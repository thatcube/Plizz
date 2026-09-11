#if DEBUG && canImport(AVFoundation)
import CoreModels
import TraktService
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import FeaturePlayback

@MainActor
final class LibraryChannelPlaybackSessionTests: XCTestCase {
    private func fixture(
        offset: Double = 0, history: Bool = false, externalHistory: Bool = false
    ) throws -> LibraryPlaybackFixture {
        try LibraryPlaybackFixture(offset: offset, history: history, externalHistory: externalHistory)
    }

    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Playback did not reach its expected state", file: file, line: line)
    }

    func testJoinIgnoresOrdinaryResumeAndRecomputesOffsetAfterResolutionAndBuffering() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.state.resolveHook = { [weak fixture] _ in fixture?.state.advance(5) }
        fixture.engine.loadHook = { [weak fixture] in fixture?.state.advance(7) }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        XCTAssertEqual(fixture.engine.loads.first?.startPosition, 25)
        XCTAssertEqual(fixture.engine.currentTime, 32)
        XCTAssertEqual(fixture.engine.seeks, [32])
        XCTAssertTrue(fixture.engine.loads.first?.suppressOrdinaryWatchReporting == true)
    }

    func testResolutionCrossingBoundaryResolvesTheActualCurrentProgramme() async throws {
        let fixture = try fixture(offset: 98)
        defer { fixture.player.stop() }
        fixture.state.resolveHook = { [weak fixture] _ in
            if fixture?.state.resolved.count == 1 { fixture?.state.advance(5) }
        }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        XCTAssertEqual(fixture.state.resolved, ["first", "second"])
        XCTAssertEqual(fixture.engine.loads.count, 1)
        XCTAssertEqual(fixture.engine.loads.first?.item.id, "second")
        XCTAssertEqual(fixture.engine.currentTime, 3)
    }

    func testOffHasNoOrdinaryOrDedicatedHistoryWritesThroughTeardown() async throws {
        let fixture = try fixture()
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<95 { fixture.advancePlayback() }
        fixture.player.pause()
        fixture.player.resume()
        fixture.player.stop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.state.ordinaryReports, 0)
        XCTAssertTrue(fixture.state.completed.isEmpty)
        XCTAssertTrue(fixture.state.tracked.isEmpty)
        XCTAssertEqual(fixture.state.checkpoints, 0)
        XCTAssertEqual(fixture.player.secondsWatched, 0)
    }

    func testLateJoinDoesNotCompleteProgrammeFromItsPosition() async throws {
        let fixture = try fixture(offset: 92, history: true)
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<7 { fixture.advancePlayback() }
        fixture.player.stop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.state.completed.isEmpty)
        XCTAssertTrue(fixture.state.tracked.isEmpty)
        XCTAssertEqual(fixture.player.secondsWatched, 7, accuracy: 0.001)
    }

    func testOptInRequiresActualCoverageAndNeverCreditsOffIntervals() async throws {
        let fixture = try fixture()
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        for _ in 0..<80 { fixture.advancePlayback() }
        fixture.state.historyToken = UUID()
        fixture.player.tick()
        for _ in 0..<15 { fixture.advancePlayback() }
        XCTAssertEqual(fixture.player.secondsWatched, 15, accuracy: 0.001)
        XCTAssertTrue(fixture.state.completed.isEmpty)
        fixture.state.historyToken = nil
        fixture.player.tick()
        fixture.state.historyToken = UUID()
        fixture.player.tick()
        fixture.advancePlayback()
        XCTAssertEqual(fixture.player.secondsWatched, 1, accuracy: 0.001)
    }

    func testNinetyPercentCoverageCompletesOnlyOnceAndNotOnOrdinaryReporter() async throws {
        let fixture = try fixture(history: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<91 { fixture.advancePlayback() }
        await settle { fixture.state.checkpoints == 1 }
        for _ in 0..<3 { fixture.advancePlayback() }
        XCTAssertEqual(fixture.state.completed, ["first"])
        XCTAssertEqual(fixture.state.tracked.count, 1)
        XCTAssertGreaterThanOrEqual(fixture.state.tracked.first ?? 0, 90)
        XCTAssertEqual(fixture.state.ordinaryReports, 0)
    }

    func testExternalCompletionSinkExclusivelyOwnsEveryHistorySideEffect() async throws {
        let fixture = try fixture(history: true, externalHistory: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.tick()
        for _ in 0..<94 { fixture.advancePlayback() }
        await settle { fixture.state.externalCompletions.count == 1 }
        for _ in 0..<3 { fixture.advancePlayback() }
        XCTAssertEqual(fixture.state.externalCompletions, ["first"])
        XCTAssertEqual(fixture.state.externalTokens, [fixture.state.historyToken!])
        XCTAssertEqual(fixture.state.externalAccounts, ["account"])
        XCTAssertEqual(fixture.state.externalAttempts, 1)
        XCTAssertTrue(fixture.state.completed.isEmpty)
        XCTAssertTrue(fixture.state.tracked.isEmpty)
        XCTAssertEqual(fixture.state.checkpoints, 0)
        XCTAssertEqual(fixture.state.ordinaryReports, 0)
    }

    func testExternalCompletionStillRequiresBothWatchingAndProfileOptIn() async throws {
        for history in [false, true] {
            let fixture = try fixture(history: history, externalHistory: true)
            defer { fixture.player.stop() }
            if history { fixture.player.setWatching(false) }
            fixture.player.tune()
            try await fixture.player.waitUntilSettled()
            fixture.player.tick()
            for _ in 0..<95 { fixture.advancePlayback() }
            await fixture.player.stopAndDrain()
            XCTAssertEqual(fixture.state.externalAttempts, 0)
            XCTAssertTrue(fixture.state.completed.isEmpty)
            XCTAssertTrue(fixture.state.tracked.isEmpty)
        }
    }

    func testExternalCompletionFailureCannotFallBackToProviderOrTrackerWrites() async throws {
        let fixture = try fixture(history: true, externalHistory: true)
        defer { fixture.player.stop() }
        fixture.state.externalError = .storageFailed
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.tick()
        for _ in 0..<91 { fixture.advancePlayback() }
        await settle { fixture.player.historyIssue }
        for _ in 0..<3 { fixture.advancePlayback() }
        XCTAssertEqual(fixture.state.externalAttempts, 1)
        XCTAssertTrue(fixture.state.externalCompletions.isEmpty)
        XCTAssertTrue(fixture.state.completed.isEmpty)
        XCTAssertTrue(fixture.state.tracked.isEmpty)
        XCTAssertEqual(fixture.state.checkpoints, 0)
        XCTAssertEqual(fixture.player.state, .playing)
    }

    func testQueuedExternalCompletionRevalidatesOptInAndProfileBeforeCallingSink() async throws {
        for revokeProfile in [false, true] {
            let fixture = try fixture(history: true, externalHistory: true)
            defer { fixture.player.stop() }
            fixture.player.tune()
            try await fixture.player.waitUntilSettled()
            fixture.player.tick()
            for _ in 0..<90 { fixture.advancePlayback() }
            if revokeProfile { fixture.state.authorization = nil }
            else { fixture.state.historyToken = nil }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(fixture.state.externalAttempts, 0)
            XCTAssertTrue(fixture.state.completed.isEmpty)
            XCTAssertTrue(fixture.state.tracked.isEmpty)
        }
    }

    func testExternalCompletionDoesNotUseALateJoinPositionAsWatchedCoverage() async throws {
        let fixture = try fixture(offset: 94, history: true, externalHistory: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.tick()
        for _ in 0..<5 { fixture.advancePlayback() }
        await fixture.player.stopAndDrain()
        XCTAssertEqual(fixture.state.externalAttempts, 0)
        XCTAssertEqual(fixture.player.secondsWatched, 5)
    }

    func testCompletionCanFinishAcrossProgrammeBoundary() async throws {
        let fixture = try fixture(history: true)
        defer { fixture.player.stop() }
        let gate = LibraryPlaybackGate()
        fixture.state.completionHook = { await gate.wait() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<91 { fixture.advancePlayback() }
        await settle { gate.isWaiting }
        fixture.state.advance(12)
        fixture.player.tick()
        await settle { fixture.player.currentSlot?.item.itemID == "second" && fixture.player.state == .playing }
        gate.open()
        await settle { fixture.state.checkpoints == 1 }
        XCTAssertEqual(fixture.state.completed, ["first"])
    }

    func testStallsAndSeekJumpsCannotEarnCoverage() async throws {
        let fixture = try fixture(history: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        fixture.engine.preventsDisplaySleep = false
        for _ in 0..<10 { fixture.advancePlayback() }
        fixture.engine.preventsDisplaySleep = true
        fixture.player.tick()
        fixture.engine.currentTime = 90
        fixture.state.advance(1)
        fixture.player.tick()
        XCTAssertEqual(fixture.player.secondsWatched, 0)
        XCTAssertTrue(fixture.state.completed.isEmpty)
    }

    func testPauseKeepsDelayedCursorAndGoLiveRejoinsWallClock() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.pause()
        fixture.state.advance(10)
        fixture.player.tick()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertEqual(fixture.engine.currentTime, 20)
        fixture.player.resume()
        XCTAssertTrue(fixture.player.isDelayed)
        XCTAssertEqual(fixture.engine.currentTime, 20)
        fixture.player.goLive()
        await settle { fixture.player.state == .playing }
        XCTAssertFalse(fixture.player.isDelayed)
        XCTAssertEqual(fixture.engine.currentTime, 30)
    }

    func testExpiredDelayedCursorRequiresGoLive() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.pause()
        fixture.state.advance(86_401)
        fixture.player.resume()
        XCTAssertEqual(fixture.player.state, .unavailable(.historyExpired))
        fixture.player.goLive()
        await settle { fixture.player.state == .playing }
        XCTAssertFalse(fixture.player.isDelayed)
    }

    func testMissingFilePreservesUnavailableIntervalThenAdvancesAtScheduledBoundary() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.state.resolveHook = { item in
            if item.itemID == "first" { throw LibraryChannelError.mediaChanged }
        }
        fixture.player.tune()
        await settle { fixture.player.state == .unavailable(.mediaChanged) }
        XCTAssertEqual(fixture.player.recoverableProgrammeIssue, .mediaChanged)
        fixture.state.advance(10)
        fixture.player.tick()
        XCTAssertEqual(fixture.player.currentSlot?.item.itemID, "first")
        XCTAssertTrue(fixture.engine.loads.isEmpty)
        fixture.state.advance(70)
        fixture.player.tick()
        await settle { fixture.player.state == .playing }
        XCTAssertEqual(fixture.player.currentSlot?.item.itemID, "second")
        XCTAssertEqual(fixture.engine.currentTime, 0)
        XCTAssertNil(fixture.player.recoverableProgrammeIssue)
    }

    func testAuthorizationChangeDuringResolveNeverLoadsOldCredentials() async throws {
        let fixture = try fixture()
        defer { fixture.player.stop() }
        let gate = LibraryPlaybackGate()
        fixture.state.resolveHook = { _ in await gate.wait() }
        fixture.player.tune()
        await settle { gate.isWaiting }
        fixture.state.authorization = "replacement-profile"
        gate.open()
        await settle { fixture.player.state == .unavailable(.authorizationChanged) }
        XCTAssertTrue(fixture.engine.loads.isEmpty)
    }

    func testUnreadyEngineTimesOutInsteadOfShowingAFalseLiveState() async throws {
        let fixture = try fixture()
        defer { fixture.player.stop() }
        fixture.engine.readyOnLoad = false
        fixture.player.tune()
        await settle { !fixture.engine.loads.isEmpty }
        fixture.state.advance(46)
        fixture.player.tick()
        XCTAssertEqual(fixture.player.state, .unavailable(.unableToJoinLive))
    }

    func testProgrammeBoundaryAdvancesEvenWhenPreviousDecoderNeverBecameReady() async throws {
        let fixture = try fixture(offset: 98)
        defer { fixture.player.stop() }
        fixture.engine.readyOnLoad = false
        fixture.player.tune()
        await settle { fixture.engine.loads.count == 1 }
        fixture.engine.readyOnLoad = true
        fixture.state.advance(3)
        fixture.player.tick()
        await settle { fixture.player.state == .playing }
        XCTAssertEqual(fixture.player.currentSlot?.item.itemID, "second")
        XCTAssertEqual(fixture.engine.currentTime, 1)
    }

    func testRetryWithinProgrammeKeepsOnlyItsPreviouslyWatchedIntervals() async throws {
        let fixture = try fixture(history: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<50 { fixture.advancePlayback() }
        fixture.player.retry()
        await settle { fixture.player.state == .playing }
        fixture.player.tick()
        for _ in 0..<41 { fixture.advancePlayback() }
        await settle { fixture.state.checkpoints == 1 }
        XCTAssertEqual(fixture.state.completed, ["first"])
        XCTAssertGreaterThanOrEqual(fixture.player.secondsWatched, 90)
    }

    func testRetainedPaneWaitFollowsResolutionAcrossTheProgrammeBoundary() async throws {
        let fixture = try fixture(offset: 98)
        defer { fixture.player.stop() }
        fixture.state.resolveHook = { [weak fixture] _ in
            if fixture?.state.resolved.count == 1 { fixture?.state.advance(3) }
        }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.currentSlot?.item.itemID, "second")
        XCTAssertEqual(fixture.engine.currentTime, 1)
    }

    func testPreviewHasNoHistoryEvenWithExplicitProfileOptIn() async throws {
        let fixture = try fixture(history: true)
        fixture.player.setWatching(false)
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.tick()
        for _ in 0..<95 { fixture.advancePlayback() }
        await fixture.player.stopAndDrain()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.state.completed.isEmpty)
        XCTAssertTrue(fixture.state.tracked.isEmpty)
        XCTAssertEqual(fixture.state.checkpoints, 0)
        XCTAssertEqual(fixture.player.secondsWatched, 0)
        XCTAssertGreaterThanOrEqual(fixture.engine.drainCount, 2)
    }

    func testOwnedStopThenAwaitableDrainDoesNotStopTheDecoderAgain() async throws {
        let fixture = try fixture()
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.stop()
        await fixture.player.stopAndDrain()
        let drained = fixture.engine.drainCount
        await fixture.player.stopAndDrain()
        XCTAssertEqual(fixture.engine.drainCount, drained)
        XCTAssertEqual(fixture.player.state, .idle)
    }

    func testDrainStopsACancellationIgnoringLoadBeforeReturning() async throws {
        let fixture = try fixture()
        let gate = LibraryPlaybackGate()
        fixture.engine.asyncLoadHook = { await gate.wait() }
        fixture.player.tune()
        await settle { gate.isWaiting }
        fixture.player.stop()
        let cleanup = Task { await fixture.player.stopAndDrain() }
        gate.open()
        await cleanup.value
        XCTAssertEqual(fixture.engine.status, .idle)
        XCTAssertTrue(fixture.engine.isPaused)
        let stopCount = fixture.engine.stopCount
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.engine.stopCount, stopCount, "No delayed stop after the owner may reuse its decoder")
    }

    func testOldCapturedEngineCallbacksCannotFailOrAdvanceAReplacementProgramme() async throws {
        let fixture = try fixture()
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        let oldFailure = fixture.engine.onFailure
        let oldEnded = fixture.engine.onEnded
        fixture.state.advance(100)
        fixture.player.tick()
        try await fixture.player.waitUntilSettled()
        oldFailure?(.invalidResponse)
        oldEnded?()
        XCTAssertEqual(fixture.player.state, .playing)
        XCTAssertEqual(fixture.player.currentSlot?.item.itemID, "second")
        XCTAssertEqual(fixture.engine.loads.count, 2)
        await fixture.player.stopAndDrain()
        oldFailure?(.invalidResponse)
        oldEnded?()
        XCTAssertEqual(fixture.player.state, .idle)
    }

    func testSourceResetCallbackMaySynchronouslyRetireTheOwnerBeforeLoad() async throws {
        let fixture = try fixture()
        fixture.player.onSourceReset = { [weak player = fixture.player] in player?.stop() }
        fixture.player.tune()
        await fixture.player.stopAndDrain()
        XCTAssertTrue(fixture.engine.loads.isEmpty)
        XCTAssertEqual(fixture.player.state, .idle)
    }

    func testPauseAppliedBeforeTuneRemainsTheOwnerIntent() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.player.pause()
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertEqual(fixture.engine.currentTime, 20)
        XCTAssertTrue(fixture.engine.isPaused)
    }

    func testBehindLiveUsesThePausedBroadcastCursor() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.pause()
        fixture.state.advance(12)
        XCTAssertEqual(fixture.player.behindLiveSeconds, 12)
        fixture.player.resume()
        XCTAssertEqual(fixture.player.behindLiveSeconds, 12)
        fixture.player.goLive()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.behindLiveSeconds, 0)
    }

    func testForegroundOwnerReapplyingPauseDoesNotReplaceTheDelayedCursor() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.pause()
        fixture.state.advance(12)
        fixture.player.foreground()
        fixture.player.pause()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertEqual(fixture.engine.currentTime, 20)
        XCTAssertEqual(fixture.player.behindLiveSeconds, 12)
    }

    func testPausedBufferingCanSettleAfterTheDecoderBecomesReady() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.engine.readyOnLoad = false
        fixture.player.tune()
        await settle { fixture.engine.loads.count == 1 }
        fixture.player.pause()
        fixture.engine.status = .ready
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertEqual(fixture.engine.currentTime, 20)
    }

    func testPausedInitialLoadReconcilesAnyFramesAdvancedWhileBuffering() async throws {
        let fixture = try fixture(offset: 20)
        defer { fixture.player.stop() }
        fixture.engine.loadHook = { [weak fixture] in fixture?.engine.currentTime += 5 }
        fixture.player.tune()
        fixture.player.pause()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.player.state, .paused)
        XCTAssertEqual(fixture.engine.currentTime, 20)
    }

    func testRebufferRecoveryRejoinsWithoutCreditingTheMissedInterval() async throws {
        let fixture = try fixture(history: true)
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.player.tick()
        for _ in 0..<5 { fixture.advancePlayback() }
        fixture.engine.preventsDisplaySleep = false
        fixture.state.advance(10)
        fixture.player.tick()
        fixture.engine.preventsDisplaySleep = true
        fixture.player.tick()
        try await fixture.player.waitUntilSettled()
        XCTAssertEqual(fixture.engine.currentTime, 15)
        XCTAssertEqual(fixture.player.secondsWatched, 5)
        fixture.player.tick()
        fixture.advancePlayback()
        XCTAssertEqual(fixture.player.secondsWatched, 6)
    }

    func testRetainedPaneWaitRejectsAuthorizationRevokedAfterPlaybackSettled() async throws {
        let fixture = try fixture()
        defer { fixture.player.stop() }
        fixture.player.tune()
        try await fixture.player.waitUntilSettled()
        fixture.state.authorization = nil
        XCTAssertNil(fixture.player.recoverableProgrammeIssue)
        do {
            try await fixture.player.waitUntilSettled()
            XCTFail("A settled decoder is not an authorization grant")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
        XCTAssertTrue(fixture.engine.isPaused)
    }
}

