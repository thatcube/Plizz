#if DEBUG && canImport(UIKit)
import AVFoundation
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

private final class LiveChannelObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() { lock.withLock { recordedCount += 1 } }
}

@MainActor
final class LiveChannelPlayerModelTests: XCTestCase {
    func testLiveFailureCopyDoesNotAskPublicChannelViewersToSignInAgain() {
        let messages: [(AppError, String)] = [
            (.notFound, "playlist link may be outdated"),
            (.unauthorized, "provider refused access"),
            (.serverUnreachable, "streaming server"),
            (.invalidResponse, "playlist or video data"),
            (.decoding, "could not decode"),
            (.rateLimited(retryAfter: nil), "Wait before trying again"),
            (.unknown("https://example.invalid/?token=fixture-secret"), "could not start this live stream")
        ]
        for (error, expected) in messages {
            let message = String(localized: LiveChannelPlaybackFailure.engineMessage(error))
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertFalse(message.contains("fixture-secret"))
            XCTAssertFalse(message.contains("sign in again"))
            XCTAssertFalse(message.contains("Something went wrong"))
        }
    }

    private func makeModel(
        engine: LiveEngineSpy,
        clock: LiveTestClock = LiveTestClock()
    ) -> LiveChannelPlayerModel {
        LiveChannelPlayerModel(
            engine: engine,
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            uptime: { clock.now }
        )
    }

