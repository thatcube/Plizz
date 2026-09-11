import CryptoKit
import Foundation

/// Local parental authority for one profile and its current server identities.
/// A profile rename/avatar edit does not revoke access; changing its identity,
/// Kids restriction revision, household PIN, or account membership does.
public struct LiveTVSourceApprovalContext: Equatable, Sendable {
    public let profileID: String
    public let requiresApproval: Bool
    public let identity: String
    private let parentalPIN: ParentalPIN?

    public init(profile: Profile, parentalPIN: ParentalPIN?, activeAccountIDs: [String]) {
        self.profileID = profile.id
        self.requiresApproval = profile.isKids
        self.parentalPIN = parentalPIN
        let bindings = activeAccountIDs.sorted().map {
            Binding(accountID: $0, userID: profile.homeUserBinding(forPlexAccount: $0)?.homeUserID)
        }
        identity = LiveTVApprovalDigest.make(Identity(
            profileID: profile.id,
            createdAt: profile.createdAt,
            linkedAccountID: profile.linkedAccountID,
            isKids: profile.isKids,
            kidsRevision: profile.kidsProfileRevision,
            bindings: bindings,
            allHomeUserIDs: profile.plexHomeUserBindings?.mapValues(\.homeUserID) ?? [:],
            legacyHomeUserID: profile.plexHomeUserID,
            legacyHomeAccountID: profile.plexHomeUserAccountID,
            pendingIdentities: profile.pendingIdentityAccountIDs.sorted(),
            parentalPIN: parentalPIN
        ))
    }

    public var hasParentalPIN: Bool { parentalPIN != nil }

    @MainActor
    public init(profiles: ProfilesModel) {
        self.init(
            profile: profiles.activeProfile, parentalPIN: profiles.parentalPIN,
            activeAccountIDs: profiles.activeAccountIDs(for: profiles.activeProfileID, fallback: [])
        )
    }

    /// Uses the existing household verifier; no alternative PIN is created or stored.
    public func authorize(parentalPIN pin: String) -> LiveTVSourceApprovalPermit? {
        guard parentalPIN?.matches(pin: pin) == true else { return nil }
        return LiveTVSourceApprovalPermit(profileID: profileID, identity: identity)
    }

    private struct Binding: Encodable {
        let accountID: String
        let userID: String?
    }

    private struct Identity: Encodable {
        let profileID: String
        let createdAt: Date
        let linkedAccountID: String?
        let isKids: Bool
        let kidsRevision: ProfileLockRevision?
        let bindings: [Binding]
        let allHomeUserIDs: [String: String]
        let legacyHomeUserID: String?
        let legacyHomeAccountID: String?
        let pendingIdentities: [String]
        let parentalPIN: ParentalPIN?
    }
}

/// Short-lived proof of a successful existing parental-PIN check. Only the
/// context can create this value; callers must compare current context on save.
public struct LiveTVSourceApprovalPermit: Sendable {
    fileprivate let profileID: String
    fileprivate let identity: String

    fileprivate init(profileID: String, identity: String) {
        self.profileID = profileID
        self.identity = identity
    }
}

public enum LiveTVSourceApprovalStatus: Equatable, Sendable {
    case unrestricted, approved, needsApproval, parentalPINRequired, disabled
}

/// Safe to pass to importers and playback coordinators. Never contains a PIN,
/// source URL, title, artwork, or credentials.
public struct LiveTVSourceAuthorization: Equatable, Sendable {
    public let profileID: String
    /// Request-generation fence, NOT a durable channel-identity storage namespace.
    /// It changes with configuration and grants while channel IDs must survive both.
    public let identity: String
    public let allowedPlaylistIDs: Set<String>

    public func allowsPlaylist(_ id: String?) -> Bool {
        guard let id else { return false }
        return allowedPlaylistIDs.contains(id)
    }

    /// Server sources deliberately stay unchanged: authorized provider identity
    /// and Live TV permission checks remain mandatory at their existing boundary.
    public func filtering(_ configuration: LiveTVSourcesConfiguration) -> LiveTVSourcesConfiguration {
        var result = configuration
        result.playlists = configuration.playlists.filter { allowedPlaylistIDs.contains($0.id) }
        return result
    }
}

public enum LiveTVSourceApprovalError: Error, Equatable, Sendable {
    case invalidStoredValue, unsupportedVersion, invalidRecord, staleAuthority, wrongProfile
}

public extension Notification.Name {
    static let plozzLiveTVSourceApprovalsDidChange = Notification.Name(
        "com.plozz.liveTV.sourceApprovalsDidChange"
    )
}

