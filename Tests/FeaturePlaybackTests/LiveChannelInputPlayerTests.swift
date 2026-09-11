#if DEBUG && canImport(UIKit)
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelInputPlayerTests: XCTestCase {
    func testScheduledPauseResumeAndGoLiveDoNotRequireNativeDVRRange() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = nil
        engine.liveSnapshot.behindLiveSeconds = 0
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture")
        )
        defer { model.stop() }
        await model.start()
        XCTAssertTrue(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(model.phase, .paused)
        engine.liveSnapshot.behindLiveSeconds = 30
        model.refreshFromEngine()
        XCTAssertTrue(model.canGoLive)
        model.togglePlayPause()
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertTrue(model.canGoLive)
        await model.goLive()
        XCTAssertEqual(engine.goLiveCount, 1)
        XCTAssertEqual(engine.genericSeekCount, 0)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertFalse(model.canGoLive)
        XCTAssertEqual(engine.loadedInputs.count, 1)
    }

    func testScheduledControlsStillRequireAFrameAndRespectNetworkBlocks() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = nil
        engine.liveSnapshot.firstFrameReady = false
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture")
        )
        defer { model.stop() }
        await model.start()
        XCTAssertFalse(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        XCTAssertEqual(engine.pauseCount, 0)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertTrue(model.canPause)
        model.setNetworkBlock(.wifiRequired)
        XCTAssertFalse(model.canPause)
        XCTAssertFalse(model.canGoLive)
    }

    func testScheduledInputUsesRetainedEngineWithoutFabricatingAURLOrSeeking() async {
        let engine = LiveEngineSpy()
        let id = UUID()
        let input = LiveChannelInput.libraryChannel(id: id, authorizationID: "fixture")
        let model = LiveChannelPlayerModel(engine: engine, channelID: "library", input: input)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(engine.loadedInputs, [input])
        XCTAssertTrue(model.matchesSource(channelID: "library", input: input))
        XCTAssertEqual(engine.liveLoads, 0)
        XCTAssertEqual(engine.vodLoads, 0)
        XCTAssertEqual(engine.genericSeekCount, 0)
        XCTAssertEqual(engine.goLiveCount, 0)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSourceKindTransitionKeepsEngineAndRefreshesAuthorizedStreamHeaders() async {
        let engine = LiveEngineSpy()
        let id = UUID()
        let input = LiveChannelInput.libraryChannel(id: id, authorizationID: "fixture")
        let model = LiveChannelPlayerModel(engine: engine, channelID: "library", input: input)
        defer { model.stop() }
        await model.start()
        let url = URL(string: "https://example.invalid/authorized-live.m3u8")!
        let headers = ["X-Test-Authorization": "fixture"]
        await model.changeSource(channelID: "stream", input: .stream(url: url, httpHeaders: headers))
        XCTAssertTrue(model.engine === engine)
        XCTAssertEqual(engine.loadedInputs, [input, .stream(url: url, httpHeaders: headers)])
        XCTAssertEqual(engine.loadedHeaders, [headers])
        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testNewAuthorizationRetunesSameChannelOnRetainedEngineAndFencesOldCallbacks() async {
        let engine = LiveEngineSpy()
        let id = UUID()
        let channelID = "library:\(id.uuidString)"
        let original = LiveChannelInput.libraryChannel(id: id, authorizationID: "fixture-original")
        let replacement = LiveChannelInput.libraryChannel(id: id, authorizationID: "fixture-replacement")
        let model = LiveChannelPlayerModel(engine: engine, channelID: channelID, input: original)
        defer { model.stop() }
        await model.start()
        let obsoleteFailure = engine.onFailure
        let obsoleteProgrammeChanged = engine.onProgrammeChanged
        XCTAssertTrue(model.matchesSource(channelID: channelID, input: original))
        XCTAssertFalse(model.matchesSource(channelID: channelID, input: replacement))

        await model.changeSource(channelID: channelID, input: original)
        XCTAssertEqual(engine.loadedInputs, [original])
        await model.changeSource(channelID: channelID, input: replacement)
        obsoleteFailure?(.unauthorized)
        obsoleteProgrammeChanged?()

        XCTAssertTrue(model.engine === engine)
        XCTAssertEqual(engine.loadedInputs, [original, replacement])
        XCTAssertTrue(model.matchesSource(channelID: channelID, input: replacement))
        XCTAssertFalse(model.matchesSource(channelID: channelID, input: original))
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testThrowingInputDoesNotLeaveThePlayerLoading() async {
        let engine = LiveEngineSpy()
        engine.inputLoadError = AppError.unauthorized
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(model.phase, .failed(.engine(.unauthorized)))
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testWatchingEligibilityIsForwardedAndFinalStopCannotBeOverridden() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        await model.start()
        XCTAssertFalse(engine.watching)
        model.setWatching(true)
        XCTAssertTrue(engine.watching)
        model.setWatching(false)
        XCTAssertFalse(engine.watching)
        model.setWatching(true)
        model.stop()
        XCTAssertFalse(engine.watching)
        model.setWatching(true)
        XCTAssertFalse(engine.watching)
    }

    func testUnsupportedInputRetainsTypedReasonAndDoesNotOfferIneffectiveRetry() async {
        let engine = LiveEngineSpy()
        engine.inputLoadError = LiveChannelInputError.unsupportedSource
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(model.phase, .failed(.input(.unsupportedSource)))
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testUnavailableProgrammeKeepsScheduleOwnerAndRecoversWithoutRetuning() async {
        let engine = LiveEngineSpy()
        engine.inputLoadError = LibraryChannelError.mediaChanged
        engine.recoverableProgrammeIssue = .mediaChanged
        engine.liveSnapshot.phase = .failed
        engine.liveSnapshot.firstFrameReady = false
        engine.status = .failed(.notFound)
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        defer { model.stop() }
        var failures = 0
        var updates = 0
        model.setSessionReporting(.init(id: UUID(), update: { _ in updates += 1 }, failed: { failures += 1 }))
        await model.start()
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.library(.mediaChanged)))
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(updates, 0)
        engine.recoverableProgrammeIssue = nil
        engine.liveSnapshot.phase = .loading
        engine.status = .loading
        engine.onProgrammeChanged?()
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertEqual(updates, 0)
        engine.liveSnapshot.phase = .playing
        engine.liveSnapshot.firstFrameReady = true
        engine.status = .ready
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(engine.loadedInputs.count, 1)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testProgrammeRecoveryWithoutBoundaryCallbackStillResumesSnapshotPolling() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        defer { model.stop() }
        var failures = 0
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { failures += 1 }))
        await model.start()
        engine.recoverableProgrammeIssue = .playbackFailed
        engine.liveSnapshot.phase = .failed
        engine.liveSnapshot.firstFrameReady = false
        engine.status = .failed(.notFound)
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.library(.playbackFailed)))
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertEqual(failures, 0)
        engine.recoverableProgrammeIssue = nil
        engine.liveSnapshot.phase = .loading
        engine.status = .loading
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        engine.liveSnapshot.phase = .playing
        engine.liveSnapshot.firstFrameReady = true
        engine.status = .ready
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(engine.loadedInputs.count, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(failures, 0)
    }

    func testAuthorizationFailureAfterRecoverableGapIsTerminalAndKeepsTypedReason() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        await model.start()
        engine.recoverableProgrammeIssue = .mediaChanged
        model.refreshFromEngine()
        engine.recoverableProgrammeIssue = nil
        engine.inputLoadError = LibraryChannelError.authorizationChanged
        await model.retry()
        XCTAssertEqual(model.phase, .failed(.library(.authorizationChanged)))
        XCTAssertEqual(engine.stopCount, 1)
        model.stop()
    }

    func testAuthorizationLossDuringProgrammeGapStopsWithoutManualRetry() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"))
        defer { model.stop() }
        var failures = 0
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { failures += 1 }))
        await model.start()
        engine.recoverableProgrammeIssue = .mediaChanged
        engine.liveSnapshot.phase = .failed
        engine.liveSnapshot.firstFrameReady = false
        model.refreshFromEngine()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(engine.stopCount, 0)
        engine.recoverableProgrammeIssue = nil
        engine.status = .failed(.unauthorized)
        model.refreshFromEngine()
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.engine(.unauthorized)))
        XCTAssertEqual(engine.loadedInputs.count, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(failures, 1)
    }

    func testProgrammeResetReappliesLanguagesAndSubtitleOffToReusedTrackIDs() async {
        let engine = LiveEngineSpy()
        let preferences = LiveChannelTrackPreferences(audioLanguage: "fr", subtitleMode: .all, subtitleLanguage: "en")
        engine.audioTracks = [
            .init(id: 1, kind: .audio, displayTitle: "English", language: "eng"),
            .init(id: 2, kind: .audio, displayTitle: "French", language: "fra")
        ]
        engine.subtitleTracks = [.init(id: 5, kind: .subtitle, displayTitle: "English", language: "eng")]
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"), trackPreferences: preferences
        )
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(engine.currentAudioTrackID, 2)
        model.selectSubtitle(nil)
        engine.onProgrammeChanged?()
        XCTAssertTrue(model.audioTracks.isEmpty)
        XCTAssertTrue(model.subtitleTracks.isEmpty)
        engine.audioTracks = [
            .init(id: 1, kind: .audio, displayTitle: "French", language: "fra"),
            .init(id: 2, kind: .audio, displayTitle: "English", language: "eng")
        ]
        engine.currentAudioTrackID = 2
        engine.selectedSubtitleID = 5
        engine.onTracksChanged?()
        XCTAssertEqual(engine.currentAudioTrackID, 1)
        XCTAssertNil(engine.selectedSubtitleID)
        XCTAssertEqual(engine.loadedInputs.count, 1)
        XCTAssertEqual(engine.goLiveCount, 0)
        XCTAssertEqual(engine.genericSeekCount, 0)
    }

    func testProgrammeBoundaryReselectsBothLanguagesFromFreshTracksWithoutRetuning() async {
        let engine = LiveEngineSpy()
        let preferences = LiveChannelTrackPreferences(audioLanguage: "fr", subtitleMode: .all, subtitleLanguage: "en")
        engine.audioTracks = [
            .init(id: 1, kind: .audio, displayTitle: "English", language: "eng"),
            .init(id: 2, kind: .audio, displayTitle: "French", language: "fra")
        ]
        engine.subtitleTracks = [.init(id: 5, kind: .subtitle, displayTitle: "English", language: "eng")]
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"), trackPreferences: preferences
        )
        defer { model.stop() }
        let reportingID = UUID()
        var failures = 0
        model.setSessionReporting(.init(id: reportingID, update: { _ in }, failed: { failures += 1 }))
        await model.start()
        XCTAssertEqual(model.selectedAudioID, 2)
        XCTAssertEqual(model.selectedSubtitleID, 5)
        engine.onSubtitleCues?([.init(id: 1, start: 90, end: 110, body: .text(.init("Old programme")))])
        XCTAssertEqual(model.subtitles.primary.count, 1)

        engine.onProgrammeChanged?()
        XCTAssertTrue(model.audioTracks.isEmpty)
        XCTAssertTrue(model.subtitleTracks.isEmpty)
        XCTAssertTrue(model.subtitles.primary.isEmpty)
        XCTAssertNil(model.selectedAudioID)
        XCTAssertNil(model.selectedSubtitleID)
        XCTAssertFalse(model.hasPresentedFrame)
        engine.audioTracks = [
            .init(id: 11, kind: .audio, displayTitle: "Français", language: "fr"),
            .init(id: 12, kind: .audio, displayTitle: "English", language: "en")
        ]
        engine.subtitleTracks = [
            .init(id: 15, kind: .subtitle, displayTitle: "Français", language: "fr"),
            .init(id: 16, kind: .subtitle, displayTitle: "English", language: "en")
        ]
        engine.currentAudioTrackID = 12
        engine.selectedSubtitleID = 15
        engine.onTracksChanged?()

        XCTAssertEqual(model.selectedAudioID, 11)
        XCTAssertEqual(model.selectedSubtitleID, 16)
        XCTAssertEqual(preferences.audioLanguage, "fr")
        XCTAssertEqual(preferences.subtitleLanguage, "en")
        XCTAssertEqual(preferences.subtitleMode, .all)
        XCTAssertEqual(model.sessionReportingID, reportingID)
        XCTAssertEqual(engine.loadedInputs.count, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(failures, 0)
        model.stop()
        XCTAssertNil(engine.onProgrammeChanged)
    }

    func testGeneratedStartupUsesSessionDeadlineInsteadOfEarlierIPTVTimeout() async {
        let engine = LiveEngineSpy()
        var now: TimeInterval = 0
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "fixture"), uptime: { now }
        )
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.firstFrameReady = false
        engine.liveSnapshot.phase = .loading
        engine.onProgrammeChanged?()
        now = 35
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(engine.stopCount, 0)
    }
}
#endif
