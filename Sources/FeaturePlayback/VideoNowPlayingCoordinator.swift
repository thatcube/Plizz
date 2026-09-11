#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MediaPlayer
import CoreModels
import CoreUI

@MainActor
protocol VideoNowPlayingHost: AnyObject {
    var nowPlayingPlayer: AVPlayer? { get }
    var nowPlayingCanPlay: Bool { get }
    var nowPlayingTime: TimeInterval { get }
    var nowPlayingDuration: TimeInterval { get }
    var nowPlayingSpeed: Double { get }
    var nowPlayingPaused: Bool { get }
    var nowPlayingAdvancing: Bool { get }
    var nowPlayingReady: Bool { get }
    var nowPlayingSeeking: Bool { get }
    var nowPlayingPendingSeek: TimeInterval? { get }
    var nowPlayingPrevious: MediaItem? { get }
    var nowPlayingNext: MediaItem? { get }
    var nowPlayingBackwardInterval: TimeInterval { get }
    var nowPlayingForwardInterval: TimeInterval { get }
    func nowPlayingSetPaused(_ paused: Bool)
    func nowPlayingSeek(to seconds: TimeInterval)
    func nowPlayingPlayEpisode(_ item: MediaItem)
    func nowPlayingStop()
}

/// System transport follows the shared player lifecycle, not the visibility of
/// either platform's overlay. Artwork and clock tasks never retain the player.
@MainActor
final class VideoNowPlayingCoordinator {
    typealias ArtworkLoader = @MainActor (
        MediaItem, @escaping @MainActor (MPMediaItemArtwork) -> Void
    ) async -> Void

    private weak var host: (any VideoNowPlayingHost)?
    private let publisher: any NowPlayingPublishing
    private let artworkLoader: ArtworkLoader
    private let startsClock: Bool
    private var clockTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = UUID()
    private var artwork: MPMediaItemArtwork?
    private var artworkIsComplete = false
    private var item: MediaItem?
    private var title = ""
    private var subtitle = ""
    private var startPosition: TimeInterval = 0

    init(
        host: any VideoNowPlayingHost,
        publisher: any NowPlayingPublishing,
        startsClock: Bool = true,
        artworkLoader: @escaping ArtworkLoader = VideoNowPlayingCoordinator.loadArtwork
    ) {
        self.host = host
        self.publisher = publisher
        self.startsClock = startsClock
        self.artworkLoader = artworkLoader
    }

    func begin(item: MediaItem, title: String, subtitle: String, position: TimeInterval) { // l10n:content - provider media titles and episode identifiers
        let firstStart = self.item == nil
        let changedItem = self.item?.id != item.id || self.item?.sourceAccountID != item.sourceAccountID
        self.item = item
        self.title = title
        self.subtitle = subtitle
        startPosition = position.isFinite ? max(0, position) : 0
        if changedItem {
            artwork = nil
            artworkIsComplete = false
            cancelArtwork()
        }
        // A fallback may finish loading after another player took ownership.
        // Only a new session or an explicit Play may reclaim system controls.
        if firstStart || publisher.isActive {
            activate()
        }
    }

