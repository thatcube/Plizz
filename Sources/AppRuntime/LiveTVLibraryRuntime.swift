#if DEBUG
import CoreModels
import CoreNetworking
import CoreSecureStore
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
    var automaticChannelsEnabled = false
    var automaticSourceIDs: Set<UUID> = []

    init(profileID: String, profiles: ProfilesModel) {
        self.profileID = profileID
        preferencesNamespace = LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles)
        self.profiles = profiles
    }

    var isCurrentProfile: Bool {
        guard let profiles, profiles.activeProfileID == profileID,
              preferencesNamespace == LiveTVLibraryStorage.preferencesNamespace(
                profileID: profileID, profiles: profiles
              ) else { return false }
        return true
    }

    var isAuthorized: Bool {
        isCurrentProfile && expectedAccounts != nil
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
    public private(set) var automaticChannelsEnabled = false
    public private(set) var isPreparingAutomaticChannels = false
    public let automaticPreparation = LibraryChannelPreparationProgress()
    public private(set) var automaticChannelsIssue: LibraryChannelError?
    public private(set) var automaticUnavailableSources: [LibraryChannelSourceFailure] = []
    public private(set) var automaticSkippedItemCount = 0
    public var automaticChannelCount: Int {
        service.channels.filter { channel in
            authority.automaticSourceIDs.contains { $0.uuidString == channel.configuredSourceID }
        }.count
    }
    private var loadIssue: LibraryChannelError?
    public var issue: LibraryChannelError? {
        loadIssue ?? Self.catalogIssue(
            serviceIssue: service.definitions.contains(where: { !$0.isAutomatic }) ? service.issue : nil,
            definitions: service.visibleDefinitions.filter { !$0.isAutomatic },
            unavailableAccountIDs: unavailableAccountIDs
        )
    }
    public private(set) var unavailableAccountIDs: Set<String> = []
    public private(set) var refreshRequest = 0
    @ObservationIgnored private let authority: LiveTVLibraryAuthority
    @ObservationIgnored private let definitionsStore: any LibraryChannelDefinitionStoring
    @ObservationIgnored private let automaticSettingsStore: any LiveTVAutomaticChannelsStoring
    @ObservationIgnored private var lastAutomaticRefresh: Date?
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var loadedRefreshRequest: Int?
    private var acceptedAuthorization: String?

    public convenience init(profileID: String, profiles: ProfilesModel) {
        self.init(
            profileID: profileID, profiles: profiles,
            definitionsStore: LiveTVLibraryStorage.definitions(
                profileID: profileID,
                namespace: LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles)),
            snapshotStore: LiveTVLibraryStorage.snapshots,
            automaticSettingsStore: LiveTVAutomaticChannelsStore(
                secureStore: LiveTVSourceStorage.catalogSecrets(),
                namespace: LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles)))
    }

    init(
        profileID: String, profiles: ProfilesModel,
        definitionsStore: any LibraryChannelDefinitionStoring,
        snapshotStore: any LibraryChannelSnapshotStoring,
        automaticSettingsStore: any LiveTVAutomaticChannelsStoring = LiveTVMemoryAutomaticChannelsStore()
    ) {
        self.profileID = profileID
        let authority = LiveTVLibraryAuthority(profileID: profileID, profiles: profiles)
        self.authority = authority
        self.definitionsStore = definitionsStore
        self.automaticSettingsStore = automaticSettingsStore
        preferencesNamespace = authority.preferencesNamespace
        history = LibraryChannelHistorySettings.shared(namespace: authority.preferencesNamespace)
        trackPreferences = LiveChannelTrackPreferences(namespace: authority.preferencesNamespace)
        service = LibraryChannelService(
            profileID: profileID,
            store: definitionsStore,
            snapshotStore: snapshotStore,
            isActive: { authority.isAuthorized },
            isSourceAllowed: {
                !authority.automaticSourceIDs.contains($0) || authority.automaticChannelsEnabled
            }
        )
    }

    public var authorizationID: String? {
        guard authority.isAuthorized, !isLoading else { return nil }
        return acceptedAuthorization
    }

    public func retry() {
        refreshRequest &+= 1
    }

    public func requestAutomaticRefresh(force: Bool = false) {
        guard automaticChannelsEnabled, !isLoading, !isPreparingAutomaticChannels,
              loadedRefreshRequest == refreshRequest,
              force || (lastAutomaticRefresh.map({ Date().timeIntervalSince($0) >= 900 }) ?? true) else { return }
        retry()
    }

    public func setAutomaticChannelsEnabled(_ enabled: Bool) async {
        guard authority.isCurrentProfile, !enabled || (authority.isAuthorized && service.isLoaded) else {
            automaticChannelsIssue = .authorizationChanged
            PlozzLog.app.error("Automatic Plozz channels changed outside their authorized profile")
            return
        }
        do {
            try automaticSettingsStore.setEnabled(enabled)
            automaticChannelsEnabled = enabled
            authority.automaticChannelsEnabled = enabled
            automaticChannelsIssue = nil
            if !enabled {
                refreshID = UUID()
                isPreparingAutomaticChannels = false
                isLoading = false
                automaticSkippedItemCount = 0
                automaticUnavailableSources = []
                if service.isLoaded { try service.setAutomaticChannelsEnabled(false) }
                else { service.setContexts([]) }
            }
            retry()
        } catch {
            automaticChannelsIssue = (error as? LibraryChannelError) ?? .storageFailed
            PlozzLog.app.error("Automatic Plozz channels preference could not be applied")
        }
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
        service.updateContexts(discovery.contexts)
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
        let expected = accounts?.liveTVAuthorizationID ?? ""
        let retainsAuthorization = authority.accounts === accounts
            && authorizationID != nil && service.isLoaded
        let previousAuthorization = acceptedAuthorization
        refreshID = stamp
        isLoading = !retainsAuthorization
        isPreparingAutomaticChannels = false
        loadIssue = nil
        automaticChannelsIssue = nil
        automaticUnavailableSources = []
        unavailableAccountIDs = []
        authority.accounts = accounts
        if !retainsAuthorization {
            acceptedAuthorization = nil
            authority.expectedAccounts = nil
            service.setContexts([])
        }
        defer {
            if refreshID == stamp {
                isLoading = false
                isPreparingAutomaticChannels = false
            }
        }
        do {
            try check(stamp, accounts: accounts, expected: expected)
            let definitions = try definitionsStore.load()
            guard definitions.allSatisfy({ $0.profileID == profileID }) else {
                throw LibraryChannelError.authorizationChanged
            }
            authority.automaticSourceIDs = Set(definitions.filter(\.isAutomatic).map(\.sourceID))
            do {
                automaticChannelsEnabled = try automaticSettingsStore.isEnabled()
            } catch {
                automaticChannelsEnabled = false
                automaticChannelsIssue = .storageFailed
                PlozzLog.app.error("Automatic Plozz channels preference could not be read")
            }
            authority.automaticChannelsEnabled = automaticChannelsEnabled
            if automaticChannelsEnabled {
                isPreparingAutomaticChannels = true
                automaticPreparation.begin()
            }
            let requiredAccounts = automaticChannelsEnabled ? nil : Self.requiredDiscoveryAccountIDs(
                definitions: definitions.filter { !$0.isAutomatic })
            let discovery = try await discoverContexts(
                accounts: accounts, requiredAccountIDs: requiredAccounts, stamp: stamp, expected: expected,
                reportsProgress: automaticChannelsEnabled)
            try check(stamp, accounts: accounts, expected: expected)
            unavailableAccountIDs = discovery.unavailableAccountIDs
            automaticUnavailableSources = discovery.failures
            authority.expectedAccounts = expected
            service.updateContexts(discovery.contexts)
            try await service.load()
            try check(stamp, accounts: accounts, expected: expected)
            acceptedAuthorization = retainsAuthorization ? previousAuthorization : expected + "|" + stamp.uuidString
            loadedRefreshRequest = requested
            isLoading = false
            if automaticChannelsEnabled {
                isPreparingAutomaticChannels = true
                defer {
                    if refreshID == stamp {
                        authority.automaticSourceIDs = Set(service.definitions.filter(\.isAutomatic).map(\.sourceID))
                        isPreparingAutomaticChannels = false
                    }
                }
                do {
                    let summary = try await service.refreshAutomaticChannels(
                        unavailableAccountIDs: unavailableAccountIDs,
                        reportProgress: { [weak self] update in
                            guard let self, self.refreshID == stamp, self.automaticChannelsEnabled else { return }
                            self.automaticPreparation.receive(update)
                        })
                    try check(stamp, accounts: accounts, expected: expected)
                    authority.automaticSourceIDs = Set(service.definitions.filter(\.isAutomatic).map(\.sourceID))
                    automaticSkippedItemCount = summary.skippedItemCount
                    automaticUnavailableSources = discovery.failures + summary.unavailableSources
                    unavailableAccountIDs.formUnion(summary.unavailableSources.map(\.accountID))
                    for failure in summary.unavailableSources {
                        PlozzLog.app.error("Automatic library catalog failed: \(failure.reason.rawValue)")
                    }
                    if automaticChannelCount == 0 {
                        automaticChannelsIssue = automaticUnavailableSources.isEmpty ? .emptyCatalog : .sourceUnavailable
                        PlozzLog.app.info("Automatic Plozz channels have no currently available library media")
                    }
                    PlozzLog.app.info(
                        "Automatic Plozz channels prepared channels=\(automaticChannelCount) items=\(summary.eligibleItemCount) unavailableSources=\(automaticUnavailableSources.count)")
                    lastAutomaticRefresh = Date()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try check(stamp, accounts: accounts, expected: expected)
                    automaticChannelsIssue = (error as? LibraryChannelError) ?? .storageFailed
                    PlozzLog.app.error("Automatic Plozz channel lineup could not be prepared")
                }
            } else {
                try service.setAutomaticChannelsEnabled(false)
            }
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
        stamp: UUID, expected: String, reportsProgress: Bool = false
    ) async throws -> (
        contexts: [LibraryChannelProviderContext], unavailableAccountIDs: Set<String>,
        failures: [LibraryChannelSourceFailure]
    ) {
        try check(stamp, accounts: accounts, expected: expected)
        if requiredAccountIDs?.isEmpty == true { return ([], [], []) }
        var contexts: [LibraryChannelProviderContext] = []
        var unavailable: Set<String> = []
        var failures: [LibraryChannelSourceFailure] = []
        for resolved in accounts?.resolvedActiveAccounts ?? [] {
            guard requiredAccountIDs?.contains(resolved.account.id) ?? true else { continue }
            guard let provider = resolved.provider as? any LibraryChannelCatalogProviding,
                  provider is any LibraryChannelPlaybackProviding else { continue }
            do {
                if reportsProgress {
                    automaticPreparation.receive(.init(
                        stage: .checkingServers, serverName: resolved.account.server.name))
                }
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
                let failure = LibraryChannelSourceFailure(
                    accountID: resolved.account.id, serverName: resolved.account.server.name, error: error)
                failures.append(failure)
                PlozzLog.app.error("Live TV library discovery failed for an authorized source: \(failure.reason.rawValue)")
            }
        }
        return (contexts, unavailable, failures)
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
