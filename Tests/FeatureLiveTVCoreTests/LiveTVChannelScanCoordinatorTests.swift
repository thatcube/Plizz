import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVChannelScanCoordinatorTests: XCTestCase {
    func testImportedCatalogGenerationSurvivesRenameReorderAndChangesWithCredentials() throws {
        var playlist = LiveTVPlaylistSource(
            id: "source", name: "Channels", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
        )
        let first = scanChannel(id: "first")
        let second = scanChannel(id: "second", url: "https://fixture.test/second.m3u8")
        let original = try LiveTVChannelScanSource(source: playlist, channels: [first, second])
        playlist.name = "Renamed"
        let reordered = try LiveTVChannelScanSource(source: playlist, channels: [second, first])
        XCTAssertEqual(original.generation, reordered.generation)
        let tokenChanged = try LiveTVChannelScanSource(source: playlist, channels: [
            scanChannel(id: "first", headers: ["Authorization": "Bearer changed-fixture"]), second
        ])
        XCTAssertNotEqual(original.generation, tokenChanged.generation)
        playlist.playlistURL = URL(string: "https://fixture.test/channels.m3u?token=new-fixture")!
        let sourceChanged = try LiveTVChannelScanSource(source: playlist, channels: [first, second])
        XCTAssertNotEqual(original.generation, sourceChanged.generation)
    }

    func testImportedCatalogFactoryExcludesOtherSourcesAndServerChannels() throws {
        var playlist = LiveTVPlaylistSource(
            id: "source", name: "Channels", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
        )
        let catalog = try LiveTVChannelScanSource(source: playlist, channels: [
            scanChannel(id: "imported"),
            scanChannel(id: "other", sourceID: "other-source"),
            scanChannel(id: "server", source: .plex),
            scanChannel(id: "library", source: .plozz)
        ])
        XCTAssertEqual(catalog.targets.map(\.id), ["imported"])
        playlist.isEnabled = false
        XCTAssertThrowsError(try LiveTVChannelScanSource(source: playlist, channels: [scanChannel()]))
    }

    func testMixedTransportPoliciesKeepWholeLineupAndNeverRequestBlockedEntries() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "source", name: "Mixed", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
        )
        let missingURL = LiveTVPrototypeChannel(
            id: "no-url", number: 7, name: "No URL", category: "Test", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", playlistSourceID: "source"
        )
        let channels = [
            scanChannel(id: "good"),
            scanChannel(id: "missing", url: "https://fixture.test/missing.m3u8"),
            scanChannel(id: "http", url: "http://fixture.test/insecure.m3u8"),
            scanChannel(id: "local", url: "https://127.0.0.1/local.m3u8"),
            scanChannel(id: "unsupported", url: "ftp://fixture.test/live.ts"),
            scanChannel(id: "unsafe-headers", headers: ["Host": "different.test"]),
            missingURL,
            scanChannel(id: "auth", url: "https://fixture.test/auth.m3u8")
        ]
        let catalog = try LiveTVChannelScanSource(source: playlist, channels: channels)
        XCTAssertEqual(catalog.channelCount, 8)
        XCTAssertEqual(catalog.targets.count, 3)
        XCTAssertEqual(catalog.unprobeableChannels.count, 5)
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 200, data: scanTransportStream)],
            "/missing.m3u8": [.init(statusCode: 404)],
            "/auth.m3u8": [.init(statusCode: 401)]
        ])
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(),
            probe: LiveTVChannelProbe(transport: transport, limits: .init(retryDelay: .zero))
        )
        try coordinator.bind(profileID: "profile", sources: [catalog])
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.progress?.total, 8)
        XCTAssertEqual(coordinator.progress?.completed, 8)
        XCTAssertEqual(coordinator.progress?.reachable, 1)
        XCTAssertEqual(coordinator.progress?.unavailable, 1)
        XCTAssertEqual(coordinator.progress?.uncertain, 6)
        XCTAssertEqual(coordinator.scanHiddenChannelIDs, ["missing"])
        XCTAssertEqual(coordinator.results(sourceID: "source").count, 8)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "fixture.test" })
        XCTAssertFalse(requests.contains { $0.url?.path == "/insecure.m3u8" || $0.url?.path == "/local.m3u8" })
    }

    func testEntirelyUnprobeableSourceProducesPersistentUncertainResultsWithoutNetwork() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "source", name: "Blocked", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
        )
        let catalog = try LiveTVChannelScanSource(source: playlist, channels: [
            scanChannel(id: "http", url: "http://fixture.test/live.m3u8?token=private-fixture"),
            scanChannel(id: "local", url: "https://192.168.1.8/live.m3u8"),
            scanChannel(id: "unsupported", url: "rtsp://fixture.test/live")
        ])
        let store = ScanMemoryHealthStore()
        let transport = ScanFixtureTransport(responses: [:])
        let probe = LiveTVChannelProbe(transport: transport)
        let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        try coordinator.bind(profileID: "profile", sources: [catalog])
        XCTAssertTrue(coordinator.canScan(sourceID: "source"))
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await coordinator.waitUntilFinished()
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(coordinator.progress?.completed, 3)
        XCTAssertEqual(coordinator.progress?.uncertain, 3)
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
        let reloaded = LiveTVChannelScanCoordinator(store: store, probe: probe)
        try reloaded.bind(profileID: "profile", sources: [catalog])
        XCTAssertEqual(reloaded.results(sourceID: "source").count, 3)
        XCTAssertTrue(reloaded.results(sourceID: "source").allSatisfy { $0.status == .uncertain && !$0.isScanHidden })
        let stored = String(decoding: try JSONEncoder().encode(store.load()), as: UTF8.self)
        XCTAssertFalse(stored.contains("private-fixture"))
        XCTAssertFalse(stored.contains("192.168.1.8"))
    }

    func testExplicitHTTPAndLocalApprovalPermitsOnlyEachStreamsOwnOrigin() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "source", name: "Approved", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
        )
        let channels = [
            scanChannel(id: "http", url: "http://fixture.test/insecure.m3u8"),
            scanChannel(id: "local", url: "https://192.168.1.8/local.m3u8", headers: ["Authorization": "Bearer local-fixture"])
        ]
        let denied = try LiveTVChannelScanSource(source: playlist, channels: channels)
        let allowed = try LiveTVChannelScanSource(
            source: playlist, channels: channels, allowsHTTP: true, allowsLocalNetwork: true
        )
        XCTAssertNotEqual(denied.generation, allowed.generation)
        XCTAssertEqual(allowed.targets.count, 2)
        XCTAssertTrue(allowed.unprobeableChannels.isEmpty)
        for target in allowed.targets {
            XCTAssertTrue(target.policy.permits(target.streamURL))
            XCTAssertFalse(target.policy.permits(URL(string: "http://different.test/stream")!))
            XCTAssertFalse(target.policy.permits(URL(string: "https://192.168.1.9/stream")!))
            XCTAssertTrue(target.policy.requestHeaders(for: URL(string: "https://different.test/stream")!).isEmpty)
        }
        let transport = ScanFixtureTransport(responses: [
            "/insecure.m3u8": [.init(statusCode: 200, data: scanTransportStream)],
            "/local.m3u8": [.init(statusCode: 200, data: scanTransportStream)]
        ])
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(), probe: LiveTVChannelProbe(transport: transport)
        )
        try coordinator.bind(profileID: "profile", sources: [allowed])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.progress?.reachable, 2)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.first { $0.url?.host == "192.168.1.8" }?.value(forHTTPHeaderField: "Authorization"),
            "Bearer local-fixture"
        )
    }

    func testCredentialedSourceContextPreventsMasked404HidesWithoutForwardingCredentials() async throws {
        let contexts = [
            ("https://provider.test/get.php?username=user-fixture&password=password-fixture", false),
            ("https://provider.test/live/user-fixture/password-fixture/list.m3u", false),
            ("https://provider.test/channels.m3u", true)
        ]
        for (address, explicitContext) in contexts {
            let playlist = LiveTVPlaylistSource(id: "source", name: "Channels", playlistURL: URL(string: address)!)
            let catalog = try LiveTVChannelScanSource(
                source: playlist,
                channels: [scanChannel(url: "https://fixture.test/missing.m3u8")],
                hasCredentialedSourceContext: explicitContext
            )
            XCTAssertTrue(try XCTUnwrap(catalog.targets.first).hasCredentialedSourceContext)
            let transport = ScanFixtureTransport(responses: ["/missing.m3u8": [.init(statusCode: 404)]])
            let store = ScanMemoryHealthStore()
            let coordinator = LiveTVChannelScanCoordinator(
                store: store, probe: LiveTVChannelProbe(transport: transport, limits: .init(retryDelay: .zero))
            )
            try coordinator.bind(profileID: "profile", sources: [catalog])
            coordinator.start(sourceID: "source")
            await coordinator.waitUntilFinished()
            XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
            XCTAssertEqual(coordinator.progress?.uncertain, 1)
            XCTAssertEqual(coordinator.results(sourceID: "source").first?.reason, .authorizationRequired)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(requests.first?.url?.query)
            let stored = String(decoding: try JSONEncoder().encode(store.load()), as: UTF8.self)
            XCTAssertFalse(stored.contains("password-fixture"))
            XCTAssertFalse(stored.contains("provider.test"))
        }
    }

    func testChannelRenameUpdatesResultsWithoutDiscardingHealth() async throws {
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(), probe: ScanResultProbe(outcomes: ["channel": .unavailable])
        )
        let original = try scanTarget()
        try coordinator.bind(profileID: "profile", sources: [source([original])])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        let renamed = LiveTVPrototypeChannel(
            id: "channel", number: 1, name: "Renamed channel", category: "Test",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            streamURL: original.streamURL, playlistSourceID: "source"
        )
        try coordinator.bind(profileID: "profile", sources: [source([
            LiveTVChannelScanTarget(channel: renamed, policy: original.policy)
        ])])
        XCTAssertEqual(coordinator.results(sourceID: "source").first?.name, "Renamed channel")
        XCTAssertEqual(coordinator.scanHiddenChannelIDs, ["channel"])
        XCTAssertFalse(coordinator.isScanning)
    }

    func testAllGoodAllBadAndMixedLineupsHaveAccurateSummaries() async throws {
        let lineups: [[LiveTVChannelHealthStatus]] = [
            [.reachable, .reachable, .reachable],
            [.unavailable, .unavailable, .unavailable],
            [.reachable, .unavailable, .uncertain]
        ]
        for outcomes in lineups {
            let targets = try outcomes.indices.map { try scanTarget(id: "channel-\($0)") }
            let probe = ScanResultProbe(outcomes: Dictionary(uniqueKeysWithValues: zip(targets.map(\.id), outcomes)))
            let store = ScanMemoryHealthStore()
            let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
            try coordinator.bind(profileID: "profile", sources: [try source(targets)])
            XCTAssertTrue(coordinator.start(sourceID: "source"))
            await coordinator.waitUntilFinished()
            XCTAssertEqual(coordinator.progress?.completed, 3)
            XCTAssertEqual(coordinator.progress?.reachable, outcomes.filter { $0 == .reachable }.count)
            XCTAssertEqual(coordinator.progress?.unavailable, outcomes.filter { $0 == .unavailable }.count)
            XCTAssertEqual(coordinator.progress?.uncertain, outcomes.filter { $0 == .uncertain }.count)
            XCTAssertEqual(coordinator.scanHiddenChannelIDs.count, outcomes.filter { $0 == .unavailable }.count)
            XCTAssertEqual(try store.load().count, 3)
            XCTAssertFalse(coordinator.isScanning)
            XCTAssertEqual(coordinator.progress?.isFinished, true)
        }
    }

    func testRestoreAndSuccessfulRescanNeverClearManualHideFavoritesOrPlayingChannel() async throws {
        let channels = [scanChannel(id: "playing"), scanChannel(id: "hidden")]
        let browser = LiveTVPrototypeModel(channels: channels)
        browser.toggleFavorite("playing")
        browser.toggleFavorite("hidden")
        _ = browser.hideChannel(channels[1])
        browser.tune("playing")
        let preferences = browser.favoriteIDs
        let probe = ScanResultProbe(outcomes: ["playing": .unavailable, "hidden": .unavailable])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore(), probe: probe)
        try coordinator.bind(profileID: "profile", sources: [try source([
            scanTarget(id: "playing"), scanTarget(id: "hidden")
        ])])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.scanHiddenChannelIDs, ["playing", "hidden"])
        XCTAssertEqual(browser.playingChannelID, "playing")
        XCTAssertEqual(browser.channels, channels)
        coordinator.restore(channelID: "hidden")
        XCTAssertFalse(coordinator.scanHiddenChannelIDs.contains("hidden"))
        XCTAssertTrue(browser.hiddenChannelIDs.contains("hidden"))
        await probe.replace(outcomes: ["playing": .reachable, "hidden": .reachable])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
        XCTAssertEqual(browser.favoriteIDs, preferences)
        XCTAssertEqual(browser.playingChannelID, "playing")
        XCTAssertTrue(browser.hiddenChannelIDs.contains("hidden"))
    }

    func testUncertainRescanCannotLeaveChannelAutoHidden() async throws {
        let probe = ScanResultProbe(outcomes: ["channel": .unavailable])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore(), probe: probe)
        try coordinator.bind(profileID: "profile", sources: [try source([scanTarget()])])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.scanHiddenChannelIDs, ["channel"])
        await probe.replace(outcomes: ["channel": .uncertain])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
    }

    func testStoredHealthRequiresSameProfileSourceAndStreamGeneration() async throws {
        let store = ScanMemoryHealthStore()
        let probe = ScanResultProbe(outcomes: ["channel": .unavailable])
        let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        let catalog = try source([scanTarget()])
        try coordinator.bind(profileID: "profile", sources: [catalog])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        let reloaded = LiveTVChannelScanCoordinator(store: store, probe: probe)
        try reloaded.bind(profileID: "profile", sources: [catalog])
        XCTAssertEqual(reloaded.scanHiddenChannelIDs, ["channel"])
        try reloaded.bind(profileID: "other-profile", sources: [catalog])
        XCTAssertTrue(reloaded.scanHiddenChannelIDs.isEmpty)
        try reloaded.bind(profileID: "profile", sources: [try source([scanTarget()], generation: "new")])
        XCTAssertTrue(reloaded.scanHiddenChannelIDs.isEmpty)
        try reloaded.bind(profileID: "profile", sources: [try source([
            scanTarget(url: "https://fixture.test/rotated.m3u8")
        ])])
        XCTAssertTrue(reloaded.scanHiddenChannelIDs.isEmpty)
    }

    func testCancelFencesNonCooperativeLateResults() async throws {
        let probe = ScanSuspendedProbe()
        let store = ScanMemoryHealthStore()
        let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        try coordinator.bind(profileID: "profile", sources: [try source([scanTarget()])])
        coordinator.start(sourceID: "source")
        await probe.waitForStart()
        coordinator.cancel()
        await probe.complete()
        await probe.waitForReturn()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
        XCTAssertEqual(coordinator.progress?.isCancelled, true)
    }

    func testRefreshEditProfileChangeAndRemovalFencePendingResults() async throws {
        for mutation in 0..<4 {
            let probe = ScanSuspendedProbe()
            let store = ScanMemoryHealthStore()
            let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
            let original = try source([scanTarget()])
            try coordinator.bind(profileID: "profile", sources: [original])
            coordinator.start(sourceID: "source")
            await probe.waitForStart()
            switch mutation {
            case 0: coordinator.invalidate(sourceID: "source")
            case 1:
                try coordinator.bind(profileID: "profile", sources: [source([scanTarget()], generation: "edited")])
            case 2: try coordinator.bind(profileID: "new-profile", sources: [original])
            default: coordinator.deactivate()
            }
            await probe.complete()
            await probe.waitForReturn()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(try store.load().isEmpty, "mutation \(mutation)")
            XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
        }
    }

    func testRestoreWhileRescanRunsWinsOverLateUnavailableResult() async throws {
        let store = ScanMemoryHealthStore()
        let seed = LiveTVChannelScanCoordinator(
            store: store, probe: ScanResultProbe(outcomes: ["channel": .unavailable])
        )
        let catalog = try source([scanTarget()])
        try seed.bind(profileID: "profile", sources: [catalog])
        seed.start(sourceID: "source")
        await seed.waitUntilFinished()
        let probe = ScanSuspendedProbe()
        let coordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        try coordinator.bind(profileID: "profile", sources: [catalog])
        coordinator.start(sourceID: "source")
        await probe.waitForStart()
        coordinator.restore(channelID: "channel")
        await probe.complete()
        await coordinator.waitUntilFinished()
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
    }

    func testLargeCatalogKeepsBoundedWorkersAndBatchedPersistence() async throws {
        let targets = try (0..<1_000).map { try scanTarget(id: "channel-\($0)") }
        let probe = ScanResultProbe(outcomes: [:], delay: .milliseconds(1))
        let store = ScanMemoryHealthStore()
        let coordinator = LiveTVChannelScanCoordinator(
            store: store, probe: probe, limits: .init(concurrentChannels: 3)
        )
        try coordinator.bind(profileID: "profile", sources: [try source(targets)])
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        let maximum = await probe.maximumActive
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertEqual(coordinator.progress?.completed, 1_000)
        XCTAssertLessThanOrEqual(store.saveCount, 9)
    }

    func testStoreFailuresAreVisibleAndNeverPublishUnsavedHides() async throws {
        let store = ScanMemoryHealthStore()
        let coordinator = LiveTVChannelScanCoordinator(
            store: store, probe: ScanResultProbe(outcomes: ["channel": .unavailable])
        )
        try coordinator.bind(profileID: "profile", sources: [try source([scanTarget()])])
        store.failSaving()
        coordinator.start(sourceID: "source")
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.issue, .healthSaveFailed)
        XCTAssertTrue(coordinator.scanHiddenChannelIDs.isEmpty)
        XCTAssertEqual(coordinator.progress?.isCancelled, true)
        let corrupt = LiveTVChannelScanCoordinator(store: ScanUnreadableHealthStore())
        XCTAssertThrowsError(try corrupt.bind(profileID: "profile", sources: [source([scanTarget()])]))
        XCTAssertEqual(corrupt.issue, .healthLoadFailed)
        XCTAssertFalse(corrupt.start(sourceID: "source"))
    }

    func testPerHostRequestPermitsBoundCDNLoadAndReleaseCancelledWaiters() async throws {
        let permits = LiveTVScanRequestPermits(maximum: 4, perHost: 1)
        let first = UUID()
        try await permits.acquire(id: first, host: "cdn.test")
        let secondID = UUID()
        let waiting = Task {
            try await withTaskCancellationHandler {
                try await permits.acquire(id: secondID, host: "cdn.test")
            } onCancel: {
                Task { await permits.cancel(id: secondID) }
            }
        }
        for _ in 0..<20 { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Queued request must cancel") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation error") }
        let other = UUID()
        try await permits.acquire(id: other, host: "different.test")
        await permits.release(id: first)
        await permits.release(id: other)
        let replacement = UUID()
        try await permits.acquire(id: replacement, host: "cdn.test")
        await permits.release(id: replacement)
    }

    private func source(
        _ targets: [LiveTVChannelScanTarget], generation: String = "revision"
    ) throws -> LiveTVChannelScanSource {
        try LiveTVChannelScanSource(id: "source", generation: generation, targets: targets)
    }
}