    func testLoadsLiveInsteadOfConstructingVODRequest() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.vodLoads, 0)
        XCTAssertNotNil(engine.onLiveSourceReset)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testPlaybackFacetInvalidatesPhaseWithoutInvalidatingTrackMenu() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let phaseChanges = LiveChannelObservationChanges()
        let trackChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.phase
        } onChange: {
            phaseChanges.record()
        }
        withObservationTracking {
            _ = model.audioTracks
        } onChange: {
            trackChanges.record()
        }

        model.togglePlayPause()

        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(phaseChanges.count, 1)
        XCTAssertEqual(trackChanges.count, 0)
    }

    func testTrackFacetInvalidatesListsSelectionsAndProgrammeResetWithoutUnrelatedPhaseChanges() async {
        let engine = LiveEngineSpy()
        engine.audioTracks = [.init(id: 1, kind: .audio, displayTitle: "English", language: "eng")]
        engine.currentAudioTrackID = 1
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "observation-fixture")
        )
        defer { model.stop() }
        await model.start()
        let originalSubtitles = model.subtitles
        let phaseChanges = LiveChannelObservationChanges()
        let trackChanges = LiveChannelObservationChanges()
        let selectionChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.phase
        } onChange: {
            phaseChanges.record()
        }
        withObservationTracking {
            _ = model.audioTracks
        } onChange: {
            trackChanges.record()
        }
        withObservationTracking {
            _ = model.selectedAudioID
        } onChange: {
            selectionChanges.record()
        }
        let french = MediaTrack(id: 2, kind: .audio, displayTitle: "French", language: "fra")
        engine.audioTracks.append(french)
        engine.onTracksChanged?()
        model.selectAudio(french)

        XCTAssertEqual(trackChanges.count, 1)
        XCTAssertEqual(selectionChanges.count, 1)
        XCTAssertEqual(model.selectedAudioID, 2)
        XCTAssertEqual(phaseChanges.count, 0)
        let resetChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.audioTracks
            _ = model.selectedAudioID
        } onChange: {
            resetChanges.record()
        }
        engine.onProgrammeChanged?()
        XCTAssertEqual(resetChanges.count, 1)
        XCTAssertTrue(model.audioTracks.isEmpty)
        XCTAssertNil(model.selectedAudioID)
        XCTAssertTrue(model.subtitles === originalSubtitles)
    }

    func testLiveSessionStartsAtFirstFrameAndReportsStateAndHeartbeat() async {
        let engine = LiveEngineSpy()
        let clock = LiveTestClock()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        var updates: [LiveTVPlaybackUpdate] = []
        model.setSessionReporting(.init(id: UUID(), update: { updates.append($0) }, failed: {}))
        await model.start()
        XCTAssertTrue(updates.isEmpty)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(updates.map(\.state), [.started])
        clock.now = 14
        model.refreshFromEngine()
        XCTAssertEqual(updates.count, 1)
        clock.now = 15
        model.refreshFromEngine()
        XCTAssertEqual(updates.map(\.state), [.started, .playing])
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertEqual(updates.last?.state, .paused)
        XCTAssertEqual(updates.last?.positionSeconds, 100)
        XCTAssertEqual(engine.vodLoads, 0)
    }

    func testNewLiveSessionReloadsEvenWhenItsResolvedURLIsUnchanged() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var original: [LiveTVPlaybackUpdate.State] = []
        var replacement: [LiveTVPlaybackUpdate.State] = []
        model.setSessionReporting(.init(id: UUID(), update: { original.append($0.state) }, failed: {}))
        await model.start()
        await model.changeSource(
            channelID: "",
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            reporting: .init(id: UUID(), update: { replacement.append($0.state) }, failed: {})
        )
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(original, [.started])
        XCTAssertEqual(replacement, [.started])
    }

    func testSameLiveSessionDoesNotRestartOrRepeatStartedReport() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var updates: [LiveTVPlaybackUpdate.State] = []
        let reporting = LiveChannelSessionReporting(id: UUID(), update: { updates.append($0.state) }, failed: {})
        model.setSessionReporting(reporting)
        await model.start()
        await model.changeSource(
            channelID: "",
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            reporting: reporting
        )
        model.refreshFromEngine()
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(updates, [.started])
    }

    func testLiveSessionFailureIsReportedOnceAndStopDoesNotReportFailure() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        var failures = 0
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { failures += 1 }))
        await model.start()
        engine.onFailure?(.serverUnreachable)
        engine.onFailure?(.serverUnreachable)
        model.refreshFromEngine()
        XCTAssertEqual(failures, 1)
        model.stop()
        XCTAssertEqual(failures, 1)

        let stopped = makeModel(engine: LiveEngineSpy())
        stopped.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { failures += 1 }))
        await stopped.start()
        stopped.stop()
        XCTAssertEqual(failures, 1)
    }

    func testPlayingIntentWithoutFirstFrameKeepsStartupCover() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testPlaylistHeadersSurviveLiveLoadRetryAndSourceReset() async {
        let engine = LiveEngineSpy()
        let headers = ["User-Agent": "IPTV test", "Referer": "https://example.invalid/"]
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/live.m3u8")!,
            httpHeaders: headers
        )
        defer { model.stop() }
        await model.start()
        engine.onFailure?(.serverUnreachable)
        await model.retry()
        engine.onLiveSourceReset?()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.loadedHeaders, Array(repeating: headers, count: engine.liveLoads))
        XCTAssertEqual(engine.liveLoads, 3)
    }

    func testChannelChangeReusesEngineWithNewURLAndHeaders() async {
        let engine = LiveEngineSpy()
        let firstURL = URL(string: "https://example.invalid/one.m3u8")!
        let secondURL = URL(string: "https://example.invalid/two.m3u8")!
        let firstHeaders = ["User-Agent": "First"]
        let secondHeaders = ["User-Agent": "Second", "Referer": "https://example.invalid/"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "one",
            streamURL: firstURL,
            httpHeaders: firstHeaders
        )
        defer { model.stop() }

        await model.start()
        await model.changeSource(
            channelID: "two",
            streamURL: secondURL,
            httpHeaders: secondHeaders
        )

        XCTAssertEqual(engine.loadedURLs, [firstURL, secondURL])
        XCTAssertEqual(engine.loadedHeaders, [firstHeaders, secondHeaders])
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testChannelChangeResetsPerChannelStateAndCoversPreviousFrame() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.onFailure?(.serverUnreachable)
        await model.retry()
        XCTAssertEqual(model.manualRetryCount, 1)
        XCTAssertTrue(model.hasPresentedFrame)

        engine.suspendsLoads = true
        let change = Task {
            await model.changeSource(
                channelID: "replacement",
                streamURL: URL(string: "https://example.invalid/replacement.m3u8")!,
                httpHeaders: ["Authorization": "fixture"]
            )
        }
        await waitForLiveLoads(3, engine: engine)

        XCTAssertEqual(model.manualRetryCount, 0)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertNil(model.seekableWindow)
        engine.resumeLoad(3)
        await change.value
        XCTAssertEqual(model.phase, .playing)
    }

    func testStaleChannelFailureCannotReplaceNewestPlaybackState() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let staleFailure = engine.capturedFailureHandlers[0]

        await model.changeSource(
            channelID: "newest",
            streamURL: URL(string: "https://example.invalid/newest.m3u8")!,
            httpHeaders: [:]
        )
        staleFailure(.unauthorized)

        XCTAssertEqual(model.phase, .playing)
        XCTAssertTrue(model.hasPresentedFrame)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testStaleLoadCompletionCannotPresentOldChannelFrame() async {
        let engine = LiveEngineSpy()
        engine.suspendsLoads = true
        let model = makeModel(engine: engine)
        defer { model.stop() }

        let firstLoad = Task { await model.start() }
        await waitForLiveLoads(1, engine: engine)
        let replacementLoad = Task {
            await model.changeSource(
                channelID: "replacement",
                streamURL: URL(string: "https://example.invalid/replacement.m3u8")!,
                httpHeaders: [:]
            )
        }
        await waitForLiveLoads(2, engine: engine)

        engine.resumeLoad(1)
        await firstLoad.value
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)

        engine.resumeLoad(2)
        await replacementLoad.value
        XCTAssertEqual(model.phase, .playing)
        XCTAssertTrue(model.hasPresentedFrame)
    }

    func testUnchangedSourceDoesNotReload() async {
        let engine = LiveEngineSpy()
        let url = URL(string: "https://example.invalid/channel.m3u8")!
        let headers = ["User-Agent": "IPTV test"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "same",
            streamURL: url,
            httpHeaders: headers
        )
        defer { model.stop() }
        await model.start()

        await model.changeSource(
            channelID: "same",
            streamURL: url,
            httpHeaders: headers
        )

        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testSameChannelIDReloadsWhenURLOrHeadersChange() async {
        let engine = LiveEngineSpy()
        let firstURL = URL(string: "https://example.invalid/original.m3u8")!
        let replacementURL = URL(string: "https://example.invalid/replacement.m3u8")!
        let firstHeaders = ["User-Agent": "Original"]
        let replacementHeaders = ["User-Agent": "Replacement"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "stable-id",
            streamURL: firstURL,
            httpHeaders: firstHeaders
        )
        defer { model.stop() }
        await model.start()

        await model.changeSource(
            channelID: "stable-id",
            streamURL: replacementURL,
            httpHeaders: firstHeaders
        )
        await model.changeSource(
            channelID: "stable-id",
            streamURL: replacementURL,
            httpHeaders: replacementHeaders
        )

        XCTAssertEqual(
            engine.loadedURLs,
            [firstURL, replacementURL, replacementURL]
        )
        XCTAssertEqual(
            engine.loadedHeaders,
            [firstHeaders, firstHeaders, replacementHeaders]
        )
    }

    func testChannelChangeResetsAutomaticRetuneBudget() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        for tick in 0..<3 {
            clock.now = Double(tick) * 20
            engine.onLiveSourceReset?()
            await model.requestRetune()?.value
        }
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))

        await model.changeSource(
            channelID: "new-budget",
            streamURL: URL(string: "https://example.invalid/new-budget.m3u8")!,
            httpHeaders: [:]
        )
        engine.onLiveSourceReset?()
        await model.requestRetune()?.value

        XCTAssertEqual(engine.liveLoads, 6)
        XCTAssertEqual(model.phase, .playing)
    }

    func testChannelChangePreservesUserPauseIntent() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()

        await model.changeSource(
            channelID: "paused-replacement",
            streamURL: URL(string: "https://example.invalid/paused.m3u8")!,
            httpHeaders: [:]
        )

        XCTAssertEqual(model.phase, .paused)
        XCTAssertTrue(engine.isPaused)
        model.togglePlayPause()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(engine.playCount, 1)
    }

    func testPausedReplacementCanResumeBeforeItsFirstFrameAndLiveWindow() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.firstFrameReady = false
        engine.liveSnapshot.seekableRange = nil
        engine.liveSnapshot.behindLiveSeconds = 10

        await model.changeSource(
            channelID: "paused-no-frame",
            streamURL: URL(string: "https://example.invalid/paused-no-frame.m3u8")!
        )

        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertTrue(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.playCount, 1)
    }

    func testFirstFrameTimingIsOncePerAttemptAndIncludesPauseBeforeFirstFrame() async {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.firstFrameReady = false
        clock.now = 100
        await model.changeSource(
            channelID: "timed-replacement",
            streamURL: URL(string: "https://example.invalid/timed.m3u8")!
        )
        clock.now = 110
        model.togglePlayPause()
        clock.now = 112
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()

        let lines = PlozzLog.recentEntries(limit: 50).map(\.message)
        let timing = lines.last { $0.contains("event=tuneToFirstFrame") }
        XCTAssertTrue(timing?.contains("elapsedMs=12000") == true)
        let occurrences = lines.filter { $0 == timing }.count
        model.refreshFromEngine()
        XCTAssertEqual(
            PlozzLog.recentEntries(limit: 50).map(\.message).filter { $0 == timing }.count,
            occurrences
        )
    }

    func testEnginePhaseOwnsStatusEvenWhileClockAdvances() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let cases: [(LiveChannelEnginePhase, LiveChannelPlaybackPhase)] = [
            (.rebuffering, .buffering),
            (.stalled(reconnecting: true), .reconnecting),
            (.stalled(reconnecting: false), .buffering),
            (.seeking, .seeking),
            (.paused, .paused),
            (.playing, .playing),
        ]
        for (enginePhase, expectedPhase) in cases {
            engine.liveSnapshot.phase = enginePhase
            engine.liveSnapshot.position += 1
            model.refreshFromEngine()
            XCTAssertEqual(model.phase, expectedPhase)
        }
    }

    func testPauseIntentWinsOverLatePlayingPublication() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.phase = .playing
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.showsActivityIndicator)
        model.togglePlayPause()
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(model.phase, .playing)
    }

    func testRouteReplacementWaitsForItsOwnFirstFrame() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.route = .localHLS
        engine.liveSnapshot.firstFrameReady = false
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .buffering)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
    }

    func testNoAdvertisedWindowDoesNotInventTimeshift() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = nil
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertFalse(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        await model.goLive()
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.goLiveCount, 0)
    }

    func testGoLiveUsesEngineAPIInsteadOfGuessingSeekTarget() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertTrue(model.canGoLive)
        await model.goLive()
        XCTAssertEqual(engine.goLiveCount, 1)
        XCTAssertEqual(engine.genericSeekCount, 0)
        XCTAssertTrue(model.isAtLiveEdge)
    }

    func testPauseDuringGoLiveDoesNotResumeAtCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.onGoLive = { model.togglePlayPause() }
        await model.goLive()
        model.refreshFromEngine()
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(model.phase, .paused)
    }

    func testStopDuringGoLiveIgnoresLateCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        await model.start()
        engine.onGoLive = { model.stop() }
        await model.goLive()
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertNil(engine.onLiveSourceReset)
    }

    func testStopDuringLoadDoesNotResurrectPlayback() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        engine.onLoad = { model.stop() }
        await model.start()
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertNil(engine.onFailure)
    }

    func testFailureDuringLoadSurvivesLateLoadCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        engine.onLoad = { engine.onFailure?(.notFound) }
        await model.start()
        XCTAssertEqual(model.phase, .failed(.engine(.notFound)))
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertTrue(model.canRetry)
    }

    func testStartupTimeoutStopsUnreadyEngine() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        clock.now = 29
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .loading)
        clock.now = 30
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.startupTimedOut))
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testStallAllowsEngineRecoveryButIsStillBounded() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.phase = .stalled(reconnecting: true)
        model.refreshFromEngine()
        clock.now = 59
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .reconnecting)
        clock.now = 60
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.bufferingTimedOut))
    }

    func testTerminalEngineErrorIsNotMistakenForBuffering() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.status = .failed(.unauthorized)
        engine.liveSnapshot.phase = .failed
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.engine(.unauthorized)))
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testManualRetriesAreBounded() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        for _ in 0..<3 {
            engine.onFailure?(.serverUnreachable)
            await model.retry()
        }
        XCTAssertEqual(engine.liveLoads, 3)
        XCTAssertEqual(model.manualRetryCount, 2)
        XCTAssertFalse(model.canRetry)
    }

    func testSourceResetRetunesOnlyThreeTimesPerChannelSession() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        for tick in 0..<3 {
            clock.now = Double(tick) * 20
            engine.onLiveSourceReset?()
            await model.requestRetune()?.value
            XCTAssertEqual(model.phase, .playing)
        }
        XCTAssertEqual(engine.liveLoads, 4)
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))
        XCTAssertEqual(engine.liveLoads, 4)
        await model.retry()
        XCTAssertEqual(engine.liveLoads, 5)
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))
        XCTAssertEqual(engine.liveLoads, 5)
    }

    func testSourceResetRaisedDuringLoadIsNotLost() async {
        let engine = LiveEngineSpy()
        engine.onLoad = {
            if engine.liveLoads == 1 { engine.onLiveSourceReset?() }
        }
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSourceResetWhilePausedWaitsForUserResume() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.onLiveSourceReset?()
        XCTAssertNil(model.requestRetune())
        XCTAssertEqual(engine.liveLoads, 1)
        model.togglePlayPause()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSourceResetWhileInactiveWaitsForForeground() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.handleScenePhase(.inactive)
        engine.onLiveSourceReset?()
        XCTAssertNil(model.requestRetune())
        XCTAssertEqual(engine.liveLoads, 1)
        model.handleScenePhase(.active)
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
    }

    func testRepeatedResetSignalsCoalesceBeforeRetuneStarts() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        for _ in 0..<100 { engine.onLiveSourceReset?() }
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testStopCancelsScheduledRecovery() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        await model.start()
        engine.onLiveSourceReset?()
        let task = model.requestRetune()
        model.stop()
        await task?.value
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertNil(engine.onLiveSourceReset)
    }

    func testBackgroundStopsEngineAndPausedReturnDoesNotAutoplay() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)
        XCTAssertEqual(engine.stopCount, 1)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.playCount, 0)
        let loaded = expectation(description: "Reload only after explicit resume")
        engine.onLoad = { loaded.fulfill() }
        model.togglePlayPause()
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(engine.liveLoads, 2)
    }

    func testInactiveReturnDoesNotReloadHealthyStream() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(model.phase, .playing)
    }

    private func waitForLiveLoads(
        _ expected: Int,
        engine: LiveEngineSpy
    ) async {
        for _ in 0..<100 {
            if engine.liveLoads >= expected { break }
            await Task.yield()
        }
        XCTAssertEqual(engine.liveLoads, expected)
    }
}