@MainActor
private final class LibraryPlaybackFixture {
    let state = LibraryPlaybackStateFixture()
    let engine = LibraryPlaybackEngineFixture()
    let schedule: LibraryChannelSchedule
    let player: LibraryChannelPlaybackSession

    init(offset: Double, history: Bool, externalHistory: Bool) throws {
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let items = try ["first", "second"].enumerated().map { index, id in
            var item = MediaItem(id: id, title: id, kind: .episode, runtime: 100)
            item.seriesID = "show"
            item.seasonNumber = 1
            item.episodeNumber = index + 1
            return try LibraryChannelItem(item: item, library: library, serverID: "server", userID: "user")
        }
        let snapshot = try LibraryChannelSnapshot(items: items, createdAt: state.now)
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            LibraryChannelRevision(
                snapshotID: snapshot.id, recipe: LibraryChannelRecipe(name: "TV", libraries: [library]),
                epochSeconds: Int64(state.now.timeIntervalSince1970)
            )
        ])
        schedule = try LibraryChannelSchedule(definition: definition, snapshots: [snapshot.id: snapshot])
        state.advance(offset)
        state.historyToken = history ? UUID() : nil
        let fixtureState = self.state
        let channelSchedule = self.schedule
        let provider = LibraryPlaybackProviderFixture(state: fixtureState)
        let reporting: LibraryChannelHistoryReporting
        if externalHistory {
            reporting = .externalCompletion { scheduled, item, token in
                try await fixtureState.completeExternally(scheduled: scheduled, item: item, token: token)
            }
        } else {
            reporting = .sourceAndTrakt(
                scrobbler: LibraryPlaybackScrobblerFixture(state: fixtureState),
                onCompleted: { _, _, _ in fixtureState.checkpoints += 1 }
            )
        }
        player = LibraryChannelPlaybackSession(
            channelID: definition.id, engine: engine, schedule: { channelSchedule }, provider: { _ in provider },
            authorization: { fixtureState.authorization }, historyAuthorization: { fixtureState.historyToken },
            historyReporting: reporting,
            clock: { fixtureState.now }, uptime: { fixtureState.uptime }
        )
        player.setWatching(true)
    }

    func advancePlayback() {
        state.advance(1)
        engine.currentTime += 1
        player.tick()
    }
}

