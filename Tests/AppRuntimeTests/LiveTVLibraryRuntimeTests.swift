#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import FeatureLiveTVCore
import XCTest
@testable import AppRuntime

final class LiveTVLibraryRuntimeTests: XCTestCase {
    @MainActor
    func testIPTVRefreshMakesZeroLibraryRequestsEvenWithAnUnreachableConnectedServer() async throws {
        let suite = "LiveTVLibraryRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let store = AccountStore(secureStore: InMemorySecureStore())
        let provider = RuntimeLibraryDiscoveryProvider()
        try store.add(Account(
            id: "unrelated-account", server: provider.session.server, userID: "user",
            userName: "User", deviceID: store.deviceID()), token: "fixture-token")
        store.setActiveAccountIDs(["unrelated-account"])
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { _ in provider }
        let accounts = AccountsProvidersModel(accountStore: store, registry: registry, profilesModel: profiles)
        accounts.tokenResolver = { store.token(for: $0) }
        accounts.reloadAccounts()
        XCTAssertEqual(accounts.resolvedActiveAccounts.count, 1)
        let runtime = LiveTVLibraryRuntime(
            profileID: profiles.activeProfileID, profiles: profiles,
            definitionsStore: RuntimeLibraryDefinitions(),
            snapshotStore: LibraryChannelSnapshotStore(databaseURL: nil))

        await runtime.refresh(accounts: accounts)
        runtime.retry()
        await runtime.refresh(accounts: accounts)

        XCTAssertNil(runtime.issue)
        XCTAssertTrue(runtime.service.isLoaded)
        XCTAssertNotNil(runtime.authorizationID)
        XCTAssertTrue(runtime.unavailableAccountIDs.isEmpty)
        let callsWhileBrowsing = await provider.requests.count
        XCTAssertEqual(callsWhileBrowsing, 0)

        do {
            try await runtime.prepareForEditing()
            XCTFail("Explicit library editing must surface the unreachable server")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .sourceUnavailable)
        }
        let callsWhileEditing = await provider.requests.count
        XCTAssertEqual(callsWhileEditing, 1)
        XCTAssertEqual(runtime.unavailableAccountIDs, ["unrelated-account"])
        XCTAssertNil(runtime.issue, "Editor discovery failure must not turn into an IPTV guide error")
        XCTAssertNotNil(runtime.authorizationID, "An editor must not remove its own authorized host")
    }

    @MainActor
    func testNoConfiguredPlozzChannelsRequiresNoMediaServerDiscovery() {
        XCTAssertTrue(LiveTVLibraryRuntime.requiredDiscoveryAccountIDs(definitions: []).isEmpty)
    }

    @MainActor
    func testOnlyEnabledChannelDependenciesAreDiscovered() {
        var disabled = definition(accountID: "disabled-server")
        disabled.isEnabled = false
        XCTAssertEqual(LiveTVLibraryRuntime.requiredDiscoveryAccountIDs(
            definitions: [definition(accountID: "used-server"), disabled]), ["used-server"])
    }

    @MainActor
    func testRetainedScheduleDependenciesRemainAvailableForPlayback() {
        var channel = definition(accountID: "old-server")
        channel.revisions.append(revision(accountID: "new-server", epoch: 1_800_000_100))
        XCTAssertEqual(LiveTVLibraryRuntime.requiredDiscoveryAccountIDs(definitions: [channel]),
                       ["old-server", "new-server"])
    }

    @MainActor
    func testIPTVOnlyCatalogDoesNotReportUnrelatedLibraryDiscoveryFailure() {
        XCTAssertNil(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [], unavailableAccountIDs: ["offline-server"]))
    }

    @MainActor
    func testUnrelatedServerFailureDoesNotMarkAnAvailablePlozzChannelUnavailable() {
        XCTAssertNil(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [definition(accountID: "healthy-server")],
            unavailableAccountIDs: ["offline-server"]))
    }

    @MainActor
    func testEnabledChannelUsingFailedServerStillReportsItsLibraryFailure() {
        XCTAssertEqual(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [definition(accountID: "offline-server")],
            unavailableAccountIDs: ["offline-server"]), .sourceUnavailable)
    }

    @MainActor
    func testDisabledChannelDoesNotShowARetryWarningInTheGuide() {
        var channel = definition(accountID: "offline-server")
        channel.isEnabled = false
        XCTAssertNil(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [channel], unavailableAccountIDs: ["offline-server"]))
    }

    @MainActor
    func testRetainedOldRevisionDoesNotMakeAnUnrelatedAccountARequiredSource() {
        var channel = definition(accountID: "offline-server")
        channel.revisions.append(revision(accountID: "healthy-server", epoch: 1_800_000_100))
        XCTAssertNil(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [channel], unavailableAccountIDs: ["offline-server"]))
    }

    @MainActor
    func testDiscoveryRecoveryClearsOnlyTheAffectedLibraryWarning() {
        let channel = definition(accountID: "server")
        XCTAssertEqual(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [channel], unavailableAccountIDs: ["server"]), .sourceUnavailable)
        XCTAssertNil(LiveTVLibraryRuntime.catalogIssue(
            serviceIssue: nil, definitions: [channel], unavailableAccountIDs: []))
    }

    @MainActor
    func testActualScheduleAndStorageFailuresAreNeverHiddenByAnEmptyCatalog() {
        for error in [LibraryChannelError.snapshotUnavailable, .storageFailed, .authorizationChanged] {
            XCTAssertEqual(LiveTVLibraryRuntime.catalogIssue(
                serviceIssue: error, definitions: [], unavailableAccountIDs: ["offline-server"]), error)
        }
    }

    private func definition(accountID: String) -> LibraryChannelDefinition {
        LibraryChannelDefinition(
            profileID: "profile",
            revisions: [revision(accountID: accountID, epoch: 1_800_000_000)])
    }

    private func revision(accountID: String, epoch: Int64) -> LibraryChannelRevision {
        LibraryChannelRevision(
            snapshotID: UUID(),
            recipe: LibraryChannelRecipe(
                name: "Library channel",
                libraries: [LibraryChannelLibrary(accountID: accountID, libraryID: "movies")]),
            epochSeconds: epoch)
    }
}

private struct RuntimeLibraryDefinitions: LibraryChannelDefinitionStoring {
    func load() throws -> [LibraryChannelDefinition] { [] }
    func save(_ definitions: [LibraryChannelDefinition]) throws {
        guard definitions.isEmpty else { throw LibraryChannelError.storageFailed }
    }
}

private actor RuntimeLibraryRequests {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct RuntimeLibraryDiscoveryProvider: LibraryChannelCatalogProviding, LibraryChannelPlaybackProviding {
    let requests = RuntimeLibraryRequests()
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "fixture-server", name: "Unreachable library server",
            baseURL: URL(string: "https://example.invalid")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture-token")

    func libraries() async throws -> [MediaLibrary] {
        await requests.record()
        throw AppError.notFound
    }
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest { throw AppError.notFound }
    func recordLibraryChannelCompletion(itemID: String) async throws {}
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