final class LiveChannelPlaybackFocusPolicyTests: XCTestCase {
    func testPlaybackPrefersPlayPauseWhenAvailable() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: true,
            canGoLive: false,
            canToggleFavorite: true
        )

        XCTAssertEqual(availability.preferredControl, .playPause)
    }

    func testPlaybackFallsBackToNextWhenPlayPauseIsUnavailable() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: false,
            canGoLive: false,
            canToggleFavorite: true
        )

        XCTAssertEqual(availability.preferredControl, .next)
    }

    func testNewPlayPauseAvailabilityDoesNotInvalidateExistingTransportFocus() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: true,
            canGoLive: false,
            canToggleFavorite: true
        )

        XCTAssertTrue(availability.contains(.next))
        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.tracks))
    }

    func testPlaybackEligibilityExcludesMissingAndEscapeControls() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: false,
            canGoLive: true,
            canToggleFavorite: true
        )

        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.goLive))
        XCTAssertTrue(availability.contains(.next))
        XCTAssertTrue(availability.contains(.favorite))
        XCTAssertTrue(availability.contains(.tracks))
        XCTAssertFalse(availability.contains(.playPause))
        XCTAssertFalse(availability.contains(.surface))
        XCTAssertFalse(availability.contains(.close))
        XCTAssertFalse(availability.contains(.retry))
        XCTAssertFalse(availability.contains(nil))
        XCTAssertFalse(
            LiveChannelPlaybackFocusPolicy.Availability.hidden.contains(.next)
        )
        XCTAssertFalse(
            LiveChannelPlaybackFocusPolicy.Availability.hidden.contains(.tracks)
        )
    }

    func testUnavailableFavoriteActionLeavesExistingTransportFocusValid() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: true,
            canGoLive: true,
            canToggleFavorite: false
        )

        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.playPause))
        XCTAssertTrue(availability.contains(.goLive))
        XCTAssertTrue(availability.contains(.next))
        XCTAssertFalse(availability.contains(.favorite))
    }

    func testInterruptionPrefersRetryThenFallsBackToClose() {
        XCTAssertEqual(
            LiveChannelPlaybackFocusPolicy.interruptionControl(canRetry: true),
            .retry
        )
        XCTAssertEqual(
            LiveChannelPlaybackFocusPolicy.interruptionControl(canRetry: false),
            .close
        )
    }
}

