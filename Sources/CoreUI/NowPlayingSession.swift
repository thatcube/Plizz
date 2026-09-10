#if canImport(MediaPlayer)
import Foundation
import MediaPlayer
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

public enum NowPlayingCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, stop, nextTrack, previousTrack
    case seek(TimeInterval)
    case skip(TimeInterval)
}

public struct NowPlayingTransport: Equatable, Sendable {
    public var canPlay: Bool
    public var canSeek: Bool
    public var hasNext: Bool
    public var hasPrevious: Bool
    public var skipBackward: TimeInterval?
    public var skipForward: TimeInterval?

    public init(
        canPlay: Bool = true,
        canSeek: Bool = false,
        hasNext: Bool = false,
        hasPrevious: Bool = false,
        skipBackward: TimeInterval? = nil,
        skipForward: TimeInterval? = nil
    ) {
        self.canPlay = canPlay
        self.canSeek = canSeek
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
        self.skipBackward = skipBackward
        self.skipForward = skipForward
    }
}

@MainActor
public protocol NowPlayingPublishing: AnyObject {
    var isActive: Bool { get }
    func bind(player: AVPlayer?)
    func activate(
        onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
        onResigned: @escaping @MainActor () -> Void
    )
    func publish(
        _ info: [String: Any],
        state: MPNowPlayingPlaybackState,
        transport: NowPlayingTransport
    )
    func invalidate()
}

/// One active owner for music and video, including delayed callbacks from an
/// outgoing player. Releasing an old session must never clear its successor.
@MainActor
public final class NowPlayingSession: NowPlayingPublishing {
    private let id = UUID()
    private let ownership: NowPlayingOwnership
    private let backend: any NowPlayingBackend
    private var activation = UUID()
    private var onCommand: (@MainActor (NowPlayingCommand) -> Void)?
    private var onResigned: (@MainActor () -> Void)?

    public convenience init() {
        self.init(ownership: .shared, backend: MediaPlayerNowPlayingBackend())
    }

    init(ownership: NowPlayingOwnership, backend: any NowPlayingBackend) {
        self.ownership = ownership
        self.backend = backend
    }

    public var isActive: Bool { ownership.ownerID == id }

    public func bind(player: AVPlayer?) {
        guard isActive else { return }
        backend.bind(player: player)
    }

    public func activate(
        onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
        onResigned: @escaping @MainActor () -> Void
    ) {
        guard !isActive else { return }
        ownership.owner?.resign()
        self.onCommand = onCommand
        self.onResigned = onResigned
        activation = UUID()
        let expectedActivation = activation
        ownership.owner = self
        ownership.ownerID = id
        backend.install { [weak self] command in
            Task { @MainActor in
                guard let self, self.isActive,
                      self.activation == expectedActivation else { return }
                self.onCommand?(command)
            }
        }
    }

    public func publish(
        _ info: [String: Any],
        state: MPNowPlayingPlaybackState,
        transport: NowPlayingTransport
    ) {
        guard isActive else { return }
        backend.publish(info, state: state, transport: transport)
    }

    public func invalidate() {
        activation = UUID()
        backend.removeHandlers()
        if isActive {
            ownership.owner = nil
            ownership.ownerID = nil
            backend.clear()
        }
        onCommand = nil
        onResigned = nil
    }

    private func resign() {
        let callback = onResigned
        invalidate()
        callback?()
    }

    deinit {
        let backend = backend
        let ownership = ownership
        let id = id
        Task { @MainActor in
            backend.removeHandlers()
            guard ownership.ownerID == id else { return }
            ownership.owner = nil
            ownership.ownerID = nil
            backend.clear()
        }
    }

