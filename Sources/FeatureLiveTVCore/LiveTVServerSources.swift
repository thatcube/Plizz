#if DEBUG
import CoreModels
import CryptoKit
import Foundation

/// Resolve only from the current profile's authorized accounts. Never fall back to household accounts.
public typealias LiveTVServerProviderResolver = @MainActor @Sendable (String) -> LiveTVAuthorizedServerProvider?

public struct LiveTVAuthorizedServerProvider: Sendable {
    public let accountID: String
    /// A nonsecret, opaque identity that changes with the profile, server user, or provider authorization.
    public let authorizationID: String
    public let kind: LiveTVPrototypeSource
    public let provider: any ServerLiveTVProviding

    public init(
        accountID: String, authorizationID: String, kind: LiveTVPrototypeSource,
        provider: any ServerLiveTVProviding
    ) {
        self.accountID = accountID
        self.authorizationID = authorizationID
        self.kind = kind
        self.provider = provider
    }
}

public struct LiveTVServerChannelReference: Equatable, Sendable {
    public let sourceID: String
    public let accountID: String
    /// Runtime catalog authorization snapshot; compare before opening and after awaited playback preparation.
    public let authorizationID: String
    public let channelID: String

    public init(sourceID: String, accountID: String, authorizationID: String, channelID: String) {
        self.sourceID = sourceID
        self.accountID = accountID
        self.authorizationID = authorizationID
        self.channelID = channelID
    }
}

public enum LiveTVServerImportError: Error, Equatable, Sendable {
    case accountUnavailable, permissionDenied, unsupportedAPI, unsupportedPlaybackMode
    case tunerUnavailable, serviceUnavailable, invalidCatalog, invalidGuide
    case subscriptionRequired, guideRequired
    case configurationNotSaved

    public var userDescription: LocalizedStringResource {
        switch self {
        case .accountUnavailable: "This server account isn't available to the current profile."
        case .permissionDenied: "This server account doesn't have permission to use Live TV."
        case .subscriptionRequired: "This server requires an active subscription for Live TV."
        case .guideRequired: "This server requires a configured guide before this channel can play."
        case .configurationNotSaved: "The discovered Live TV source couldn't be saved. Try again."
        case .unsupportedAPI: "This server doesn't support the Live TV API used by Plozz."
        case .unsupportedPlaybackMode: "This server's Live TV playback mode isn't supported."
        case .tunerUnavailable: "No tuner is currently available on this server."
        case .serviceUnavailable: "The Live TV server couldn't be reached."
        case .invalidCatalog: "The server returned an invalid Live TV channel list."
        case .invalidGuide: "The server returned an invalid Live TV guide."
        }
    }

    static func sanitized(_ error: any Error, fallback: Self) -> Self {
        if let error = error as? Self { return error }
        if error is DecodingError { return fallback == .invalidGuide ? .invalidGuide : .invalidCatalog }
        if let error = error as? AppError {
            switch error {
            case .unauthorized, .invalidCredentials: return .accountUnavailable
            case .notFound: return .unsupportedAPI
            case .invalidResponse, .decoding: return fallback == .invalidGuide ? .invalidGuide : .invalidCatalog
            default: return fallback
            }
        }
        guard let error = error as? ServerLiveTVError else { return fallback }
        switch error {
        case .permissionDenied: return .permissionDenied
        case .subscriptionRequired: return .subscriptionRequired
        case .guideRequired: return .guideRequired
        case .unsupportedAPI: return .unsupportedAPI
        case .unsupportedPlaybackMode, .noCompatibleStream: return .unsupportedPlaybackMode
        case .tunerUnavailable: return .tunerUnavailable
        case .invalidChannel: return .invalidCatalog
        case .invalidGuideWindow: return .invalidGuide
        }
    }
}

public struct LiveTVServerSourceStatus: Identifiable, Equatable, Sendable {
    public let source: LiveTVServerSource
    public var id: String { source.id }
    public internal(set) var phase: LiveTVImportPhase = .idle
    public internal(set) var guidePhase: LiveTVImportPhase = .idle
    public internal(set) var availability: ServerLiveTVAvailability?
    public internal(set) var failure: LiveTVServerImportError?
    public internal(set) var guideFailure: LiveTVServerImportError?
    public internal(set) var channelCount = 0
    public internal(set) var programCount = 0
    public internal(set) var lastRefresh: Date?
    public internal(set) var lastGuideRefresh: Date?

