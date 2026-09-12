import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVServerImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRuntimeChannelReferenceEqualityIncludesCatalogAuthorization() {
        let original = LiveTVServerChannelReference(
            sourceID: "server", accountID: "account", authorizationID: "profile-one", channelID: "native"
        )
        let changed = LiveTVServerChannelReference(
            sourceID: "server", accountID: "account", authorizationID: "profile-two", channelID: "native"
        )
        XCTAssertNotEqual(original, changed)
        XCTAssertEqual(original.authorizationID, "profile-one")
    }

    func testEmptyOrDisabledSetupNeverResolvesProvidersOrFetchesAnySource() async {
        for servers in [[], [source(isEnabled: false)]] {
            let authorization = ServerAuthorizationFixture()
            let loader = ServerMixPlaylistLoader()
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: servers), loader: loader,
                serverProviderResolver: { authorization.resolve($0) }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertTrue(authorization.resolvedAccountIDs.isEmpty)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertEqual(imports.catalogPhase, .idle)
            XCTAssertFalse(imports.isLoading)
            let calls = await loader.playlistLoads
            XCTAssertEqual(calls, 0)
        }
    }

    func testMixedCatalogUsesNativeServerChannelIDsAndNeverXMLTVNameMatching() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "iptv", name: "Playlist", playlistURL: URL(string: "https://example.test/list.m3u")!,
            guideURLs: [URL(string: "https://example.test/guide.xml")!]
        )
        let server = source()
        let native = [
            ServerLiveTVChannel(id: "one", name: "Identical name"),
            ServerLiveTVChannel(id: "two", name: "Identical name")
        ]
        let provider = ServerImportProvider(
            channels: native, programs: [program(id: "airing", channelID: "two", title: "Native second channel")]
        )
        let loader = ServerMixPlaylistLoader()
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist], servers: [server]), loader: loader,
            serverProviderResolver: { $0 == server.accountID ? context : nil }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 3)
        XCTAssertEqual(imports.catalogPhase, .loaded)
        let first = try XCTUnwrap(imports.serverChannelReferences.first { $0.value.channelID == "one" }?.key)
        let second = try XCTUnwrap(imports.serverChannelReferences.first { $0.value.channelID == "two" }?.key)
        XCTAssertNil(model.currentProgram(for: first))
        XCTAssertEqual(model.currentProgram(for: second)?.title, "Native second channel")
        XCTAssertNil(imports.selectedSourceByChannel[second])
        XCTAssertEqual(imports.configuredSourceIDByChannel[second], server.id)
        XCTAssertEqual(imports.serverChannelReferences[second]?.authorizationID, context.authorizationID)
        XCTAssertEqual(model.channel(id: second)?.configuredSourceID, server.id)
        XCTAssertNil(model.channel(id: second)?.streamURL)
        model.configuredSourceID = server.id
        XCTAssertEqual(model.visibleChannels.count, 2)
        model.source = .iptv
        XCTAssertTrue(model.visibleChannels.isEmpty)
        let submitted = await loader.submittedGuideSources
        XCTAssertEqual(submitted, [.iptv])
        let calls = await provider.calls
        XCTAssertEqual(calls.guideChannelIDs, ["one", "two"])
        XCTAssertEqual(calls.opens, 0)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
    }

    func testSameProviderIDsAreNamespacedBySourceAndAccountAndNamesNeverChangeIdentity() async throws {
        let first = source(id: "first", accountID: "one")
        let second = source(id: "second", accountID: "two")
        let firstProvider = ServerImportProvider(channels: [channel()], programs: [program()])
        let secondProvider = ServerImportProvider(channels: [channel()], programs: [program()])
        let contexts = [
            first.accountID: authorized(first, firstProvider),
            second.accountID: authorized(second, secondProvider, kind: .plex)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, 2)
        let programs = try model.channels.map { try XCTUnwrap(model.currentProgram(for: $0.id)) }
        XCTAssertEqual(Set(programs.map(\.id)).count, 2)
        let ids = Set(model.channels.map(\.id))
        let favorite = try XCTUnwrap(model.channels.first?.id)
        model.toggleFavorite(favorite)
        var renamed = first
        renamed.name = "Renamed server"
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [second, renamed]), into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), ids)
        XCTAssertTrue(model.favoriteIDs.contains(favorite))
        XCTAssertEqual(imports.serverSources.last?.source.name, renamed.name)
        let calls = await firstProvider.calls
        XCTAssertEqual(calls.catalogs, 1)
    }

    func testNoTunerNoChannelsAndTransportFailureAreDistinctWithoutSyntheticChannels() async {
        for status in [
            ServerLiveTVAvailability.Status.notConfigured, .noChannels, .serviceUnavailable, .permissionDenied
        ] {
            let server = source()
            let provider = ServerImportProvider(
                availability: ServerLiveTVAvailability(status: status), channels: [channel()]
            )
            let context = authorized(server, provider)
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [server]),
                serverProviderResolver: { _ in context }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertEqual(imports.serverSources[0].availability?.status, status)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertEqual(imports.serverSources[0].failure, status == .serviceUnavailable ? .serviceUnavailable
                : (status == .permissionDenied ? .permissionDenied : nil))
            XCTAssertFalse(imports.isLoading)
            let calls = await provider.calls
            XCTAssertEqual(calls.catalogs, 0)
            XCTAssertEqual(calls.opens, 0)
        }
    }

    func testNoGuideRetainsAuthoritativeCurrentProgrammeWithoutCallingGuideEndpoint() async throws {
        let server = source()
        let current = program()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .available, channelCount: 1, supportsGuide: false),
            channels: [ServerLiveTVChannel(id: "native", name: "Native", currentProgramme: current)]
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let imported = try XCTUnwrap(model.channels.first)
        XCTAssertEqual(model.currentProgram(for: imported.id)?.title, current.title)
        XCTAssertEqual(imports.serverSources[0].guidePhase, .idle)
        XCTAssertEqual(imports.gapState(for: imported), .disabled)
        let calls = await provider.calls
        XCTAssertEqual(calls.guides, 0)
    }

    func testEmptyNativeCatalogReportsNoChannelsRatherThanATunerOrTransportFailure() async {
        let server = source()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .available, channelCount: 1), channels: []
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .noChannels)
        XCTAssertNil(imports.serverSources[0].failure)
        XCTAssertFalse(imports.serverSources[0].supportsPlayback)
    }

    func testDisablingAndReenablingServerPreservesOtherSourcesAndStableReferences() async throws {
        let first = source(id: "one", accountID: "one")
        let second = source(id: "two", accountID: "two")
        let providerOne = ServerImportProvider(channels: [channel()])
        let providerTwo = ServerImportProvider(channels: [channel()])
        let contexts = [
            first.accountID: authorized(first, providerOne), second.accountID: authorized(second, providerTwo)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let original = Set(model.channels.map(\.id))
        model.configuredSourceID = first.id
        try imports.setServerEnabled(first.id, enabled: false, into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertNil(model.configuredSourceID)
        XCTAssertEqual(Set(imports.serverChannelReferences.values.map(\.sourceID)), [second.id])
        try imports.setServerEnabled(first.id, enabled: true, into: model)
        await imports.reloadServers(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), original)
    }

    func testUnsupportedPlaybackStillExposesNativeMetadataWithoutOpeningATuner() async {
        let server = source()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .unsupportedPlaybackMode, channelCount: 1),
            channels: [channel()], programs: [program()]
        )
        let context = authorized(server, provider, kind: .plex)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .unsupportedPlaybackMode)
        XCTAssertEqual(imports.serverSources[0].availability?.supportsPlayback, false)
        let calls = await provider.calls
        XCTAssertEqual(calls.opens, 0)
    }

    func testGuideFailurePreservesLastGoodNativeScheduleAndRejectsUnknownChannelAssociations() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program(title: "Last good")])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let id = try XCTUnwrap(model.channels.first?.id)
        await provider.replaceGuide([program(channelID: "not-in-catalog", title: "Wrong channel")])
        await imports.reloadServers(into: model)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "Last good")
        XCTAssertEqual(imports.serverSources[0].guideFailure, .invalidGuide)
        XCTAssertEqual(imports.serverSources[0].phase, .loaded)
        XCTAssertEqual(imports.serverSources[0].guidePhase, .failed)
        XCTAssertNotNil(imports.serverSources[0].lastGuideRefresh)
    }

    func testTransientServerOutageKeepsLastGoodButExplicitNoChannelsClearsOnlyThatSource() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program()])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let original = model.channels
        await provider.setAvailability(ServerLiveTVAvailability(status: .serviceUnavailable))
        await imports.reloadServers(into: model)
        XCTAssertEqual(model.channels, original)
        XCTAssertEqual(imports.serverSources[0].failure, .serviceUnavailable)
        await provider.setAvailability(ServerLiveTVAvailability(status: .noChannels))
        await imports.reloadServers(into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(imports.serverSources[0].failure)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .noChannels)
    }

    func testRemovingAnotherSourceDoesNotDiscardAnUnrelatedServerRequestInFlight() async throws {
        let first = source(id: "one", accountID: "one")
        let second = source(id: "two", accountID: "two")
        let started = expectation(description: "Second catalog suspended")
        let providerOne = ServerImportProvider(channels: [channel()])
        let providerTwo = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let contexts = [
            first.accountID: authorized(first, providerOne),
            second.accountID: authorized(second, providerTwo)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [second]), into: model)
        await providerTwo.resume()
        await task.value
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(Set(imports.configuredSourceIDByChannel.values), [second.id])
        XCTAssertEqual(imports.serverSources[0].phase, .loaded)
    }

    func testRemovingTheLoadingServerFencesLateCatalogWithoutRemovingPlaylistChannels() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "iptv", name: "Playlist", playlistURL: URL(string: "https://example.test/list.m3u")!
        )
        let server = source()
        let started = expectation(description: "Catalog suspended")
        let provider = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist], servers: [server]),
            loader: ServerMixPlaylistLoader(), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [playlist]), into: model)
        await provider.resume()
        await task.value
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(model.channels[0].source, .iptv)
        XCTAssertTrue(imports.serverChannelReferences.isEmpty)
        XCTAssertFalse(imports.isLoading)
    }

    func testChangingAccountNamespacesChannelsAndFencesOldGuideResults() async throws {
        let server = source(accountID: "old-account")
        var replacement = server
        replacement.accountID = "new-account"
        let started = expectation(description: "Old guide suspended")
        let old = ServerImportProvider(
            channels: [channel()], programs: [program(title: "Old account")], suspended: .guide, started: started
        )
        let fresh = ServerImportProvider(channels: [channel()], programs: [program(title: "New account")])
        let contexts = [server.accountID: authorized(server, old), replacement.accountID: authorized(replacement, fresh)]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        let oldID = try XCTUnwrap(model.channels.first?.id)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [replacement]), into: model)
        await imports.reloadServers(into: model)
        await old.resume()
        await task.value
        let freshID = try XCTUnwrap(model.channels.first?.id)
        XCTAssertNotEqual(oldID, freshID)
        XCTAssertEqual(model.currentProgram(for: freshID)?.title, "New account")
        XCTAssertEqual(imports.serverChannelReferences[freshID]?.accountID, replacement.accountID)
    }

    func testProfileAuthorizationRevocationClearsCachedCatalogSynchronouslyAndHasNoHouseholdFallback() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program()])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        model.tune(try XCTUnwrap(model.channels.first?.id))
        try imports.setServerProviderResolver({ _ in nil }, into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.playingChannelID)
        XCTAssertTrue(imports.serverChannelReferences.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        await imports.reloadServers(into: model)
        let calls = await provider.calls
        XCTAssertEqual(calls.catalogs, 1)
    }

    func testProfileIdentityChangeDuringAwaitRejectsOldResultsEvenWithoutReplacingResolver() async throws {
        let server = source()
        let started = expectation(description: "Old profile catalog suspended")
        let provider = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let authorization = ServerAuthorizationFixture()
        authorization.contexts[server.accountID] = authorized(server, provider, authorizationID: "profile-one")
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]),
            serverProviderResolver: { authorization.resolve($0) }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        authorization.contexts[server.accountID] = authorized(server, provider, authorizationID: "profile-two")
        await provider.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        XCTAssertFalse(imports.isLoading)
    }

    func testResolverCannotReturnAnotherAccountsProvider() async {
        let configured = source(accountID: "configured")
        let unauthorized = source(accountID: "household")
        let provider = ServerImportProvider(channels: [channel()])
        let context = authorized(unauthorized, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [configured]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        let calls = await provider.calls
        XCTAssertEqual(calls.availability, 0)
    }

    func testCancellationAtEveryServerBoundaryCannotPublishLateDataOrFakeAFailure() async {
        for boundary in [ServerImportProvider.Boundary.availability, .channels, .guide] {
            let server = source()
            let started = expectation(description: "Server request suspended")
            let provider = ServerImportProvider(
                channels: [channel()], programs: [program()], suspended: boundary, started: started
            )
            let context = authorized(server, provider)
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
            )
            let model = LiveTVPrototypeModel(now: now, channels: [])
            let task = Task { await imports.reload(into: model) }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            await provider.resume()
            await task.value
            XCTAssertEqual(model.channels.count, boundary == .guide ? 1 : 0)
            XCTAssertEqual(imports.programCount, 0)
            XCTAssertNil(imports.serverSources[0].failure)
            XCTAssertNil(imports.serverSources[0].guideFailure)
            XCTAssertFalse(imports.isLoading)
        }
    }

    private func source(
        id: String = "server", accountID: String = "account", isEnabled: Bool = true
    ) -> LiveTVServerSource {
        LiveTVServerSource(id: id, name: id, accountID: accountID, isEnabled: isEnabled)
    }

    private func channel() -> ServerLiveTVChannel {
        ServerLiveTVChannel(id: "native", name: "Native channel", number: "7")
    }

    private func program(
        id: String = "airing", channelID: String = "native", title: String = "Native programme"
    ) -> ServerLiveTVProgramme {
        ServerLiveTVProgramme(
            id: id, channelID: channelID, title: title,
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(3_600)
        )
    }

    private func authorized(
        _ source: LiveTVServerSource, _ provider: ServerImportProvider,
        kind: LiveTVPrototypeSource = .jellyfin, authorizationID: String = "active-profile"
    ) -> LiveTVAuthorizedServerProvider {
        LiveTVAuthorizedServerProvider(
            accountID: source.accountID, authorizationID: authorizationID, kind: kind, provider: provider
        )
    }
}

