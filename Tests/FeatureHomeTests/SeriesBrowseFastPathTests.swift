import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class SeriesBrowseFastPathTests: XCTestCase {
    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        ResolvedAccount(
            account: Account(
                id: id, server: provider.session.server,
                userID: provider.session.userID, userName: "User", deviceID: "device"
            ),
            provider: provider
        )
    }

    private func episode(_ id: String, seriesID: String) -> MediaItem {
        MediaItem(
            id: id, title: "Episode", kind: .episode,
            seasonNumber: 4, episodeNumber: 3, seriesID: seriesID,
            seasonID: "season-4", resumePosition: 120
        )
    }

    func testHomeBatchesParentIDsAcrossRowsWithoutLosingCrossServerMerging() async throws {
        let first = FakeMediaProvider(allItems: [], kind: .emby, accountID: "first")
        let second = FakeMediaProvider(allItems: [], kind: .jellyfin, accountID: "second")
        let firstEpisode = episode("first-episode", seriesID: "first-show")
        let secondEpisode = episode("second-episode", seriesID: "second-show")
        first.continueWatchingItems = [firstEpisode]
        second.continueWatchingItems = [secondEpisode]
        let firstProvider = FastBrowseProvider(
            base: first, latestItems: [firstEpisode],
            identities: .success(["first-show": ["Tvdb": "100"]])
        )
        let secondProvider = FastBrowseProvider(
            base: second, latestItems: [secondEpisode],
            identities: .success(["second-show": ["Tvdb": "100"]])
        )
        let content = await HomeAggregator().content(from: [
            resolved("first", provider: firstProvider),
            resolved("second", provider: secondProvider)
        ])

        XCTAssertEqual(content.continueWatching.count, 1)
        XCTAssertEqual(content.latest.count, 1)
        for item in content.continueWatching + content.latest {
            XCTAssertEqual(item.providerIDs["SeriesTvdb"], "100")
            XCTAssertEqual(Set(item.sources.map(\.itemID)), ["first-episode", "second-episode"])
            XCTAssertEqual(Set(item.sources.map(\.accountID)), ["first", "second"])
        }
        let firstBatches = await firstProvider.calls.identityBatches
        let secondBatches = await secondProvider.calls.identityBatches
        XCTAssertEqual(firstBatches, [["first-show"]])
        XCTAssertEqual(secondBatches, [["second-show"]])
        XCTAssertTrue(first.itemCallCounts.isEmpty)
        XCTAssertTrue(second.itemCallCounts.isEmpty)
    }

    func testHomeFallsBackToExistingDetailsWhenBatchLookupFails() async {
        let show = MediaItem(id: "show", title: "Show", kind: .series, providerIDs: ["Tvdb": "100"])
        let base = FakeMediaProvider(allItems: [show])
        base.continueWatchingItems = [episode("episode", seriesID: show.id)]
        let provider = FastBrowseProvider(base: base, identities: .failure(.notFound))
        let content = await HomeAggregator().content(from: [resolved("account", provider: provider)])
        XCTAssertEqual(content.continueWatching.first?.providerIDs["SeriesTvdb"], "100")
        XCTAssertEqual(base.itemCallCounts, ["show": 1])
        let batches = await provider.calls.identityBatches
        XCTAssertEqual(batches, [["show"]])
    }

    func testHomeCancellationDoesNotStartFullDetailFallback() async {
        let base = FakeMediaProvider(allItems: [])
        base.continueWatchingItems = [episode("episode", seriesID: "show")]
        let provider = FastBrowseProvider(base: base, identities: .failure(.cancelled))
        _ = await HomeAggregator().content(from: [resolved("account", provider: provider)])
        XCTAssertTrue(base.itemCallCounts.isEmpty)
    }

    func testHomeProvidersWithoutBatchCapabilityKeepTheirExistingIdentityLookup() async {
        let show = MediaItem(id: "show", title: "Show", kind: .series, providerIDs: ["Tvdb": "100"])
        let provider = FakeMediaProvider(allItems: [show], kind: .plex)
        provider.continueWatchingItems = [episode("episode", seriesID: show.id)]
        let content = await HomeAggregator().content(from: [resolved("account", provider: provider)])
        XCTAssertEqual(content.continueWatching.first?.providerIDs["SeriesTvdb"], "100")
        XCTAssertEqual(provider.itemCallCounts, ["show": 1])
    }

    func testDetailUsesFreshScopedResumeWithoutRequestingTheGlobalFeed() async {
        let show = MediaItem(id: "show", title: "Show", kind: .series, overview: "Overview")
        let season = MediaItem(id: "season-4", title: "Season 4", kind: .season, seasonNumber: 4)
        let base = FakeMediaProvider(allItems: [show], kind: .emby)
        base.childrenByParent = [show.id: [season]]
        let provider = FastBrowseProvider(
            base: base, resume: .success(episode("resume", seriesID: show.id))
        )
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            sourceAccountID: "account",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()
        XCTAssertEqual(vm.serverResumeEpisode?.id, "resume")
        XCTAssertEqual(vm.serverResumeEpisode?.resumePosition, 120)
        XCTAssertEqual(vm.serverResumeEpisode?.seasonNumber, 4)
        XCTAssertEqual(vm.serverResumeEpisode?.sourceAccountID, "account")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["season-4"])
        let requests = await provider.calls.resumeSeries
        let global = await provider.calls.globalResumeRequests
        XCTAssertEqual(requests, ["show"])
        XCTAssertEqual(global, 0)
        vm.suspendEnrichment()
    }

    func testDetailRejectsAnUnrelatedScopedResumeAnswer() async {
        let show = MediaItem(id: "show", title: "Show", kind: .series, overview: "Overview")
        let base = FakeMediaProvider(allItems: [show])
        base.childrenByParent = [show.id: []]
        let provider = FastBrowseProvider(
            base: base, resume: .success(episode("wrong", seriesID: "other-show"))
        )
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()
        XCTAssertNil(vm.serverResumeEpisode)
        vm.suspendEnrichment()
    }
}

private actor BrowseCalls {
    var identityBatches: [[String]] = []
    var resumeSeries: [String] = []
    var globalResumeRequests = 0

    func recordBatch(_ ids: [String]) { identityBatches.append(ids) }
    func recordSeries(_ id: String) { resumeSeries.append(id) }
    func recordGlobalResume() { globalResumeRequests += 1 }
}

private struct FastBrowseProvider: MediaProvider, SeriesResumeProviding, SeriesIdentityProviding {
    let base: FakeMediaProvider
    var latestItems: [MediaItem] = []
    var identities: Result<[String: [String: String]], AppError> = .success([:])
    var resume: Result<MediaItem?, AppError> = .success(nil)
    let calls = BrowseCalls()
    var kind: ProviderKind { base.kind }
    var session: UserSession { base.session }

    func seriesProviderIDs(for seriesIDs: [String]) async throws -> [String: [String: String]] {
        await calls.recordBatch(seriesIDs)
        return try identities.get()
    }

    func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem? {
        await calls.recordSeries(seriesID)
        return try resume.get()
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        await calls.recordGlobalResume()
        return try await base.continueWatching(limit: limit)
    }

    func libraries() async throws -> [MediaLibrary] { try await base.libraries() }
    func latest(limit: Int) async throws -> [MediaItem] { Array(latestItems.prefix(limit)) }
    func item(id: String) async throws -> MediaItem { try await base.item(id: id) }
    func children(of itemID: String) async throws -> [MediaItem] { try await base.children(of: itemID) }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await base.items(in: containerID, kind: kind, page: page)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