/// Small local-only receipts. Neither cloud configuration nor portable channel
/// sync can create parental authority. Legacy sources are not inferred approvals.
public final class LiveTVSourceApprovalStore: @unchecked Sendable {
    private struct Receipt: Codable {
        let sourceIdentity: String
        let profileIdentity: String
    }

    private struct Document: Codable {
        var version = 1
        var profileID: String
        var receipts: [String: Receipt] = [:]
    }

    fileprivate let defaults: UserDefaults
    fileprivate let profileID: String
    fileprivate let namespace: String?
    private let key: String
    private static let lock = NSLock()

    public convenience init(defaults: UserDefaults = .standard, profileID: String) {
        self.init(
            defaults: defaults, profileID: profileID,
            namespace: profileID == ProfileStore.defaultProfileID ? nil : profileID
        )
    }

    public init(defaults: UserDefaults = .standard, profileID: String, namespace: String?) {
        self.defaults = defaults
        self.profileID = profileID
        self.namespace = namespace
        key = SettingsKey.scoped(
            "com.plozz.liveTV.sourceApprovals.v1",
            namespace: namespace
        )
    }

    public func status(
        source: LiveTVPlaylistSource, context: LiveTVSourceApprovalContext
    ) throws -> LiveTVSourceApprovalStatus {
        guard context.profileID == profileID else { throw LiveTVSourceApprovalError.wrongProfile }
        guard source.isEnabled else { return .disabled }
        guard context.requiresApproval else { return .unrestricted }
        guard context.hasParentalPIN else { return .parentalPINRequired }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let receipt = try load().receipts[source.id]
        return receipt?.profileIdentity == context.identity
            && receipt?.sourceIdentity == Self.sourceIdentity(source) ? .approved : .needsApproval
    }

    public func authorization(
        context: LiveTVSourceApprovalContext, configuration: LiveTVSourcesConfiguration
    ) throws -> LiveTVSourceAuthorization {
        guard context.profileID == profileID else { throw LiveTVSourceApprovalError.wrongProfile }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Adults retain their sources even if an obsolete child receipt is corrupt.
        let document = context.requiresApproval ? try load() : Document(profileID: profileID)
        let ids = Set(configuration.playlists.filter { source in
            guard source.isEnabled else { return false }
            guard context.requiresApproval else { return true }
            guard context.hasParentalPIN, let receipt = document.receipts[source.id] else { return false }
            return receipt.profileIdentity == context.identity
                && receipt.sourceIdentity == Self.sourceIdentity(source)
        }.map(\.id))
        return LiveTVSourceAuthorization(
            profileID: profileID,
            identity: LiveTVApprovalDigest.make([
                context.identity,
                ids.sorted().joined(separator: "\u{1F}"),
                LiveTVApprovalDigest.make(configuration.playlists)
            ]),
            allowedPlaylistIDs: ids
        )
    }

    public func authorizationFailClosed(
        context: LiveTVSourceApprovalContext, configuration: LiveTVSourcesConfiguration
    ) -> LiveTVSourceAuthorization {
        do { return try authorization(context: context, configuration: configuration) }
        catch {
            return LiveTVSourceAuthorization(
                profileID: context.profileID,
                identity: LiveTVApprovalDigest.make(["denied", context.identity]),
                allowedPlaylistIDs: []
            )
        }
    }

    public func approve(
        source: LiveTVPlaylistSource,
        context: LiveTVSourceApprovalContext,
        permit: LiveTVSourceApprovalPermit
    ) throws {
        guard context.profileID == profileID else { throw LiveTVSourceApprovalError.wrongProfile }
        guard permit.profileID == profileID, permit.identity == context.identity,
              context.hasParentalPIN else { throw LiveTVSourceApprovalError.staleAuthority }
        try source.validate()
        try update { document in
            guard document.receipts[source.id] != nil || document.receipts.count < 100 else {
                throw LiveTVSourceApprovalError.invalidRecord
            }
            document.receipts[source.id] = Receipt(
                sourceIdentity: Self.sourceIdentity(source), profileIdentity: context.identity
            )
        }
    }

    /// Revocation is always safe: it needs no PIN and never mutates source data or favorites.
    public func revoke(sourceID: String) throws {
        try update { $0.receipts.removeValue(forKey: sourceID) }
    }

    public func revokeAll() throws {
        try update { $0.receipts.removeAll() }
    }