final class LiveChannelFavoriteControlStateTests: XCTestCase {
    func testFavoriteControlCopyMatchesPersistedState() {
        let add = LiveChannelFavoriteControlState(isFavorite: false, canToggle: true)
        XCTAssertEqual(String(localized: add.title), "Add to Favorites")
        XCTAssertEqual(add.systemImage, "star")
        XCTAssertTrue(add.canToggle)

        let remove = LiveChannelFavoriteControlState(isFavorite: true, canToggle: true)
        XCTAssertEqual(String(localized: remove.title), "Remove from Favorites")
        XCTAssertEqual(remove.systemImage, "star.fill")
        XCTAssertTrue(remove.canToggle)
    }

    func testFavoriteControlCanStayTruthfulWhilePersistenceIsUnavailable() {
        let state = LiveChannelFavoriteControlState(isFavorite: false, canToggle: false)

        XCTAssertEqual(String(localized: state.title), "Add to Favorites")
        XCTAssertEqual(state.systemImage, "star")
        XCTAssertFalse(state.canToggle)
    }
}

final class LiveChannelPlaybackStartPolicyTests: XCTestCase {
    func testExpandedAlreadyPlayingPreviewBecomesEligible() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: false,
                phase: .playing,
                hasPresentedFrame: true
            )
        )
        XCTAssertEqual(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            ),
            "station-a"
        )
    }

    func testDelayedStartupWaitsForPlayingFrame() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .loading,
                hasPresentedFrame: false
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: false
            )
        )
        XCTAssertEqual(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            ),
            "station-a"
        )
    }

    func testPreviewStalePausedAndInterruptedSourcesAreIneligible() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                sourceMatches: false,
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .paused,
                hasPresentedFrame: true
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .failed(.startupTimedOut),
                hasPresentedFrame: true
            )
        )
    }

    func testSuccessfulFullscreenSourcesNotifyOncePerViewing() {
        var policy = LiveChannelPlaybackStartPolicy<String>()

        XCTAssertTrue(policy.consume("station-a"))
        XCTAssertFalse(policy.consume("station-a"))
        policy.resetViewing()
        XCTAssertTrue(policy.consume("station-b"))
        XCTAssertFalse(policy.consume("station-b"))
        policy.resetViewing()
        XCTAssertTrue(policy.consume("station-a"))
    }

    func testFailedTuneDoesNotConsumeNotification() {
        var policy = LiveChannelPlaybackStartPolicy<String>()

        XCTAssertFalse(policy.consume(nil))
        XCTAssertTrue(policy.consume("station-b"))
    }

    private func eligibleSource(
        _ source: String,
        sourceMatches: Bool = true,
        isExpanded: Bool,
        phase: LiveChannelPlaybackPhase,
        hasPresentedFrame: Bool
    ) -> String? {
        LiveChannelPlaybackStartPolicy<String>.eligibleSource(
            source,
            sourceMatches: sourceMatches,
            isExpanded: isExpanded,
            phase: phase,
            hasPresentedFrame: hasPresentedFrame
        )
    }
}

