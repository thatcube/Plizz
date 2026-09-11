#if canImport(AVFoundation)
import CoreModels
import Foundation

/// Live status is supplied by the engine, never reconstructed from AVPlayer hints.
public enum LiveChannelEnginePhase: Equatable, Sendable {
    case idle, loading, playing, paused, seeking, rebuffering
    case stalled(reconnecting: Bool)
    case ended, failed

    public var diagnosticCode: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .seeking: "seeking"
        case .rebuffering: "rebuffering"
        case .stalled(let reconnecting): reconnecting ? "reconnecting" : "stalled"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}

public enum LiveChannelEngineRoute: String, Equatable, Sendable {
    case none, nativeHLS, localHLS, software, audio
}

public struct LiveChannelEngineSnapshot: Equatable, Sendable {
    public var phase: LiveChannelEnginePhase
    public var firstFrameReady: Bool
    public var position: TimeInterval
    public var bufferedPosition: TimeInterval
    public var seekableRange: ClosedRange<TimeInterval>?
    public var behindLiveSeconds: TimeInterval?
    public var route: LiveChannelEngineRoute

    public init(
        phase: LiveChannelEnginePhase = .idle,
        firstFrameReady: Bool = false,
        position: TimeInterval = 0,
        bufferedPosition: TimeInterval = 0,
        seekableRange: ClosedRange<TimeInterval>? = nil,
        behindLiveSeconds: TimeInterval? = nil,
        route: LiveChannelEngineRoute = .none
    ) {
        self.phase = phase
        self.firstFrameReady = firstFrameReady
        self.position = position
        self.bufferedPosition = bufferedPosition
        self.seekableRange = seekableRange
        self.behindLiveSeconds = behindLiveSeconds
        self.route = route
    }
}

/// Process-wide audio and display ownership for independently retained live players.
public struct LiveChannelOutputPolicy: Equatable, Sendable {
    public var isAudible: Bool
    public var sharesAudioSession: Bool
    public var suppressesDisplayMatching: Bool

    public init(
        isAudible: Bool = true,
        sharesAudioSession: Bool = false,
        suppressesDisplayMatching: Bool = false
    ) {
        self.isAudible = isAudible
        self.sharesAudioSession = sharesAudioSession
        self.suppressesDisplayMatching = suppressesDisplayMatching
    }
}

/// Implemented in EnginePlozzigen and injected by the app to avoid a feature/engine dependency cycle.
@MainActor
public protocol LiveChannelEngine: VideoEngine {
    var liveSnapshot: LiveChannelEngineSnapshot { get }
    var onLiveSourceReset: (@MainActor () -> Void)? { get set }
    /// A scheduled media boundary resets tracks/cues, not the channel or decoder owner.
    var onProgrammeChanged: (@MainActor () -> Void)? { get set }
    var supportsConcurrentPlayback: Bool { get }
    var recoverableProgrammeIssue: LibraryChannelError? { get }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy)
    func setWatching(_ isWatching: Bool)
    func loadChannel(_ input: LiveChannelInput) async throws
    func loadLive(url: URL, httpHeaders: [String: String]) async
    func seekToLiveEdge() async
}

public extension LiveChannelEngine {
    var supportsConcurrentPlayback: Bool { false }
    var recoverableProgrammeIssue: LibraryChannelError? { nil }
    var onProgrammeChanged: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {}
    func setWatching(_ isWatching: Bool) {}
    func loadChannel(_ input: LiveChannelInput) async throws {
        switch input {
        case .stream(let url, let headers):
            await loadLive(url: url, httpHeaders: headers)
        case .libraryChannel:
            throw LiveChannelInputError.unsupportedSource
        }
    }
}
#endif
