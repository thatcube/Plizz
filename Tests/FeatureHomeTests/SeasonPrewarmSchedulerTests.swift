import XCTest
import CoreModels
import FeatureHomeCore
@testable import FeatureHome

@MainActor
final class SeasonPrewarmSchedulerTests: XCTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "The expected scheduling event did not arrive")
    }

    func testNeighborMetadataSchedulingWhileFirstArtworkIsBlocked() async {
        let artwork = SeasonPrewarmGate()
        var loaded: [String] = []
        var warmed: [String] = []
        let task = Task {
            await SeasonPrewarmScheduler.run(
                seasonIDs: ["s2", "s3", "s4", "s5"],
                loadEpisodes: { loaded.append($0) },
                warmArtwork: {
                    warmed.append($0)
                    if $0 == "s2" { await artwork.wait() }
                }
            )
        }
        await waitUntil { loaded.count == 4 && warmed == ["s2"] }
        XCTAssertEqual(loaded, ["s2", "s3", "s4", "s5"])
        print("Issue56 season optimized: \(loaded.count)/4 neighboring lists loaded while first season artwork is blocked (baseline 1/4)")
        artwork.open()
        await task.value
        XCTAssertEqual(loaded, ["s2", "s3", "s4", "s5"])
        XCTAssertEqual(warmed, loaded)
    }

    func testFirstNeighborArtworkDoesNotWaitForAllMetadata() async {
        let metadata = SeasonPrewarmGate()
        var loaded: [String] = []
        var warmed: [String] = []
        let task = Task {
            await SeasonPrewarmScheduler.run(
                seasonIDs: ["s2", "s3", "s4"],
                loadEpisodes: {
                    loaded.append($0)
                    if $0 == "s3" { await metadata.wait() }
                },
                warmArtwork: { warmed.append($0) }
            )
        }
        await waitUntil { loaded == ["s2", "s3"] && warmed == ["s2"] }
        metadata.open()
        await task.value
        XCTAssertEqual(warmed, ["s2", "s3", "s4"])
    }

    private func fixture() async -> (FakeMediaProvider, ItemDetailViewModel) {
        let show = MediaItem(id: "show", title: "Show", kind: .series, overview: "Overview")
        let seasons = (1...5).map { (number: Int) in
            MediaItem(id: "s\(number)", title: "Season \(number)", kind: .season, seasonNumber: number)
        }
        let provider = FakeMediaProvider(allItems: [show])
        provider.childrenByParent = Dictionary(uniqueKeysWithValues: seasons.map { season in
            (season.id, [MediaItem(
                id: "\(season.id)-episode", title: "Episode", kind: .episode,
                seasonNumber: season.seasonNumber, episodeNumber: 1,
                seriesID: show.id, seasonID: season.id
            )])
        })
        provider.childrenByParent?[show.id] = seasons
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["s1", "s2", "s3", "s4", "s5"])
        return (provider, vm)
    }

    func testSelectedListGatesOnlyArtworkWhileNeighborsKeepLoading() async {
        let (provider, vm) = await fixture()
        let selected = SeasonPrewarmGate()
        provider.childrenGate = ["s1": { _ in await selected.wait() }]
        var warmed: [String] = []
        let task = Task {
            await SeasonPrewarmScheduler.run(
                seasonIDs: ["s2", "s3", "s4", "s5"],
                loadEpisodes: { await vm.loadEpisodes(for: $0) },
                warmArtwork: { id in
                    if await vm.prepareForSpeculativeSeasonArtwork(selectedSeasonID: { "s1" }) {
                        warmed.append(id)
                    }
                }
            )
        }
        await waitUntil {
            vm.episodes(for: "s5") != nil && provider.childrenCallCount["s1"] == 1
        }
        XCTAssertTrue(warmed.isEmpty)
        XCTAssertEqual(provider.childrenCallCount["s2"], 1)
        selected.open()
        await task.value
        XCTAssertEqual(warmed, ["s2", "s3", "s4", "s5"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
        vm.suspendEnrichment()
    }

    func testImmediateSelectionBypassesAnUnrelatedBlockedPreload() async {
        let (provider, vm) = await fixture()
        let background = SeasonPrewarmGate()
        provider.childrenGate = ["s2": { _ in await background.wait() }]
        let preload = Task {
            await SeasonPrewarmScheduler.run(
                seasonIDs: ["s2", "s3", "s4", "s5"],
                loadEpisodes: { await vm.loadEpisodes(for: $0) },
                warmArtwork: { _ in }
            )
        }
        await waitUntil { provider.childrenCallCount["s2"] == 1 }
        var selectedReady = false
        let selection = Task {
            await vm.loadEpisodes(for: "s4")
            selectedReady = true
        }
        await waitUntil { selectedReady }
        XCTAssertEqual(vm.episodes(for: "s4")?.first?.id, "s4-episode")
        XCTAssertNil(vm.episodes(for: "s2"))
        background.open()
        await selection.value
        await preload.value
        XCTAssertEqual(provider.childrenCallCount["s4"], 1)
        vm.suspendEnrichment()
    }

    func testSelectingAnInFlightNeighborReusesItEvenIfPrewarmingIsCancelled() async {
        let (provider, vm) = await fixture()
        let background = SeasonPrewarmGate()
        provider.childrenGate = ["s2": { _ in await background.wait() }]
        var warmed: [String] = []
        var preloadFinished = false
        let preload = Task {
            defer { preloadFinished = true }
            await SeasonPrewarmScheduler.run(
                seasonIDs: ["s2", "s3", "s4"],
                loadEpisodes: { await vm.loadEpisodes(for: $0) },
                warmArtwork: { warmed.append($0) }
            )
        }
        await waitUntil { provider.childrenCallCount["s2"] == 1 }
        var selectionStarted = false
        var selectedReady = false
        let selection = Task {
            selectionStarted = true
            await vm.loadEpisodes(for: "s2")
            selectedReady = true
        }
        await waitUntil { selectionStarted }
        preload.cancel()
        await waitUntil { preloadFinished }
        XCTAssertFalse(selectedReady)
        XCTAssertEqual(provider.childrenCallCount["s2"], 1)
        XCTAssertNil(provider.childrenCallCount["s3"])
        XCTAssertTrue(warmed.isEmpty)
        background.open()
        await selection.value
        await preload.value
        XCTAssertEqual(vm.episodes(for: "s2")?.first?.id, "s2-episode")
        XCTAssertEqual(provider.childrenCallCount["s2"], 1)
        vm.suspendEnrichment()
    }

    func testArtworkReadinessRechecksSelectionAfterWaiting() async {
        let (provider, vm) = await fixture()
        let first = SeasonPrewarmGate()
        let second = SeasonPrewarmGate()
        provider.childrenGate = [
            "s1": { _ in await first.wait() },
            "s4": { _ in await second.wait() }
        ]
        var selection = "s1"
        var artworkAdmitted = false
        let priority = Task {
            artworkAdmitted = await vm.prepareForSpeculativeSeasonArtwork(
                selectedSeasonID: { selection }
            )
        }
        await waitUntil { provider.childrenCallCount["s1"] == 1 }
        selection = "s4"
        first.open()
        await waitUntil { provider.childrenCallCount["s4"] == 1 }
        XCTAssertFalse(artworkAdmitted)
        second.open()
        await priority.value
        XCTAssertTrue(artworkAdmitted)
        vm.suspendEnrichment()
    }

    func testFailedSelectionDoesNotCauseArtworkRetryStorms() async {
        let (provider, vm) = await fixture()
        provider.childrenFailuresByParent = ["s1": [1]]
        await vm.loadEpisodes(for: "s1")
        var warmed: [String] = []
        await SeasonPrewarmScheduler.run(
            seasonIDs: ["s2", "s3"],
            loadEpisodes: { await vm.loadEpisodes(for: $0) },
            warmArtwork: { id in
                if await vm.prepareForSpeculativeSeasonArtwork(selectedSeasonID: { "s1" }) {
                    warmed.append(id)
                }
            }
        )
        XCTAssertTrue(warmed.isEmpty)
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
        XCTAssertNotNil(vm.episodes(for: "s2"))
        XCTAssertNotNil(vm.episodes(for: "s3"))
        vm.suspendEnrichment()
    }

    func testEmptyPrewarmPlanDoesNoWork() async {
        var calls: [String] = []
        await SeasonPrewarmScheduler.run(
            seasonIDs: [],
            loadEpisodes: { calls.append($0) },
            warmArtwork: { calls.append($0) }
        )
        XCTAssertTrue(calls.isEmpty)
    }
}

@MainActor
private final class SeasonPrewarmGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