private final class LiveTestClock {
    var now: TimeInterval = 0
}

#if os(tvOS)
@MainActor
final class LiveChannelFullscreenPresentationTests: XCTestCase {
    func testNativeFullscreenCoversNavigationAndReturnsTheSameOutputWithoutRetuning() async throws {
        let probe = LiveFullscreenProbe()
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 && probe.engine.outputView.window != nil }
        let root = try XCTUnwrap(window.rootViewController)
        let surface = probe.engine.outputView
        XCTAssertTrue(surface.isDescendant(of: root.view))

        for _ in 0..<2 {
            probe.expanded = true
            await waitUntil { root.presentedViewController?.view.window != nil }
            let fullscreen = try XCTUnwrap(root.presentedViewController)
            await waitUntil { surface.isDescendant(of: fullscreen.view) }
            XCTAssertTrue(surface.isDescendant(of: fullscreen.view))
            await waitUntil { focusIsInside(fullscreen.view, window: window) }
            XCTAssertTrue(focusIsInside(fullscreen.view, window: window),
                          "Focused item: \(String(describing: UIFocusSystem.focusSystem(for: window)?.focusedItem)); key window: \(window.isKeyWindow)")
            XCTAssertEqual(fullscreen.view.frame, window.bounds)
            XCTAssertTrue([UIModalPresentationStyle.fullScreen, .overFullScreen].contains(fullscreen.modalPresentationStyle))
            XCTAssertEqual(probe.creations, 1)
            XCTAssertEqual(probe.engine.liveLoads, 1)
            XCTAssertEqual(probe.engine.stopCount, 0)

            // Exercise a real presentation dismissal, not just an expanded flag.
            fullscreen.dismiss(animated: false)
            await waitUntil { !probe.expanded && surface.isDescendant(of: root.view) }
            XCTAssertFalse(probe.expanded)
            XCTAssertTrue(surface.isDescendant(of: root.view))
            XCTAssertEqual(probe.engine.liveLoads, 1)
            XCTAssertEqual(probe.engine.stopCount, 0)
        }
        XCTAssertEqual(probe.returns, 2)
        probe.active = false
        await waitUntil { probe.engine.stopCount == 1 }
        XCTAssertEqual(probe.engine.stopCount, 1)
    }

    func testExpandingDuringStartupDoesNotCancelThePendingLiveLoad() async throws {
        let probe = LiveFullscreenProbe()
        probe.engine.suspendsLoads = true
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 }
        probe.expanded = true
        await waitUntil { window.rootViewController?.presentedViewController?.view.window != nil }
        probe.engine.resumeLoad(1)
        await waitUntil { !probe.engine.cancelledLoads.isEmpty }
        XCTAssertEqual(probe.engine.cancelledLoads, [false])
        XCTAssertEqual(probe.creations, 1)
        XCTAssertEqual(probe.engine.liveLoads, 1)
        XCTAssertEqual(probe.engine.stopCount, 0)

        probe.active = false
        await waitUntil {
            probe.engine.stopCount == 1 && window.rootViewController?.presentedViewController == nil
        }
        XCTAssertEqual(probe.engine.stopCount, 1)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertEqual(probe.returns, 0)
    }

    func testTopBarFullscreenRetunesInPlaceAndHonorsAnExternalGuideReturn() async throws {
        let probe = LiveFullscreenProbe(usesSidebar: false)
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 }
        probe.expanded = true
        let root = try XCTUnwrap(window.rootViewController)
        await waitUntil { root.presentedViewController?.view.window != nil }
        let fullscreen = try XCTUnwrap(root.presentedViewController)
        probe.favorite = true
        probe.channelID = "replacement"
        await waitUntil { probe.engine.liveLoads == 2 }
        XCTAssertEqual(probe.engine.loadedURLs.last?.lastPathComponent, "replacement.m3u8")
        XCTAssertTrue(root.presentedViewController === fullscreen)
        XCTAssertTrue(probe.engine.outputView.isDescendant(of: fullscreen.view))
        XCTAssertEqual(probe.creations, 1)
        XCTAssertEqual(probe.engine.stopCount, 0)

        probe.expanded = false
        await waitUntil { root.presentedViewController == nil && probe.engine.outputView.isDescendant(of: root.view) }
        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(probe.engine.outputView.isDescendant(of: root.view))
        XCTAssertEqual(probe.returns, 0)
        XCTAssertEqual(probe.engine.liveLoads, 2)
        XCTAssertEqual(probe.engine.stopCount, 0)
        probe.active = false
        await waitUntil { probe.engine.stopCount == 1 }
    }

    private func makeWindow(_ probe: LiveFullscreenProbe) async throws -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            throw XCTSkip("Native fullscreen regressions require an app-hosted test with a window scene.")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: LiveFullscreenHarness(probe: probe).environment(\.scenePhase, .active)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        probe.active = true
        return window
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func focusIsInside(_ view: UIView, window: UIWindow) -> Bool {
        var environment: (any UIFocusEnvironment)? = UIFocusSystem.focusSystem(for: window)?.focusedItem
        while let current = environment {
            if let focusedView = current as? UIView {
                return focusedView.isDescendant(of: view)
            }
            environment = current.parentFocusEnvironment
        }
        return false
    }
}

