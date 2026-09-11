#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import FeatureLiveTVCore
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVAutomaticChannelsRuntimeTests: XCTestCase {
    func testOptInIsDurableScopedAndRejectsCorruptValues() throws {
        let secrets = InMemorySecureStore()
        let first = LiveTVAutomaticChannelsStore(secureStore: secrets, namespace: "first")
        let other = LiveTVAutomaticChannelsStore(secureStore: secrets, namespace: "other")
        XCTAssertFalse(try first.isEnabled())
        try first.setEnabled(true)
        XCTAssertTrue(try LiveTVAutomaticChannelsStore(secureStore: secrets, namespace: "first").isEnabled())
        XCTAssertFalse(try other.isEnabled())
        try secrets.setString(
            "invalid", for: SettingsKey.scoped("com.plozz.liveTV.automaticChannels", namespace: "first"))
        XCTAssertThrowsError(try first.isEnabled())
    }

    func testWholeLibraryNeedsOnlyOneOptInAndSurvivesRelaunch() async throws {
        for kind in [ProviderKind.jellyfin, .plex, .emby] {
            let fixture = try Fixture(kind: kind)
            defer { fixture.close() }
            let runtime = fixture.runtime()
            await runtime.refresh(accounts: fixture.accounts)
            XCTAssertNil(runtime.issue)
            XCTAssertFalse(runtime.automaticChannelsEnabled)
            let initialRequests = await fixture.provider.requests.count
            XCTAssertEqual(initialRequests, 0)

            await runtime.setAutomaticChannelsEnabled(true)
            await runtime.refresh(accounts: fixture.accounts)

            XCTAssertTrue(runtime.automaticChannelsEnabled)
            XCTAssertNil(runtime.automaticChannelsIssue)
            XCTAssertGreaterThan(runtime.automaticChannelCount, 0)
            XCTAssertTrue(runtime.service.definitions.allSatisfy(\.isAutomatic))
            let ids = runtime.service.definitions.map(\.id)
            let revisions = runtime.service.definitions.map(\.revisions)
            let channel = try XCTUnwrap(runtime.service.channels.first)
            let programmes = try runtime.service.programmes(
                channelIDs: [channel.id], from: Date(), to: Date().addingTimeInterval(3_600))
            XCTAssertFalse(programmes.isEmpty)

            let restored = fixture.runtime()
            await restored.refresh(accounts: fixture.accounts)
            XCTAssertTrue(restored.automaticChannelsEnabled)
            XCTAssertNil(restored.automaticChannelsIssue)
            XCTAssertEqual(restored.service.definitions.map(\.id), ids)
            XCTAssertEqual(restored.service.definitions.map(\.revisions), revisions)
        }
    }

    func testDisablingStopsDiscoveryAndRevokesPlaybackWithoutDeletingChannels() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = fixture.runtime()
        await runtime.refresh(accounts: fixture.accounts)
        await runtime.setAutomaticChannelsEnabled(true)
        await runtime.refresh(accounts: fixture.accounts)
        let channel = try XCTUnwrap(runtime.service.channels.first)
        let held = try runtime.service.playbackContext(catalogID: channel.id)
        let ids = runtime.service.definitions.map(\.id)
        let queries = await fixture.provider.requests.count

        await runtime.setAutomaticChannelsEnabled(false)
        XCTAssertNil(held.authorizationID)
        await runtime.refresh(accounts: fixture.accounts)
        XCTAssertFalse(runtime.automaticChannelsEnabled)
        XCTAssertEqual(runtime.automaticChannelCount, 0)
        XCTAssertEqual(runtime.service.definitions.map(\.id), ids)
        XCTAssertTrue(runtime.service.channels.isEmpty)
        let queriesWhileDisabled = await fixture.provider.requests.count
        XCTAssertEqual(queriesWhileDisabled, queries)

        await runtime.setAutomaticChannelsEnabled(true)
        await runtime.refresh(accounts: fixture.accounts)
        XCTAssertNil(runtime.automaticChannelsIssue)
        XCTAssertEqual(runtime.service.definitions.map(\.id), ids)
        XCTAssertGreaterThan(runtime.automaticChannelCount, 0)
    }

    func testEnabledDiscoveryFailureIsScopedAndRetryRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = fixture.runtime()
        await runtime.refresh(accounts: fixture.accounts)
        await fixture.provider.requests.setUnavailable(true)
        await runtime.setAutomaticChannelsEnabled(true)
        await runtime.refresh(accounts: fixture.accounts)
        XCTAssertEqual(runtime.automaticChannelsIssue, .sourceUnavailable)
        XCTAssertNil(runtime.issue, "Automatic lineup errors must not present IPTV as a broken library channel")
        XCTAssertNotNil(runtime.authorizationID)
        XCTAssertTrue(runtime.automaticChannelsEnabled, "A failed preparation must remain retryable")

        await fixture.provider.requests.setUnavailable(false)
        runtime.retry()
        await runtime.refresh(accounts: fixture.accounts)
        XCTAssertNil(runtime.automaticChannelsIssue)
        XCTAssertGreaterThan(runtime.automaticChannelCount, 0)
    }

    func testUnchangedAutomaticRefreshPreservesHeldPlaybackAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = fixture.runtime()
        await runtime.refresh(accounts: fixture.accounts)
        await runtime.setAutomaticChannelsEnabled(true)
        await runtime.refresh(accounts: fixture.accounts)
        let channel = try XCTUnwrap(runtime.service.channels.first)
        let held = try runtime.service.playbackContext(catalogID: channel.id)
        let authorization = try XCTUnwrap(held.authorizationID)
        let runtimeAuthorization = runtime.authorizationID

        runtime.retry()
        await runtime.refresh(accounts: fixture.accounts)

        XCTAssertNil(runtime.automaticChannelsIssue)
        XCTAssertEqual(held.authorizationID, authorization)
        XCTAssertEqual(runtime.authorizationID, runtimeAuthorization)
    }

    func testChangedProfileCannotEnableAnotherProfilesLineup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = fixture.runtime()
        await runtime.refresh(accounts: fixture.accounts)
        let other = fixture.profiles.add(name: "Other")
        fixture.profiles.select(other.id)

        await runtime.setAutomaticChannelsEnabled(true)

        XCTAssertEqual(runtime.automaticChannelsIssue, .authorizationChanged)
        XCTAssertFalse(try fixture.settings.isEnabled())
        let queries = await fixture.provider.requests.count
        XCTAssertEqual(queries, 0)
    }

    func testCorruptOptInDoesNotContactLibrariesOrHideItsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.secrets.setString(
            "invalid", for: SettingsKey.scoped("com.plozz.liveTV.automaticChannels", namespace: fixture.suite))
        let runtime = fixture.runtime()
        await runtime.refresh(accounts: fixture.accounts)

        XCTAssertFalse(runtime.automaticChannelsEnabled)
        XCTAssertEqual(runtime.automaticChannelsIssue, .storageFailed)
        XCTAssertNil(runtime.issue)
        let queries = await fixture.provider.requests.count
        XCTAssertEqual(queries, 0)
    }

    func testOptInWriteFailureDoesNotStartDiscoveryOrShowEnabled() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = LiveTVLibraryRuntime(
            profileID: fixture.profiles.activeProfileID, profiles: fixture.profiles,
            definitionsStore: fixture.definitions, snapshotStore: fixture.snapshots,
            automaticSettingsStore: FailingAutomaticOptInStore())
        await runtime.refresh(accounts: fixture.accounts)
        await runtime.setAutomaticChannelsEnabled(true)

        XCTAssertFalse(runtime.automaticChannelsEnabled)
        XCTAssertEqual(runtime.automaticChannelsIssue, .storageFailed)
        let queries = await fixture.provider.requests.count
        XCTAssertEqual(queries, 0)
    }

    func testEmptyLibraryRemainsEnabledWithAnActionablePreparationFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let runtime = fixture.runtime()
        await fixture.provider.requests.setEmpty(true)
        await runtime.refresh(accounts: fixture.accounts)
        await runtime.setAutomaticChannelsEnabled(true)
        await runtime.refresh(accounts: fixture.accounts)

        XCTAssertTrue(runtime.automaticChannelsEnabled)
        XCTAssertEqual(runtime.automaticChannelsIssue, .emptyCatalog)
        XCTAssertNil(runtime.issue)
        XCTAssertEqual(runtime.automaticChannelCount, 0)
    }

    @MainActor
    private final class Fixture {
        let suite = "LiveTVAutomaticChannelsRuntimeTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let profileStore: ProfileStore
        let profiles: ProfilesModel
        let secrets = InMemorySecureStore()
        let provider: AutomaticRuntimeProvider
        let accounts: AccountsProvidersModel
        let definitions: LibraryChannelDefinitionStore
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        let settings: LiveTVAutomaticChannelsStore

        init(kind: ProviderKind = .jellyfin) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            profileStore = ProfileStore(defaults: defaults)
            profiles = ProfilesModel(store: profileStore)
            provider = AutomaticRuntimeProvider(kind: kind)
            let accountStore = AccountStore(secureStore: secrets)
            try accountStore.add(Account(
                id: "catalog", server: provider.session.server, userID: "user",
                userName: "User", deviceID: accountStore.deviceID()), token: "fixture-token")
            accountStore.setActiveAccountIDs(["catalog"])
            let registry = ProviderRegistry()
            let provider = provider
            registry.register(kind) { _ in provider }
            accounts = AccountsProvidersModel(
                accountStore: accountStore, registry: registry, profilesModel: profiles)
            accounts.tokenResolver = { accountStore.token(for: $0) }
            accounts.reloadAccounts()
            definitions = LibraryChannelDefinitionStore(secureStore: secrets, namespace: suite)
            settings = LiveTVAutomaticChannelsStore(secureStore: secrets, namespace: suite)
        }

        func runtime() -> LiveTVLibraryRuntime {
            LiveTVLibraryRuntime(
                profileID: profiles.activeProfileID, profiles: profiles, definitionsStore: definitions,
                snapshotStore: snapshots, automaticSettingsStore: settings)
        }

        func close() { defaults.removePersistentDomain(forName: suite) }
    }
}