    public func invalidateChangedSources(
        previous: LiveTVSourcesConfiguration, updated: LiveTVSourcesConfiguration
    ) throws {
        let changedIDs = previous.playlists.compactMap { source -> String? in
            guard let replacement = updated.playlists.first(where: { $0.id == source.id }) else { return source.id }
            return Self.sourceIdentity(source) == Self.sourceIdentity(replacement) ? nil : source.id
        }
        guard !changedIDs.isEmpty else { return }
        try update { document in
            for id in changedIDs { document.receipts.removeValue(forKey: id) }
        }
    }

    private func load() throws -> Document {
        guard let stored = defaults.object(forKey: key) else { return Document(profileID: profileID) }
        guard let data = stored as? Data, data.count <= 128 * 1024 else {
            throw LiveTVSourceApprovalError.invalidStoredValue
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw LiveTVSourceApprovalError.unsupportedVersion }
        guard document.profileID == profileID, document.receipts.count <= 100 else {
            throw LiveTVSourceApprovalError.invalidRecord
        }
        return document
    }

    private func update(_ mutation: (inout Document) throws -> Void) throws {
        Self.lock.lock()
        do {
            var document = try load()
            try mutation(&document)
            defaults.set(try JSONEncoder().encode(document), forKey: key)
            Self.lock.unlock()
        } catch {
            Self.lock.unlock()
            throw error
        }
        NotificationCenter.default.post(
            name: .plozzLiveTVSourceApprovalsDidChange, object: profileID
        )
    }

    private static func sourceIdentity(_ source: LiveTVPlaylistSource) -> String {
        // Secret-bearing addresses never leave this hash. An edited endpoint or
        // guide can expose a different lineup, so it needs a fresh parental check.
        LiveTVApprovalDigest.make(
            [source.id, source.playlistURL.absoluteString] + source.guideURLs.map(\.absoluteString)
        )
    }
}

/// Install at the source-store composition boundary so even editing an address
/// away and back, deleting/reusing an ID, or a stale settings scene cannot revive
/// an earlier grant. Failed saves may revoke a grant, but can never broaden it.
public protocol LiveTVPortableSourcesStoring: LiveTVSourcesStoring {
    func loadSyncConfiguration() throws -> LiveTVSourcesConfiguration
    func applySyncedConfiguration(_ configuration: LiveTVSourcesConfiguration) throws
}

public final class LiveTVApprovalAwareSourcesStore: LiveTVPortableSourcesStoring, @unchecked Sendable {
    private let underlying: any LiveTVSourcesStoring
    private let approvals: LiveTVSourceApprovalStore
    private let suppression: LiveTVServerEnrollmentSuppressionStore
    private static let lock = NSLock()

    public init(underlying: any LiveTVSourcesStoring, approvals: LiveTVSourceApprovalStore) {
        self.underlying = underlying
        self.approvals = approvals
        suppression = LiveTVServerEnrollmentSuppressionStore(
            defaults: approvals.defaults, profileID: approvals.profileID, namespace: approvals.namespace
        )
    }

    public func load() throws -> LiveTVSourcesConfiguration {
        var configuration = try underlying.load()
        guard !configuration.servers.isEmpty else { return configuration }
        let suppressed = try suppression.suppressedAccountIDs()
        for index in configuration.servers.indices
        where suppressed.contains(configuration.servers[index].accountID) {
            configuration.servers[index].isEnabled = false
        }
        return configuration
    }

    public func loadSyncConfiguration() throws -> LiveTVSourcesConfiguration {
        try underlying.load()
    }

    /// Remote enablement never clears an independent removal marker. Its explicit
    /// server-enrollment record does that; this preserves either delivery order.
    public func applySyncedConfiguration(_ configuration: LiveTVSourcesConfiguration) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try configuration.validate()
        let previous = try underlying.load()
        try approvals.invalidateChangedSources(previous: previous, updated: configuration)
        try suppression.prepareChange(previous: previous, updated: configuration)
        try underlying.save(configuration)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: approvals.profileID)
    }

    public func save(_ configuration: LiveTVSourcesConfiguration) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try configuration.validate()
        let previous = try load()
        try approvals.invalidateChangedSources(previous: previous, updated: configuration)
        try suppression.prepareChange(previous: previous, updated: configuration)
        try underlying.save(configuration)
        try suppression.completeChange(previous: previous, updated: configuration)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: approvals.profileID)
    }
}

private enum LiveTVApprovalDigest {
    static func make(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Invalid local metadata must invalidate authority, never crash or share
        // a fallback identity with another invalid value.
        guard let data = try? encoder.encode(value) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