@MainActor
@Observable
private final class LiveFullscreenProbe {
    let engine = LiveEngineSpy()
    let usesSidebar: Bool
    var expanded = false
    var active = false
    var channelID = "channel"
    var favorite = false
    var creations = 0
    var returns = 0

    init(usesSidebar: Bool = true) {
        self.usesSidebar = usesSidebar
    }
}

private struct LiveFullscreenHarness: View {
    let probe: LiveFullscreenProbe

    var body: some View {
        if #available(tvOS 27.0, *), probe.usesSidebar {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs.tabViewStyle(.tabBarOnly)
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Live TV", systemImage: "tv") {
                NavigationStack {
                    LiveChannelPlayerView(
                        channelID: probe.channelID,
                        title: "Live channel",
                        streamURL: URL(string: "https://example.invalid/\(probe.channelID).m3u8")!,
                        logoURL: nil,
                        makeEngine: { probe.creations += 1; return probe.engine },
                        onPreviousChannel: {}, onNextChannel: {},
                        isFavorite: probe.favorite, canToggleFavorite: true,
                        onToggleFavorite: { probe.favorite.toggle() },
                        isExpanded: probe.expanded,
                        usesNativeFullscreen: true,
                        isActive: probe.active,
                        onReturnToGuide: { probe.returns += 1; probe.expanded = false }
                    )
                }
                .toolbar(probe.expanded ? .hidden : .visible, for: .tabBar)
                .toolbar(.hidden, for: .navigationBar)
            }
            Tab("Home", systemImage: "house") { Text("Home") }
        }
    }
}
#endif