    func activate() {
        guard let item else { return }
        if !publisher.isActive {
            publisher.activate(
                onCommand: { [weak self] in self?.handle($0) },
                onResigned: { [weak self] in self?.resign() }
            )
        }
        refresh()
        if !artworkIsComplete, artworkTask == nil {
            let generation = artworkGeneration
            let loader = artworkLoader
            artworkTask = Task { [weak self] in
                await loader(item) { [weak self] image in
                    guard !Task.isCancelled, let self,
                          self.artworkGeneration == generation, self.publisher.isActive else { return }
                    self.artwork = image
                    self.refresh()
                }
                guard let self, self.artworkGeneration == generation else { return }
                self.artworkIsComplete = self.artwork != nil
                self.artworkTask = nil
            }
        }
        if startsClock, clockTask == nil {
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard self?.publisher.isActive == true else { return }
                    self?.refresh()
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func refresh() {
        guard publisher.isActive, let host, let item else { return }
        publisher.bind(player: host.nowPlayingPlayer)
        let duration = Self.duration(engine: host.nowPlayingDuration, fallback: item.runtime)
        let rawPosition = host.nowPlayingReady ? host.nowPlayingTime : startPosition
        let position = rawPosition.isFinite ? max(0, rawPosition) : 0
        let speed = host.nowPlayingSpeed.isFinite && host.nowPlayingSpeed > 0 ? host.nowPlayingSpeed : 1
        let advancing = host.nowPlayingReady && !host.nowPlayingPaused
            && host.nowPlayingAdvancing && !host.nowPlayingSeeking
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: duration.map { min(position, $0) } ?? position,
            MPNowPlayingInfoPropertyPlaybackRate: advancing ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed
        ]
        if !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        publisher.publish(
            info,
            state: host.nowPlayingPaused || !host.nowPlayingReady ? .paused : .playing,
            transport: NowPlayingTransport(
                canPlay: host.nowPlayingCanPlay,
                canSeek: host.nowPlayingReady && duration != nil,
                hasNext: host.nowPlayingReady && host.nowPlayingCanPlay && host.nowPlayingNext != nil,
                hasPrevious: host.nowPlayingReady && host.nowPlayingCanPlay && host.nowPlayingPrevious != nil,
                skipBackward: host.nowPlayingBackwardInterval,
                skipForward: host.nowPlayingForwardInterval
            )
        )
    }

    func end() {
        clockTask?.cancel()
        clockTask = nil
        cancelArtwork()
        artwork = nil
        artworkIsComplete = false
        item = nil
        publisher.invalidate()
    }

    private func resign() {
        clockTask?.cancel()
        clockTask = nil
        cancelArtwork()
        host?.nowPlayingSetPaused(true)
    }

    private func cancelArtwork() {
        artworkGeneration = UUID()
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func handle(_ command: NowPlayingCommand) {
        guard publisher.isActive, let host else { return }
        switch command {
        case .play:
            if host.nowPlayingCanPlay { host.nowPlayingSetPaused(false) }
        case .pause: host.nowPlayingSetPaused(true)
        case .togglePlayPause:
            if !host.nowPlayingPaused || host.nowPlayingCanPlay {
                host.nowPlayingSetPaused(!host.nowPlayingPaused)
            }
        case .stop: host.nowPlayingStop()
        case .nextTrack:
            if host.nowPlayingReady, host.nowPlayingCanPlay, let next = host.nowPlayingNext {
                host.nowPlayingPlayEpisode(next)
            }
        case .previousTrack:
            if host.nowPlayingReady, host.nowPlayingCanPlay, let previous = host.nowPlayingPrevious {
                host.nowPlayingPlayEpisode(previous)
            }
        case .seek(let position):
            seek(position, host: host)
        case .skip(let interval):
            let position = host.nowPlayingPendingSeek ?? host.nowPlayingTime
            seek(position + interval, host: host)
        }
        refresh()
    }

    private func seek(_ position: TimeInterval, host: any VideoNowPlayingHost) {
        guard host.nowPlayingReady, position.isFinite,
              let duration = Self.duration(engine: host.nowPlayingDuration, fallback: item?.runtime) else { return }
        host.nowPlayingSeek(to: max(0, min(duration, position)))
    }

    static func duration(engine: TimeInterval, fallback: TimeInterval?) -> TimeInterval? {
        if engine.isFinite, engine > 0 { return engine }
        guard let fallback, fallback.isFinite, fallback > 0 else { return nil }
        return fallback
    }

    static func artworkReferences(for item: MediaItem) -> [ArtworkReference] {
        NowPlayingVideoArtwork.references(for: item)
    }

    private static func loadArtwork(
        _ item: MediaItem,
        onUpdate: @escaping @MainActor (MPMediaItemArtwork) -> Void
    ) async {
        await NowPlayingVideoArtwork.load(for: item, onUpdate: onUpdate)
    }

    deinit {
        clockTask?.cancel()
        artworkTask?.cancel()
    }
}
#endif
