import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies `HomeViewModel.reenrich()` — the in-place re-fold that runs when the
/// cross-server identity index warms further (a new account finishes indexing).
///
/// The bug it fixes: a Continue Watching card that cold-loaded before its local
/// twin was known kept an incomplete `sources` set for the whole session, so
/// play-time locality selection had no local copy to route to. `reenrich()` must
/// fold the freshly-discovered sources into the already-loaded cards *in place*
/// (no refetch), and must be a true no-op when nothing new was discovered.
@MainActor
final class HomeViewModelReenrichTests: XCTestCase {
    /// Thread-safe, mutable identity-sources lookup so a test can flip what the
    /// index "knows" between the initial load and the re-enrich.
    private final class SourcesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: [MediaSourceRef]] = [:]
        private var nextLookupGate: LookupGate?
        func set(_ newMap: [String: [MediaSourceRef]]) {
            lock.lock(); defer { lock.unlock() }
            map = newMap
        }
        func sources(for item: MediaItem) -> [MediaSourceRef] {
            lock.lock()
            let result = map[item.id] ?? []
            let gate = nextLookupGate
            nextLookupGate = nil
            lock.unlock()
            gate?.wait()
            return result
        }
        func blockNextLookup(_ gate: LookupGate) {
            lock.lock(); defer { lock.unlock() }
            nextLookupGate = gate
        }
    }

    private final class LookupGate: @unchecked Sendable {
        let started: XCTestExpectation
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var mainThread = false
        private var timedOut = false

        init(started: XCTestExpectation) {
            self.started = started
        }

        func wait() {
            lock.lock()
            mainThread = Thread.isMainThread
            lock.unlock()
            started.fulfill()
            let result = release.wait(timeout: .now() + 5)
            lock.lock()
            timedOut = result == .timedOut
            lock.unlock()
        }

        func open() { release.signal() }

        var result: (ranOnMainThread: Bool, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (mainThread, timedOut)
        }
    }

    private func makeViewModel(
        provider: FakeMediaProvider,
        box: SourcesBox
    ) -> HomeViewModel {
        let server = MediaServer(id: "srv-a", name: "Local", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            identitySources: { box.sources(for: $0) },
            currentVisibility: { .default }
        )
    }

    func testReenrichFoldsNewlyDiscoveredSourceIntoLoadedCard() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)

        // Cold load: the index knows nothing yet, so the card has no cross-server twin.
        await vm.load()
        let cwBefore = vm.state.value?.continueWatching ?? []
        XCTAssertEqual(cwBefore.count, 1)
        XCTAssertFalse(cwBefore[0].sources.contains { $0.accountID == "b" })

        // The index warms: account "b" (a second server) turns out to host the same title.
        box.set([
            "m1": [
                MediaSourceRef(accountID: "a", itemID: "m1", providerKind: .jellyfin),
                MediaSourceRef(accountID: "b", itemID: "m1-on-b", providerKind: .plex)
            ]
        ])
        await vm.reenrich()

        let cwAfter = vm.state.value?.continueWatching ?? []
        XCTAssertEqual(cwAfter.count, 1, "Re-enrich must not add or drop cards, only fold sources")
        XCTAssertTrue(
            cwAfter[0].sources.contains { $0.accountID == "b" },
            "The newly-discovered local twin must be folded into the loaded card so play can route to it"
        )
    }

    func testReenrichIsNoOpWhenNothingNewDiscovered() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)

        await vm.load()
        let before = vm.state.value

        // Index hasn't grown (box still empty): re-enrich must leave content identical.
        await vm.reenrich()
        XCTAssertEqual(before, vm.state.value)
    }

    func testSlowIdentityLookupDoesNotBlockTheMainActor() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)
        await vm.load()
        let gate = LookupGate(started: expectation(description: "Identity lookup started"))
        box.blockNextLookup(gate)
        defer { gate.open() }

        let pass = Task { await vm.reenrich() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertFalse(gate.result.ranOnMainThread)
        // Reaching here before releasing the worker proves MainActor remains usable.
        vm.noteHomeNavigationInteraction()
        gate.open()
        await pass.value
        XCTAssertFalse(gate.result.timedOut)
    }

    func testWatchMutationDuringMergeIsNotOverwritten() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)
        await vm.load()
        box.set(["m1": [MediaSourceRef(accountID: "b", itemID: "twin", providerKind: .plex)]])
        let gate = LookupGate(started: expectation(description: "Old snapshot merging"))
        box.blockNextLookup(gate)
        defer { gate.open() }

        let pass = Task { await vm.reenrich() }
        await fulfillment(of: [gate.started], timeout: 2)
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["m1"], scopedItemIDs: ["a:m1"],
            resumePosition: 120, playedPercentage: 0.1
        ))
        XCTAssertEqual(vm.state.value?.continueWatching.first?.resumePosition, 120)
        gate.open()
        await pass.value

        XCTAssertEqual(vm.state.value?.continueWatching.first?.resumePosition, 120)
        XCTAssertTrue(vm.state.value?.continueWatching.first?.sources.contains {
            $0.accountID == "b"
        } == true, "The retry must enrich the newer state, not simply drop the index update")
    }

    func testReloadDuringMergeCannotRestoreOldCards() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Old", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)
        await vm.load()
        box.set(["m1": [MediaSourceRef(accountID: "b", itemID: "old-twin", providerKind: .plex)]])
        let gate = LookupGate(started: expectation(description: "Old content merging"))
        box.blockNextLookup(gate)
        defer { gate.open() }

        let pass = Task { await vm.reenrich() }
        await fulfillment(of: [gate.started], timeout: 2)
        provider.continueWatchingItems = [MediaItem(id: "m2", title: "New", kind: .movie)]
        await vm.load(showLoadingState: false)
        let reloaded = vm.state.value
        gate.open()
        await pass.value

        XCTAssertEqual(vm.state.value, reloaded)
        XCTAssertEqual(vm.state.value?.continueWatching.map(\.id), ["m2"])
    }

    func testCancelledMergeDoesNotPublish() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)
        await vm.load()
        let before = vm.state.value
        box.set(["m1": [MediaSourceRef(accountID: "b", itemID: "twin", providerKind: .plex)]])
        let gate = LookupGate(started: expectation(description: "Cancellable lookup started"))
        box.blockNextLookup(gate)
        defer { gate.open() }

        let pass = Task { await vm.reenrich() }
        await fulfillment(of: [gate.started], timeout: 2)
        pass.cancel()
        gate.open()
        await pass.value

        XCTAssertEqual(vm.state.value, before)
    }

    func testNewScheduledPassSupersedesRunningPassAndItsCallback() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let box = SourcesBox()
        let vm = makeViewModel(provider: provider, box: box)
        await vm.load()
        let gate = LookupGate(started: expectation(description: "Superseded lookup started"))
        box.blockNextLookup(gate)
        defer { gate.open() }
        let obsoleteCallback = expectation(description: "Cancelled pass must not settle")
        obsoleteCallback.isInverted = true
        vm.scheduleReenrich { obsoleteCallback.fulfill() }
        await fulfillment(of: [gate.started], timeout: 2)

        box.set(["m1": [MediaSourceRef(accountID: "b", itemID: "twin", providerKind: .plex)]])
        let latestCallback = expectation(description: "Latest pass settled")
        vm.scheduleReenrich { latestCallback.fulfill() }
        await fulfillment(of: [latestCallback], timeout: 2)
        let newest = vm.state.value
        gate.open()
        await fulfillment(of: [obsoleteCallback], timeout: 0.1)

        XCTAssertEqual(vm.state.value, newest)
        XCTAssertTrue(vm.state.value?.continueWatching.first?.sources.contains {
            $0.accountID == "b"
        } == true)
    }
}