@MainActor
private final class LibraryPlaybackStateFixture {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var uptime: Double = 0
    var authorization: String? = "authorized"
    var historyToken: UUID?
    var resolved: [String] = []
    var completed: [String] = []
    var tracked: [Double] = []
    var checkpoints = 0
    var ordinaryReports = 0
    var externalAttempts = 0
    var externalCompletions: [String] = []
    var externalAccounts: [String] = []
    var externalTokens: [UUID] = []
    var externalError: LibraryChannelError?
    var resolveHook: (@MainActor (LibraryChannelItem) async throws -> Void)?
    var completionHook: (@MainActor () async -> Void)?

    func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds); uptime += seconds }

    func resolve(_ item: LibraryChannelItem) async throws -> PlaybackRequest {
        resolved.append(item.itemID)
        try await resolveHook?(item)
        var media = MediaItem(id: item.itemID, title: item.title, kind: item.kind, runtime: Double(item.durationSeconds))
        media.resumePosition = 97
        return PlaybackRequest(item: media, streamURL: URL(string: "https://server.invalid/file.mp4")!, startPosition: 97)
    }

    func complete(_ id: String) async {
        await completionHook?()
        completed.append(id)
    }

    func completeExternally(scheduled: LibraryChannelItem, item: MediaItem, token: UUID) async throws {
        externalAttempts += 1
        if let externalError { throw externalError }
        externalCompletions.append(item.id)
        externalAccounts.append(scheduled.library.accountID)
        externalTokens.append(token)
    }

    func track(_ progress: Double) { tracked.append(progress) }
    func reportOrdinary() { ordinaryReports += 1 }
}