@MainActor
final class LiveEngineSpy: LiveChannelEngine {
    let outputView = UIView()
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .playing, firstFrameReady: true, position: 100,
        bufferedPosition: 110, seekableRange: 90...110,
        behindLiveSeconds: 10, route: .nativeHLS
    )
    var status: VideoEngineStatus = .ready
    var isPaused = false
    var currentTime: TimeInterval { liveSnapshot.position }
    var duration: TimeInterval { 0 }
    var furthestObservedPosition: TimeInterval { 0 }
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var currentAudioTrackID: Int?
    var selectedSubtitleID: Int?
    var continuesPlaybackInBackground = false
    var externalPlaybackRouteName: String?
    var onPresentationLayerChanged: (() -> Void)?
    var nativeSubtitlesActive = false
    func pictureInPicturePlayerLayer() -> AVPlayerLayer? { nil }
    func setPictureInPictureActive(_ active: Bool) { continuesPlaybackInBackground = active }
    func setNativeSubtitlesActive(_ active: Bool) { nativeSubtitlesActive = active }
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onLiveSourceReset: (@MainActor () -> Void)?
    var onProgrammeChanged: (@MainActor () -> Void)?
    var recoverableProgrammeIssue: LibraryChannelError?
    var onLoad: (@MainActor () async -> Void)?
    var onGoLive: (@MainActor () -> Void)?
    var loadedInputs: [LiveChannelInput] = []
    var inputLoadError: Error?
    var watching = false
    var liveLoads = 0
    var cancelledLoads: [Bool] = []
    var loadedURLs: [URL] = []
    var loadedHeaders: [[String: String]] = []
    var capturedFailureHandlers: [(@MainActor (AppError) -> Void)] = []
    var suspendsLoads = false
    private var loadContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    var vodLoads = 0
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var goLiveCount = 0
    var genericSeekCount = 0
    var outputPolicy = LiveChannelOutputPolicy()
    var onOutputPolicy: (@MainActor (LiveChannelOutputPolicy) -> Void)?
    var supportsConcurrentPlayback: Bool { true }

    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {
        outputPolicy = policy
        onOutputPolicy?(policy)
    }

    func setWatching(_ isWatching: Bool) { watching = isWatching }

    func loadChannel(_ input: LiveChannelInput) async throws {
        loadedInputs.append(input)
        if let inputLoadError { throw inputLoadError }
        if case .stream(let url, let headers) = input {
            await loadLive(url: url, httpHeaders: headers)
        }
    }

    func loadLive(url: URL, httpHeaders: [String: String]) async {
        liveLoads += 1
        let loadNumber = liveLoads
        loadedURLs.append(url)
        loadedHeaders.append(httpHeaders)
        if let onFailure {
            capturedFailureHandlers.append(onFailure)
        }
        status = .ready
        isPaused = false
        if suspendsLoads {
            await withCheckedContinuation { continuation in
                loadContinuations[loadNumber] = continuation
            }
        }
        await onLoad?()
        cancelledLoads.append(Task.isCancelled)
    }
    func resumeLoad(_ loadNumber: Int) {
        loadContinuations.removeValue(forKey: loadNumber)?.resume()
    }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async { vodLoads += 1 }
    func play() { playCount += 1; isPaused = false }
    func pause() { pauseCount += 1; isPaused = true }
    func stop() {
        stopCount += 1
        status = .idle
        onLoad = nil
        onGoLive = nil
    }
    func seek(to seconds: TimeInterval) async { genericSeekCount += 1 }
    func seekToLiveEdge() async {
        goLiveCount += 1
        onGoLive?()
        liveSnapshot.behindLiveSeconds = 0
    }
    func selectAudioTrack(_ track: MediaTrack?) { currentAudioTrackID = track?.id }
    func selectSubtitleTrack(_ track: MediaTrack?) { selectedSubtitleID = track?.id }
    func makeVideoOutputView() -> UIView { outputView }
}
#endif