    public var supportsPlayback: Bool {
        failure == nil && channelCount > 0 && availability?.supportsPlayback == true
    }
}

public struct LiveTVServerGuideWindowStatus: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: String
    public let channelIDs: [String]
    public let from: Date
    public let to: Date
    public internal(set) var phase: LiveTVImportPhase = .idle
    public internal(set) var failure: LiveTVServerImportError?
    public internal(set) var lastRefresh: Date?

    init(sourceID: String, channelIDs: [String], from: Date, to: Date, lastRefresh: Date? = nil) {
        id = UUID()
        self.sourceID = sourceID
        self.channelIDs = channelIDs
        self.from = from
        self.to = to
        self.lastRefresh = lastRefresh
    }
}

struct LiveTVServerCatalog {
    let authorizationID: String
    let kind: LiveTVPrototypeSource
    let channels: [LiveTVPrototypeChannel]
    let references: [String: LiveTVServerChannelReference]
    var programs: [LiveTVPrototypeProgram]
    var inlineGuideFailure: LiveTVServerImportError?

    init(
        source: LiveTVServerSource, context: LiveTVAuthorizedServerProvider, channels: [ServerLiveTVChannel]
    ) throws {
        guard channels.count <= LiveTVPlaylistParser.maximumEntries,
              Set(channels.map(\.id)).count == channels.count,
              channels.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw LiveTVServerImportError.invalidCatalog }
        authorizationID = context.authorizationID
        kind = context.kind
        self.channels = channels.enumerated().map { index, channel in
            LiveTVPrototypeChannel(
                id: Self.channelID(source: source, nativeID: channel.id),
                number: Int(channel.number ?? "") ?? index + 1,
                name: channel.name, category: channel.isRadio ? "Radio" : "Live TV",
                symbol: channel.isRadio ? "radio" : "tv", accent: index % 6, source: context.kind,
                tagline: "", logoURL: channel.imageURL, configuredSourceID: source.id
            )
        }
        references = Dictionary(uniqueKeysWithValues: channels.map { channel in
            (
                Self.channelID(source: source, nativeID: channel.id),
                LiveTVServerChannelReference(
                    sourceID: source.id, accountID: source.accountID,
                    authorizationID: context.authorizationID, channelID: channel.id
                )
            )
        })
        programs = []
        inlineGuideFailure = nil
        let current = channels.compactMap { channel -> ServerLiveTVProgramme? in
            guard let program = channel.currentProgramme, program.channelID == channel.id else { return nil }
            return program
        }
        do { programs = try mapPrograms(current, source: source) }
        catch { inlineGuideFailure = .invalidGuide }
    }

    func mapPrograms(
        _ programs: [ServerLiveTVProgramme], source: LiveTVServerSource
    ) throws -> [LiveTVPrototypeProgram] {
        let knownIDs = Set(references.values.map(\.channelID))
        guard programs.count <= LiveTVXMLTVParser.maximumRetainedPrograms,
              programs.allSatisfy({
                  !$0.id.isEmpty && knownIDs.contains($0.channelID)
                      && $0.startDate.timeIntervalSince1970.isFinite && $0.endDate.timeIntervalSince1970.isFinite
                      && $0.startDate < $0.endDate
              }),
              programs.reduce(0, { $0 + $1.title.utf8.count + ($1.subtitle?.utf8.count ?? 0) })
                <= LiveTVXMLTVParser.maximumRetainedTextBytes
        else { throw LiveTVServerImportError.invalidGuide }
        let mapped = programs.map {
            LiveTVPrototypeProgram(
                id: "server-program-\(Self.digest(source.id + "\u{1F}" + source.accountID + "\u{1F}" + $0.channelID + "\u{1F}" + $0.id))",
                channelID: Self.channelID(source: source, nativeID: $0.channelID),
                title: $0.title, subtitle: $0.subtitle ?? "",
                start: $0.startDate, end: $0.endDate
            )
        }
        guard Set(mapped.map(\.id)).count == mapped.count else { throw LiveTVServerImportError.invalidGuide }
        return mapped
    }

    private static func channelID(source: LiveTVServerSource, nativeID: String) -> String {
        "server-channel-\(digest(source.id + "\u{1F}" + source.accountID + "\u{1F}" + nativeID))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