    #if canImport(UIKit)
    public nonisolated static func artwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { size in
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
    #endif
}

@MainActor
final class NowPlayingOwnership {
    static let shared = NowPlayingOwnership()
    weak var owner: NowPlayingSession?
    var ownerID: UUID?
}

@MainActor
protocol NowPlayingBackend: AnyObject {
    func bind(player: AVPlayer?)
    func install(_ handler: @escaping @Sendable (NowPlayingCommand) -> Void)
    func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState, transport: NowPlayingTransport)
    func removeHandlers()
    func clear()
}

@MainActor
private final class MediaPlayerNowPlayingBackend: NowPlayingBackend {
    private var infoCenter = MPNowPlayingInfoCenter.default()
    private var commands = MPRemoteCommandCenter.shared()
    private var session: MPNowPlayingSession?
    private weak var player: AVPlayer?
    private var handler: (@Sendable (NowPlayingCommand) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []

    func bind(player: AVPlayer?) {
        guard self.player !== player else { return }
        let handler = handler
        removeHandlers()
        clear()
        self.player = player
        if let player {
            // Bare player layers do not have AVKit's automatic session. Bind
            // transport explicitly; software decode keeps the app-level center.
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = false
            self.session = session
            infoCenter = session.nowPlayingInfoCenter
            commands = session.remoteCommandCenter
        } else {
            session = nil
            infoCenter = .default()
            commands = .shared()
        }
        if let handler { install(handler) }
    }

    func install(_ handler: @escaping @Sendable (NowPlayingCommand) -> Void) {
        removeHandlers()
        self.handler = handler
        let simple: [(MPRemoteCommand, NowPlayingCommand)] = [
            (commands.playCommand, .play),
            (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .togglePlayPause),
            (commands.stopCommand, .stop),
            (commands.nextTrackCommand, .nextTrack),
            (commands.previousTrackCommand, .previousTrack)
        ]
        for (command, action) in simple {
            let token = command.addTarget { _ in
                handler(action)
                return .success
            }
            targets.append((command, token))
        }
        let seek = commands.changePlaybackPositionCommand
        let seekToken = seek.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            handler(.seek(event.positionTime))
            return .success
        }
        targets.append((seek, seekToken))
        for (command, direction) in [
            (commands.skipBackwardCommand, -1.0),
            (commands.skipForwardCommand, 1.0)
        ] {
            let token = command.addTarget { event in
                guard let event = event as? MPSkipIntervalCommandEvent,
                      event.interval.isFinite, event.interval > 0 else { return .commandFailed }
                handler(.skip(event.interval * direction))
                return .success
            }
            targets.append((command, token))
        }
    }

    func publish(
        _ info: [String: Any],
        state: MPNowPlayingPlaybackState,
        transport: NowPlayingTransport
    ) {
        commands.playCommand.isEnabled = transport.canPlay
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = transport.canPlay
        commands.stopCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = transport.hasNext
        commands.previousTrackCommand.isEnabled = transport.hasPrevious
        commands.changePlaybackPositionCommand.isEnabled = transport.canSeek
        configureSkip(commands.skipBackwardCommand, interval: transport.canSeek ? transport.skipBackward : nil)
        configureSkip(commands.skipForwardCommand, interval: transport.canSeek ? transport.skipForward : nil)
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = state
        if let session, !session.isActive, session.canBecomeActive {
            session.becomeActiveIfPossible(completion: nil)
        }
    }

    private func configureSkip(_ command: MPSkipIntervalCommand, interval: TimeInterval?) {
        let interval = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        command.isEnabled = interval != nil
        command.preferredIntervals = interval.map { [NSNumber(value: $0)] } ?? []
    }

    func removeHandlers() {
        for (command, token) in targets {
            command.removeTarget(token)
        }
        targets = []
        handler = nil
    }

    func clear() {
        for command in [
            commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
            commands.stopCommand, commands.nextTrackCommand, commands.previousTrackCommand,
            commands.changePlaybackPositionCommand, commands.skipBackwardCommand, commands.skipForwardCommand
        ] {
            command.isEnabled = false
        }
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        session = nil
        player = nil
        infoCenter = .default()
        commands = .shared()
    }
}
#endif
