import Foundation

/// Optional capability of an authenticated media provider. Discovery never
/// opens a tuner; playback is a separate, explicitly owned operation.
public protocol ServerLiveTVProviding: Sendable {
    func liveTVAvailability() async throws -> ServerLiveTVAvailability
    func liveTVChannels() async throws -> [ServerLiveTVChannel]
    /// A window of at most 48 hours and 2,000 provider-local channel IDs.
    /// Prefer visible channels: some servers expose only per-channel/day EPG
    /// requests, rather than an efficient whole-lineup endpoint.
    func liveTVGuide(
        channelIDs: [String],
        from: Date,
        to: Date
    ) async throws -> [ServerLiveTVProgramme]
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease
}

public struct ServerLiveTVAvailability: Equatable, Sendable {
    public enum Status: String, Sendable {
        case available
        case notConfigured
        case noChannels
        case permissionDenied
        case subscriptionRequired
        case serviceUnavailable
        case unsupportedAPI
        case unsupportedPlaybackMode
    }

    public let status: Status
    public let channelCount: Int
    /// Describes adapter support, not whether this server has populated its EPG.
    public let supportsGuide: Bool

    public var hasChannels: Bool { channelCount > 0 }
    public var supportsPlayback: Bool { status == .available && hasChannels }

    public init(status: Status, channelCount: Int = 0, supportsGuide: Bool = true) {
        self.status = status
        self.channelCount = max(0, channelCount)
        self.supportsGuide = supportsGuide
    }
}

/// Provider-local identity. The feature layer additionally namespaces this by
/// source/account, since two accounts may return identical channel identifiers.
public struct ServerLiveTVChannel: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let number: String?
    /// Credential-free artwork only; never a tuner or playback URL.
    public let imageURL: URL?
    public let isRadio: Bool
    public let currentProgramme: ServerLiveTVProgramme?

    public init(
        id: String,
        name: String,
        number: String? = nil,
        imageURL: URL? = nil,
        isRadio: Bool = false,
        currentProgramme: ServerLiveTVProgramme? = nil
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.imageURL = imageURL
        self.isRadio = isRadio
        self.currentProgramme = currentProgramme
    }
}

public struct ServerLiveTVProgramme: Hashable, Identifiable, Sendable {
    /// Identifies one airing, not just a title which may air on several channels.
    public let id: String
    public let channelID: String
    public let title: String
    public let subtitle: String?
    public let overview: String?
    public let startDate: Date
    public let endDate: Date
    public let imageURL: URL?
    public let categories: [String]

    public init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String? = nil,
        overview: String? = nil,
        startDate: Date,
        endDate: Date,
        imageURL: URL? = nil,
        categories: [String] = []
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.startDate = startDate
        self.endDate = endDate
        self.imageURL = imageURL
        self.categories = categories
    }
}

public struct LiveTVPlaybackUpdate: Equatable, Sendable {
    public enum State: String, Sendable {
        case started
        case playing
        case paused
    }

    public let state: State
    public let positionSeconds: TimeInterval

    public init(state: State, positionSeconds: TimeInterval = 0) {
        self.state = state
        self.positionSeconds = positionSeconds.isFinite
            ? max(0, min(positionSeconds, 31_536_000))
            : 0
    }
}

/// Runtime-only ownership of one live playback. Callers close abandoned or
/// replaced leases, including successful opens that arrive after cancellation.
/// Providers also roll back failures before returning a lease. `close` waits for
/// idempotent best-effort cleanup and is safe in an already-cancelled task.
/// Several leases may coexist for one account/device. Closing one must release
/// only its own server-issued handles, never all playback on that device.
public protocol LiveTVStreamLease: Sendable {
    var playbackSource: PlaybackSource { get }
    func report(_ update: LiveTVPlaybackUpdate) async
    func close() async
}

public enum ServerLiveTVError: Error, Equatable, Sendable {
    case permissionDenied
    case subscriptionRequired
    case guideRequired
    case unsupportedAPI
    case unsupportedPlaybackMode
    case tunerUnavailable
    case noCompatibleStream
    case invalidChannel
    case invalidGuideWindow
}