@MainActor
private final class ServerAuthorizationFixture {
    var contexts: [String: LiveTVAuthorizedServerProvider] = [:]
    var resolvedAccountIDs: [String] = []
    func resolve(_ accountID: String) -> LiveTVAuthorizedServerProvider? {
        resolvedAccountIDs.append(accountID)
        return contexts[accountID]
    }
}

private actor ServerMixPlaylistLoader: LiveTVSourceLoading {
    private(set) var playlistLoads = 0
    private(set) var submittedGuideSources: [LiveTVPrototypeSource] = []

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        playlistLoads += 1
        return try LiveTVPlaylistParser().parse("""
            #EXTM3U
            #EXTINF:-1 tvg-id="two",Identical name
            https://example.test/live.m3u8
            """)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        submittedGuideSources += channels.map(\.source)
        return LiveTVGuideImport(
            programs: [], matchedChannelCount: 0, guideChannelCount: 0, programCount: 0,
            coverageStart: nil, coverageEnd: nil
        )
    }
}

private actor ServerImportProvider: ServerLiveTVProviding {
    enum Boundary: Equatable { case availability, channels, guide }
    var availability: ServerLiveTVAvailability
    let channels: [ServerLiveTVChannel]
    var programs: [ServerLiveTVProgramme]
    var suspended: Boundary?
    let started: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = (
        availability: 0, catalogs: 0, guides: 0, opens: 0, guideChannelIDs: [String]()
    )

    init(
        availability: ServerLiveTVAvailability? = nil, channels: [ServerLiveTVChannel],
        programs: [ServerLiveTVProgramme] = [], suspended: Boundary? = nil, started: XCTestExpectation? = nil
    ) {
        self.availability = availability ?? ServerLiveTVAvailability(status: .available, channelCount: channels.count)
        self.channels = channels
        self.programs = programs
        self.suspended = suspended
        self.started = started
    }

    func setAvailability(_ value: ServerLiveTVAvailability) { availability = value }
    func replaceGuide(_ value: [ServerLiveTVProgramme]) { programs = value }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        calls.availability += 1
        await waitIfSuspended(.availability)
        return availability
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        calls.catalogs += 1
        await waitIfSuspended(.channels)
        return channels
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        calls.guides += 1
        calls.guideChannelIDs = channelIDs
        await waitIfSuspended(.guide)
        return programs
    }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        calls.opens += 1
        throw ServerLiveTVError.unsupportedPlaybackMode
    }

    private func waitIfSuspended(_ boundary: Boundary) async {
        guard suspended == boundary else { return }
        suspended = nil
        await withCheckedContinuation {
            continuation = $0
            started?.fulfill()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