private actor LibraryPlaybackProviderFixture: LibraryChannelPlaybackProviding {
    let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    let state: LibraryPlaybackStateFixture
    init(state: LibraryPlaybackStateFixture) { self.state = state }
    func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest { try await state.resolve(item) }
    func recordLibraryChannelCompletion(itemID: String) async throws { await state.complete(itemID) }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { await state.reportOrdinary() }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct LibraryPlaybackScrobblerFixture: TraktScrobbling {
    let state: LibraryPlaybackStateFixture
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async { await state.track(progress) }
}

@MainActor
private final class LibraryPlaybackGate {
    var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class LibraryPlaybackEngineFixture: VideoEngine {
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 100
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var loads: [PlaybackRequest] = []
    var seeks: [Double] = []
    var readyOnLoad = true
    var drainCount = 0
    var stopCount = 0
    var loadHook: (@MainActor () -> Void)?
    var asyncLoadHook: (@MainActor () async -> Void)?
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loads.append(request)
        await asyncLoadHook?()
        currentTime = startPosition
        status = readyOnLoad ? .ready : .loading
        isPaused = false
        loadHook?()
    }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func reloadAfterForeground() async throws {}
    func seek(to seconds: TimeInterval) async { seeks.append(seconds); currentTime = seconds }
    func stop() { stopCount += 1; status = .idle; isPaused = true }
    func drainTransport() async { drainCount += 1 }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