private actor ScanResultProbe: LiveTVChannelProbing {
    var outcomes: [String: LiveTVChannelHealthStatus]
    let delay: Duration
    var active = 0
    private(set) var maximumActive = 0

    init(outcomes: [String: LiveTVChannelHealthStatus], delay: Duration = .zero) {
        self.outcomes = outcomes
        self.delay = delay
    }

    func replace(outcomes: [String: LiveTVChannelHealthStatus]) { self.outcomes = outcomes }

    func probe(_ target: LiveTVChannelScanTarget) async throws -> LiveTVChannelProbeResult {
        active += 1
        maximumActive = max(active, maximumActive)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        let status = outcomes[target.id] ?? .reachable
        return LiveTVChannelProbeResult(
            status: status,
            reason: status == .reachable ? .mediaObserved : status == .unavailable ? .repeatedlyMissing : .timedOut
        )
    }
}

actor ScanSuspendedProbe: LiveTVChannelProbing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var returned = false

    func probe(_ target: LiveTVChannelScanTarget) async throws -> LiveTVChannelProbeResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
        returned = true
        return LiveTVChannelProbeResult(status: .unavailable, reason: .repeatedlyMissing)
    }

    func waitForStart() async { while !started { await Task.yield() } }
    func waitForReturn() async { while !returned { await Task.yield() } }
    func complete() { continuation?.resume(); continuation = nil }
}

final class ScanMemoryHealthStore: LiveTVChannelHealthStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LiveTVChannelHealthRecord] = []
    private var failure = false
    private var writes = 0

    var saveCount: Int { lock.withLock { writes } }
    func failSaving() { lock.withLock { failure = true } }
    func load() throws -> [LiveTVChannelHealthRecord] { lock.withLock { records } }
    func save(_ records: [LiveTVChannelHealthRecord]) throws {
        try lock.withLock {
            if failure { throw LiveTVChannelHealthStoreError.encodingFailed }
            self.records = records
            writes += 1
        }
    }
}

struct ScanUnreadableHealthStore: LiveTVChannelHealthStoring {
    func load() throws -> [LiveTVChannelHealthRecord] { throw LiveTVChannelHealthStoreError.invalidStoredValue }
    func save(_ records: [LiveTVChannelHealthRecord]) throws { throw LiveTVChannelHealthStoreError.invalidStoredValue }
}
