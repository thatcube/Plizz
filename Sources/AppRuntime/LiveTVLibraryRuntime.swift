#if DEBUG
import CoreModels
import CoreNetworking
import FeatureLiveTVCore
import FeaturePlayback
import Foundation
import Observation

@MainActor
private final class LiveTVLibraryAuthority {
    let profileID: String
    let preferencesNamespace: String?
    weak var profiles: ProfilesModel?
    weak var accounts: AccountsProvidersModel?
    var expectedAccounts: String?

    init(profileID: String, profiles: ProfilesModel) {
        self.profileID = profileID
        preferencesNamespace = LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles)
        self.profiles = profiles
    }

    var isAuthorized: Bool {
        guard let profiles, profiles.activeProfileID == profileID,
              preferencesNamespace == LiveTVLibraryStorage.preferencesNamespace(
                profileID: profileID, profiles: profiles
              ) else { return false }
        return expectedAccounts != nil
            && expectedAccounts == (accounts?.liveTVAuthorizationID ?? "")
    }
}

/// Shared by the active profile's guide and source editor, not by another profile.
@MainActor
@Observable
public final class LiveTVLibraryRuntime {
    public let profileID: String
    public let preferencesNamespace: String?
    public let service: LibraryChannelService
    public let history: LibraryChannelHistorySettings
    public let trackPreferences: LiveChannelTrackPreferences
    public private(set) var isLoading = false
    private var loadIssue: LibraryChannelError?
    public var issue: LibraryChannelError? {
        loadIssue ?? Self.catalogIssue(
            serviceIssue: service.issue,
            definitions: service.visibleDefinitions,
            unavailableAccountIDs: unavailableAccountIDs
        )
    }
    public private(set) var unavailableAccountIDs: Set<String> = []
    public private(set) var refreshRequest = 0
    @ObservationIgnored private let authority: LiveTVLibraryAuthority
    @ObservationIgnored private let definitionsStore: any LibraryChannelDefinitionStoring
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var loadedRefreshRequest: Int?
    private var acceptedAuthorization: String?