private actor AutomaticRuntimeRequests {
    private(set) var count = 0
    private(set) var empty = false
    private var unavailable = false
    func setEmpty(_ value: Bool) { empty = value }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func record() throws {
        count += 1
        if unavailable { throw AppError.notFound }
    }
}

private struct FailingAutomaticOptInStore: LiveTVAutomaticChannelsStoring {
    func isEnabled() throws -> Bool { false }
    func setEnabled(_ enabled: Bool) throws { throw LibraryChannelError.storageFailed }
}

private struct AutomaticRuntimeProvider: LibraryChannelCatalogProviding, LibraryChannelPlaybackProviding {
    let requests = AutomaticRuntimeRequests()
    let kind: ProviderKind
    var session: UserSession {
        UserSession(
            server: MediaServer(
                id: "fixture-server", name: "Library", baseURL: URL(string: "https://example.invalid")!,
                provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture-token")
    }

    func libraries() async throws -> [MediaLibrary] {
        try await requests.record()
        return [MediaLibrary(id: "movies", title: "Movies", kind: .movie)]
    }

    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await requests.record()
        let isEmpty = await requests.empty
        let items: [MediaItem] = kind == .movie && !isEmpty ? (0..<12).map { index in
            var item = MediaItem(id: "movie-\(index)", title: "Movie \(index)", kind: .movie, runtime: 3_600)
            item.libraryID = libraryID
            item.productionYear = 1990 + index
            item.genres = ["Comedy"]
            item.officialRating = "PG"
            return item
        } : []
        return MediaPage(
            items: Array(items.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: items.count)
    }

    func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest { throw AppError.notFound }
    func recordLibraryChannelCompletion(itemID: String) async throws {}
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await libraryChannelItems(in: containerID, kind: kind, page: page)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
