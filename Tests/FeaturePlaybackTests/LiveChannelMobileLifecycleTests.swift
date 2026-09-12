#if DEBUG && os(iOS)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

extension LiveEngineSpy: PictureInPicturePresentingEngine {}

@MainActor
final class LiveChannelMobileLifecycleTests: XCTestCase {
    private func makeModel(
        _ engine: LiveEngineSpy,
        preferences: LiveChannelTrackPreferences? = nil
    ) -> LiveChannelPlayerModel {
        LiveChannelPlayerModel(
            engine: engine,
            streamURL: URL(string: "https://example.invalid/live.m3u8")!,
            trackPreferences: preferences
        )
    }

    func testExistingExternalPlaybackSurvivesInactiveBackgroundAndNavigationWithoutReload() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        engine.continuesPlaybackInBackground = true
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)
        model.setVisible(false)
        XCTAssertTrue(model.continuesExternally)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(engine.liveLoads, 1)
        model.setVisible(true)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testStartingPiPResumesAnInactivePauseAndFinalStopStopsHiddenPlayback() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        await model.start()
        model.handleScenePhase(.inactive)
        XCTAssertTrue(engine.isPaused)
        model.setExternalContinuation(true)
        XCTAssertFalse(engine.isPaused)
        model.setVisible(false)
        XCTAssertEqual(engine.stopCount, 0)
        model.setExternalContinuation(false)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(model.continuesExternally)
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testFailedPiPStartInBackgroundStopsRatherThanLeavingAudioRunning() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        model.setExternalContinuation(true)
        model.handleScenePhase(.background)
        XCTAssertEqual(engine.stopCount, 0)
        model.setExternalContinuation(false)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testOrdinaryHiddenPlaybackStopsAndCannotRestartFromLateExternalCallbacks() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        await model.start()
        model.setVisible(false)
        model.setExternalContinuation(true)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(model.continuesExternally)
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testAuthorizationFinalStopAlwaysInvalidatesNativePresentation() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        await model.start()
        var invalidations = 0
        model.onPresentationInvalidated = {
            invalidations += 1
            engine.continuesPlaybackInBackground = false
        }
        engine.continuesPlaybackInBackground = true
        model.refreshFromEngine()
        model.stop()
        model.stop()
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(model.continuesExternally)
    }

    func testMultiviewPermissionRejectsActualRouteAndLateContinuationCallbacks() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        engine.continuesPlaybackInBackground = true
        model.refreshFromEngine()
        XCTAssertTrue(model.continuesExternally)
        model.setPermitsExternalPresentation(false)
        model.setExternalContinuation(true)
        model.refreshFromEngine()
        XCTAssertFalse(model.continuesExternally)
        engine.continuesPlaybackInBackground = false
        model.setPermitsExternalPresentation(true)
        XCTAssertFalse(model.continuesExternally)
        model.setVisible(false)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testWifiOnlyHandoffStopsMediaRatherThanJustPausingHLS() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        model.setNetworkBlock(.wifiRequired)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(model.canPause)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertEqual(model.networkBlock, .wifiRequired)
        await model.retry()
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testUnknownConnectionBlocksInitialMediaLoad() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        model.setNetworkBlock(.checkingConnection)
        await model.start()
        XCTAssertEqual(engine.liveLoads, 0)
    }

    func testLateLoadCompletionCannotResumeAfterWifiOnlyBlocksThePath() async {
        let engine = LiveEngineSpy()
        engine.suspendsLoads = true
        let model = makeModel(engine)
        defer { model.stop() }
        let load = Task { await model.start() }
        for _ in 0..<100 where engine.liveLoads == 0 { await Task.yield() }
        XCTAssertEqual(engine.liveLoads, 1)
        model.setNetworkBlock(.wifiRequired)
        engine.resumeLoad(1)
        await load.value
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.playCount, 0)
    }

    func testNetworkBlockAlwaysEndsExternalContinuation() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        engine.continuesPlaybackInBackground = true
        model.refreshFromEngine()
        XCTAssertTrue(model.continuesExternally)
        model.setNetworkBlock(.lowDataMode)
        XCTAssertFalse(model.continuesExternally)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(model.networkBlock, .lowDataMode)
    }

    func testRetiringAnExternalOwnerStopsItWithoutResettingAnotherPane() async {
        let group = LiveChannelOutputGroup()
        let firstEngine = LiveEngineSpy()
        var first: LiveChannelPlayerModel? = LiveChannelPlayerModel(
            engine: firstEngine, streamURL: URL(string: "https://example.invalid/first.m3u8")!,
            outputGroup: group
        )
        await first?.start()
        first?.setExternalContinuation(true)
        let secondEngine = LiveEngineSpy()
        let second = LiveChannelPlayerModel(
            engine: secondEngine, streamURL: URL(string: "https://example.invalid/second.m3u8")!,
            outputGroup: group
        )
        defer { second.stop() }
        await second.start()
        weak var released = first
        first = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(released)
        XCTAssertEqual(firstEngine.stopCount, 1)
        XCTAssertTrue(firstEngine.outputPolicy.sharesAudioSession)
        XCTAssertTrue(firstEngine.outputPolicy.suppressesDisplayMatching)
        XCTAssertEqual(secondEngine.stopCount, 0)
    }

    func testLeavingOneLivePaneDoesNotReleaseAnotherPanesWakeLease() async {
        var wakeRequests: [Bool] = []
        let group = LiveChannelWakeGroup { wakeRequests.append($0) }
        let first = LiveChannelWakeLease(group: group)
        let second = LiveChannelWakeLease(group: group)
        first.keepAwake(true)
        first.keepAwake(true)
        second.keepAwake(true)
        first.allowSleep()
        XCTAssertFalse(wakeRequests.contains(false))
        XCTAssertEqual(wakeRequests.last, true)
        second.allowSleep()
        XCTAssertEqual(wakeRequests.last, false)
    }

    func testDefaultLivePaneLeasesShareWakeOwnership() {
        let first = LiveChannelWakeLease()
        let second = LiveChannelWakeLease()
        XCTAssertTrue(first.group === second.group)
    }

    func testDeinitializingOneLivePanePreservesOtherWakeOwner() async {
        var wakeRequests: [Bool] = []
        let group = LiveChannelWakeGroup { wakeRequests.append($0) }
        var first: LiveChannelWakeLease? = LiveChannelWakeLease(group: group)
        let second = LiveChannelWakeLease(group: group)
        first?.keepAwake(true)
        second.keepAwake(true)
        weak var released = first
        first = nil
        for _ in 0..<100 where wakeRequests.count < 3 { await Task.yield() }
        XCTAssertNil(released)
        XCTAssertGreaterThanOrEqual(wakeRequests.count, 3)
        XCTAssertFalse(wakeRequests.contains(false))
        XCTAssertEqual(wakeRequests.last, true)
        second.allowSleep()
        XCTAssertEqual(wakeRequests.last, false)
    }

    func testDeinitializingFinalWakeOwnerRequestsSleep() async {
        var wakeRequests: [Bool] = []
        let group = LiveChannelWakeGroup { wakeRequests.append($0) }
        var lease: LiveChannelWakeLease? = LiveChannelWakeLease(group: group)
        lease?.keepAwake(true)
        lease = nil
        for _ in 0..<100 where wakeRequests.count < 2 { await Task.yield() }
        XCTAssertEqual(wakeRequests, [true, false])
    }

    func testNetworkRecoveryInBackgroundDoesNotAutomaticallyOpenAStream() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine)
        defer { model.stop() }
        await model.start()
        model.setNetworkBlock(.wifiRequired)
        model.handleScenePhase(.background)
        model.setNetworkBlock(nil)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testChosenLanguagesResolveNewSourceIDsAndSubtitlesOffSurvivesChannelChanges() async {
        let engine = LiveEngineSpy()
        let preferences = LiveChannelTrackPreferences(audioLanguage: "fr", subtitleMode: .all, subtitleLanguage: "en")
        engine.audioTracks = [
            .init(id: 1, kind: .audio, displayTitle: "English", language: "eng"),
            .init(id: 2, kind: .audio, displayTitle: "French", language: "fra")
        ]
        engine.subtitleTracks = [.init(id: 5, kind: .subtitle, displayTitle: "English", language: "eng")]
        let model = makeModel(engine, preferences: preferences)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(engine.currentAudioTrackID, 2)
        XCTAssertEqual(engine.selectedSubtitleID, 5)
        model.selectSubtitle(nil)
        engine.audioTracks = [.init(id: 42, kind: .audio, displayTitle: "French", language: "fre")]
        engine.subtitleTracks = [.init(id: 45, kind: .subtitle, displayTitle: "English", language: "eng")]
        await model.changeSource(channelID: "other", streamURL: URL(string: "https://example.invalid/other.m3u8")!)
        XCTAssertEqual(engine.currentAudioTrackID, 42)
        XCTAssertNil(engine.selectedSubtitleID)
        XCTAssertEqual(preferences.subtitleMode, .off)
    }
}
#endif