    public convenience init(profileID: String, profiles: ProfilesModel) {
        self.init(
            profileID: profileID, profiles: profiles,
            definitionsStore: LiveTVLibraryStorage.definitions(
                profileID: profileID,
                namespace: LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles)),
            snapshotStore: LiveTVLibraryStorage.snapshots)
    }

    init(
        profileID: String, profiles: ProfilesModel,
        definitionsStore: any LibraryChannelDefinitionStoring,
        snapshotStore: any LibraryChannelSnapshotStoring
    ) {
        self.profileID = profileID
        let authority = LiveTVLibraryAuthority(profileID: profileID, profiles: profiles)
        self.authority = authority
        self.definitionsStore = definitionsStore
        preferencesNamespace = authority.preferencesNamespace
        history = LibraryChannelHistorySettings.shared(namespace: authority.preferencesNamespace)
        trackPreferences = LiveChannelTrackPreferences(namespace: authority.preferencesNamespace)
        service = LibraryChannelService(
            profileID: profileID,
            store: definitionsStore,
            snapshotStore: snapshotStore,
            isActive: { authority.isAuthorized }
        )
    }

    public var authorizationID: String? {
        guard authority.isAuthorized, !isLoading else { return nil }
        return acceptedAuthorization
    }

    public func retry() {
        refreshRequest &+= 1
    }

    public func applyPortableChanges() {
        do {
            if try definitionsStore.load() != service.definitions {
                retry()
            }
        } catch {
            acceptedAuthorization = nil
            loadIssue = .storageFailed
            PlozzLog.app.error("Live TV shared library definitions could not be read")
        }
    }

    public func prepareForEditing() async throws {
        guard authorizationID != nil, service.isLoaded else {
            throw loadIssue ?? LibraryChannelError.authorizationChanged
        }
        let accounts = authority.accounts
        let expected = accounts?.liveTVAuthorizationID ?? ""
        let stamp = refreshID
        let discovery = try await discoverContexts(
            accounts: accounts, requiredAccountIDs: nil, stamp: stamp, expected: expected)
        try check(stamp, accounts: accounts, expected: expected)
        service.setContexts(discovery.contexts)
        unavailableAccountIDs = discovery.unavailableAccountIDs
        try await service.loadLibraries()
        try check(stamp, accounts: accounts, expected: expected)
        if !unavailableAccountIDs.isEmpty { throw LibraryChannelError.sourceUnavailable }
    }

    public func refresh(accounts: AccountsProvidersModel?) async {
        if loadedRefreshRequest == refreshRequest,
           authority.accounts === accounts, authorizationID != nil, service.isLoaded { return }
        let requested = refreshRequest
        let stamp = UUID()
        refreshID = stamp
        isLoading = true
        loadIssue = nil
        unavailableAccountIDs = []
        acceptedAuthorization = nil
        authority.accounts = accounts
        authority.expectedAccounts = nil
        service.setContexts([])
        let expected = accounts?.liveTVAuthorizationID ?? ""
        defer {
            if refreshID == stamp { isLoading = false }
        }
        do {
            try check(stamp, accounts: accounts, expected: expected)
            let definitions = try definitionsStore.load()
            guard definitions.allSatisfy({ $0.profileID == profileID }) else {
                throw LibraryChannelError.authorizationChanged
            }
            let requiredAccounts = Self.requiredDiscoveryAccountIDs(definitions: definitions)
            let discovery = try await discoverContexts(
                accounts: accounts, requiredAccountIDs: requiredAccounts, stamp: stamp, expected: expected)
            try check(stamp, accounts: accounts, expected: expected)
            unavailableAccountIDs = discovery.unavailableAccountIDs
            authority.expectedAccounts = expected
            service.setContexts(discovery.contexts)
            try await service.load()
            try check(stamp, accounts: accounts, expected: expected)
            acceptedAuthorization = expected + "|" + stamp.uuidString
            loadedRefreshRequest = requested
        } catch is CancellationError {
            if refreshID == stamp {
                authority.expectedAccounts = nil
                loadIssue = .authorizationChanged
            }
        } catch {
            guard refreshID == stamp else { return }
            authority.expectedAccounts = nil
            loadIssue = (error as? LibraryChannelError) ?? .storageFailed
            PlozzLog.app.error("Live TV library catalog could not be prepared")
        }
    }

    private func discoverContexts(
        accounts: AccountsProvidersModel?, requiredAccountIDs: Set<String>?,
        stamp: UUID, expected: String
    ) async throws -> (contexts: [LibraryChannelProviderContext], unavailableAccountIDs: Set<String>) {
        try check(stamp, accounts: accounts, expected: expected)
        if requiredAccountIDs?.isEmpty == true { return ([], []) }
        var contexts: [LibraryChannelProviderContext] = []
        var unavailable: Set<String> = []
        for resolved in accounts?.resolvedActiveAccounts ?? [] {
            guard requiredAccountIDs?.contains(resolved.account.id) ?? true else { continue }
            guard let provider = resolved.provider as? any LibraryChannelCatalogProviding,
                  provider is any LibraryChannelPlaybackProviding else { continue }
            do {
                let libraries = try await provider.libraries()
                try check(stamp, accounts: accounts, expected: expected)
                contexts.append(LibraryChannelProviderContext(
                    accountID: resolved.account.id, authorizationID: expected,
                    provider: provider, allowedLibraryIDs: Set(libraries.map(\.id))))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try check(stamp, accounts: accounts, expected: expected)
                unavailable.insert(resolved.account.id)
                PlozzLog.app.error("Live TV library discovery failed for an authorized source")
            }
        }
        return (contexts, unavailable)
    }

    static func requiredDiscoveryAccountIDs(definitions: [LibraryChannelDefinition]) -> Set<String> {
        Set(definitions.filter(\.isEnabled).flatMap(\.revisions).flatMap { $0.recipe.libraries.map(\.accountID) })
    }

    static func catalogIssue(
        serviceIssue: LibraryChannelError?,
        definitions: [LibraryChannelDefinition],
        unavailableAccountIDs: Set<String>
    ) -> LibraryChannelError? {
        if let serviceIssue { return serviceIssue }
        // Discovery also checks servers not used by any generated channel.
        // Their failure must not be presented as a broken IPTV channel.
        let affected = definitions.contains { definition in
            definition.isEnabled && definition.revisions.last?.recipe.libraries.contains {
                unavailableAccountIDs.contains($0.accountID)
            } == true
        }
        return affected ? .sourceUnavailable : nil
    }

    private func check(_ stamp: UUID, accounts: AccountsProvidersModel?, expected: String) throws {
        try Task.checkCancellation()
        guard refreshID == stamp, let profiles = authority.profiles, profiles.activeProfileID == profileID,
              preferencesNamespace == LiveTVLibraryStorage.preferencesNamespace(
                profileID: profileID, profiles: profiles
              ),
              (accounts?.liveTVAuthorizationID ?? "") == expected else {
            throw CancellationError()
        }
    }
}
#endif
