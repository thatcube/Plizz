import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPreviewControllerTests: XCTestCase {
    func testInitialGuideFocusTargetsFirstVisibleChannelExactlyOnce() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        XCTAssertEqual(
            preview.requestInitialGuideFocus(isActive: true, hasOverlay: false),
            model.guideChannels.first?.id
        )
        XCTAssertTrue(preview.hasRequestedInitialGuideFocus)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        XCTAssertFalse(preview.restoresPlaybackFocus)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
        preview.stop()
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
    }

    func testInitialFocusWaitsForChannelsAndAnActiveUnobscuredGuide() {
        let empty = LiveTVPreviewController(model: LiveTVPrototypeModel(channels: []))
        XCTAssertNil(empty.requestInitialGuideFocus(isActive: true, hasOverlay: false))
        XCTAssertFalse(empty.hasRequestedInitialGuideFocus)
        let preview = LiveTVPreviewController(model: LiveTVPrototypeModel())
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: false, hasOverlay: false))
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: true))
        XCTAssertFalse(preview.hasRequestedInitialGuideFocus)
        XCTAssertNotNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
    }

    func testInitialFocusNeverReplacesAnExplicitGuideOrPlaybackReturn() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[1].id)
        preview.returnToGuide()
        let request = preview.focusRestoreRequest
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
        XCTAssertEqual(preview.focusRestoreRequest, request)
        XCTAssertTrue(preview.restoresPlaybackFocus)
        let browsing = LiveTVPreviewController(model: model)
        browsing.requestBrowsingFocus()
        XCTAssertNil(browsing.requestInitialGuideFocus(isActive: true, hasOverlay: false))
    }

    func testSearchSuppressesNavigationUntilTheReturningGuideOwnsFocus() {
        let preview = LiveTVPreviewController(model: LiveTVPrototypeModel())
        XCTAssertFalse(preview.suppressesNavigation(isActive: true))
        XCTAssertTrue(preview.suppressesNavigation(isActive: true, isSearching: true))

        preview.requestBrowsingFocus()
        XCTAssertTrue(preview.suppressesNavigation(isActive: true, isSearching: true))
        XCTAssertTrue(preview.suppressesNavigation(isActive: true, isSearching: false))
        let oldRequest = preview.focusRestoreRequest
        preview.requestBrowsingFocus()
        preview.completeGuideFocusRestore(oldRequest)
        XCTAssertTrue(preview.suppressesNavigation(isActive: true))
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        XCTAssertFalse(preview.suppressesNavigation(isActive: true))
    }

    func testSearchKeepsNavigationSuppressedAfterAnInSearchFocusHandoff() {
        let preview = LiveTVPreviewController(model: LiveTVPrototypeModel())
        preview.requestBrowsingFocus()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        XCTAssertTrue(preview.suppressesNavigation(isActive: true, isSearching: true))
        XCTAssertFalse(preview.suppressesNavigation(isActive: true, isSearching: false))
    }

    func testInactiveLiveTVCannotSuppressAnotherDestinationsNavigation() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        XCTAssertTrue(preview.suppressesNavigation(isActive: true))
        XCTAssertFalse(preview.suppressesNavigation(isActive: false, isSearching: true))
        preview.returnToGuide()
        XCTAssertFalse(preview.suppressesNavigation(isActive: false, isSearching: true))
        preview.stop()
        XCTAssertFalse(preview.suppressesNavigation(isActive: false, isSearching: true))
    }

    func testPreviewWaitsForCommitAndOnlyLatestChannelWins() throws {
        let model = LiveTVPrototypeModel(scenario: .noGuide)
        let preview = LiveTVPreviewController(model: model)
        let first = model.channels[0].id
        let second = model.channels[1].id

        preview.focus(first)
        let stale = try XCTUnwrap(preview.pendingRequest)
        XCTAssertNil(model.playingChannelID)
        XCTAssertEqual(LiveTVPreviewController.settlingDelay, .milliseconds(600))
        preview.focus(second)
        XCTAssertFalse(preview.commitPreview(stale))
        XCTAssertNil(model.playingChannelID)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        XCTAssertEqual(model.playingChannelID, second)
        XCTAssertFalse(preview.isExpanded)
    }

    func testReturningToSameChannelDoesNotAcceptItsOldRequest() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.focus(model.channels[1].id)
        preview.focus(model.channels[0].id)
        XCTAssertNotEqual(stale, preview.pendingRequest)
        preview.commitPreview(stale)
        XCTAssertNil(model.playingChannelID)
    }

    func testHorizontalProgramFocusDoesNotRestartDebounceOrTune() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let id = model.channels[0].id
        preview.focus(id)
        let request = try XCTUnwrap(preview.pendingRequest)
        preview.focus(id)
        XCTAssertEqual(preview.pendingRequest, request)
        preview.commitPreview(request)
        preview.focus(id)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertNil(model.previousChannelID)
    }

    func testWatchAndReturnRestoreTheWatchedChannelThenResumeFocusPreviewsByDefault() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let id = model.channels[0].id
        preview.focus(id)
        preview.commitPreview(try XCTUnwrap(preview.pendingRequest))
        preview.watch(id)
        XCTAssertTrue(preview.isExpanded)
        XCTAssertNil(model.previousChannelID)
        preview.focus(model.channels[1].id)
        XCTAssertNil(preview.pendingRequest)
        preview.returnToGuide()
        XCTAssertFalse(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, id)
        XCTAssertEqual(preview.focusRestoreRequest, 1)
        XCTAssertTrue(preview.followsFocus)
        XCTAssertFalse(preview.keepWatchingWhileBrowsing)
        XCTAssertNil(preview.pendingRequest)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: id)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertNil(model.previousChannelID)
        preview.focus(id)
        XCTAssertNil(preview.pendingRequest)
        preview.focus(model.channels[1].id)
        preview.commitPreview(try XCTUnwrap(preview.pendingRequest))
        XCTAssertEqual(model.playingChannelID, model.channels[1].id)
    }

    func testSelectingAnotherChannelCancelsPendingPreview() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.watch(model.channels[1].id)
        preview.commitPreview(stale)
        XCTAssertTrue(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, model.channels[1].id)
    }

    func testControlsSheetsAndInactiveSceneInvalidatePendingPreview() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.setBrowsingActive(false)
        preview.commitPreview(stale)
        XCTAssertNil(model.playingChannelID)
        preview.focus(model.channels[1].id)
        XCTAssertNil(preview.pendingRequest)
        preview.setBrowsingActive(true)
        preview.commitPreview(try XCTUnwrap(preview.pendingRequest))
        XCTAssertEqual(model.playingChannelID, model.channels[1].id)
    }

    func testFilteringOutPendingChannelPreventsTune() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        let request = try XCTUnwrap(preview.pendingRequest)
        model.query = "no-matching-channel"
        preview.commitPreview(request)
        XCTAssertNil(model.playingChannelID)
        XCTAssertFalse(model.tuneFailed)
    }

    func testNoGuideStillPreviewsAndStoppingInvalidatesRequests() throws {
        let model = LiveTVPrototypeModel(scenario: .noGuide)
        let preview = LiveTVPreviewController(model: model)
        let channel = model.channels[0]
        XCTAssertNil(model.currentProgram(for: channel.id))
        XCTAssertFalse(channel.category.isEmpty)
        preview.focus(channel.id)
        preview.commitPreview(try XCTUnwrap(preview.pendingRequest))
        XCTAssertEqual(model.playingChannelID, channel.id)
        preview.focus(model.channels[1].id)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.stop()
        preview.commitPreview(stale)
        XCTAssertNil(model.playingChannelID)
        XCTAssertFalse(preview.isExpanded)
    }

    func testTouchBrowsingCanKeepAutoplayOffUntilExplicitSelection() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model, followsFocus: false)
        preview.focus(model.channels[0].id)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertNil(model.playingChannelID)
        preview.watch(model.channels[0].id)
        XCTAssertTrue(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, model.channels[0].id)
    }

    func testLeavingTheDestinationStopsFullScreenWithoutChangingPreviewPreference() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.stop()
        preview.setBrowsingActive(false)
        XCTAssertNil(model.playingChannelID)
        XCTAssertFalse(preview.isExpanded)
        XCTAssertTrue(preview.followsFocus)
        preview.focus(model.channels[1].id)
        XCTAssertNil(preview.pendingRequest)
    }

    func testReturningToDestinationCanPreviewTheRememberedChannelWithoutAcceptingOldWork() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let channelID = model.channels[0].id
        preview.focus(channelID)
        let oldRequest = try XCTUnwrap(preview.pendingRequest)
        preview.stop()
        preview.setBrowsingActive(false)
        preview.focus(channelID)
        XCTAssertFalse(preview.commitPreview(oldRequest))
        XCTAssertNil(model.playingChannelID)
        preview.setBrowsingActive(true)
        let newRequest = try XCTUnwrap(preview.pendingRequest)
        XCTAssertNotEqual(oldRequest, newRequest)
        XCTAssertTrue(preview.commitPreview(newRequest))
        XCTAssertEqual(model.playingChannelID, channelID)
    }

    func testFailedSelectionKeepsCurrentPreviewWithoutExpanding() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        preview.commitPreview(try XCTUnwrap(preview.pendingRequest))
        model.simulateTunerBusy = true
        preview.watch(model.channels[1].id)
        XCTAssertTrue(model.tuneFailed)
        XCTAssertFalse(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, model.channels[0].id)
    }

    func testReturningGuideGatesControlsUntilItsOwnFocusRequestCompletes() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let channelID = model.channels[0].id
        preview.watch(channelID)
        preview.returnToGuide()
        let first = preview.focusRestoreRequest
        XCTAssertTrue(preview.isRestoringGuideFocus)
        XCTAssertFalse(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, channelID)
        preview.watch(channelID)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(first)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        XCTAssertFalse(preview.isRestoringGuideFocus)
        XCTAssertEqual(model.playingChannelID, channelID)
    }

    func testStoppingAndTouchReturnCannotLeaveFocusRestorationLatched() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let channelID = model.channels[0].id
        preview.watch(channelID)
        preview.returnToGuide()
        preview.stop()
        XCTAssertFalse(preview.isRestoringGuideFocus)
        preview.watch(channelID)
        preview.returnToGuide(restoresFocus: false)
        XCTAssertFalse(preview.isRestoringGuideFocus)
        XCTAssertEqual(model.playingChannelID, channelID)
    }

    func testWatchingKeepsTheEntrySectionThroughRecentPromotionAndTransport() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let id = model.channels[0].id
        let origin = LiveTVGuideRowID(channelID: id, section: .favorites)
        preview.watch(id, origin: origin)
        model.recordWatched(id)
        preview.returnToGuide()
        XCTAssertEqual(preview.watchOrigin, origin)
        XCTAssertTrue(preview.restoresPlaybackFocus)
        preview.watch(id, origin: origin)
        let next = model.channels[1].id
        preview.watch(next)
        XCTAssertEqual(preview.watchOrigin, LiveTVGuideRowID(channelID: next, section: .favorites))
        preview.watch(model.channels[6].id)
        XCTAssertEqual(preview.watchOrigin?.section, .channels)
    }

    func testSidebarEntryHasABoundedRequestWithoutExpandingOrRetuning() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.focus(model.channels[0].id)
        XCTAssertNotNil(preview.pendingRequest)
        preview.requestBrowsingFocus()
        XCTAssertNil(preview.pendingRequest)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        XCTAssertFalse(preview.restoresPlaybackFocus)
        XCTAssertFalse(preview.isExpanded)
        XCTAssertNil(model.playingChannelID)
        let first = preview.focusRestoreRequest
        preview.requestBrowsingFocus()
        preview.completeGuideFocusRestore(first)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        XCTAssertFalse(preview.isRestoringGuideFocus)
        let id = model.channels[0].id
        preview.watch(id)
        preview.requestBrowsingFocus()
        XCTAssertTrue(preview.isExpanded)
        preview.returnToGuide()
        XCTAssertTrue(preview.restoresPlaybackFocus)
    }

    func testRepeatedFullscreenVisitsNeverTurnOffAutoPreview() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        for index in 0..<3 {
            let watched = model.channels[index].id
            let next = model.channels[index + 1].id
            preview.watch(watched)
            preview.returnToGuide()
            preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
            preview.focus(next)
            XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
            XCTAssertEqual(model.playingChannelID, next)
            XCTAssertTrue(preview.followsFocus)
        }
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
    }

    func testKeepWatchingOnlySuppressesPreviewsAfterAnExplicitSelection() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model, keepWatchingWhileBrowsing: true)
        let watched = model.channels[0].id
        XCTAssertFalse(preview.isHoldingWatchedChannel)
        preview.focus(watched)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        preview.focus(model.channels[1].id)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        preview.watch(watched)
        XCTAssertTrue(preview.isHoldingWatchedChannel)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        preview.focus(model.channels[2].id)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        XCTAssertTrue(preview.followsFocus)
        preview.watch(model.channels[2].id)
        XCTAssertTrue(preview.isExpanded)
        XCTAssertEqual(model.playingChannelID, model.channels[2].id)
    }

    func testTurningOffKeepWatchingResumesSettlingAndTurningItOnCancelsPendingWork() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model, keepWatchingWhileBrowsing: true)
        let watched = model.channels[0].id
        let focused = model.channels[1].id
        preview.watch(watched)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        preview.focus(focused)
        preview.setKeepWatchingWhileBrowsing(false)
        let stale = try XCTUnwrap(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.setKeepWatchingWhileBrowsing(true)
        XCTAssertFalse(preview.commitPreview(stale))
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.setKeepWatchingWhileBrowsing(false)
        let current = try XCTUnwrap(preview.pendingRequest)
        XCTAssertNotEqual(current, stale)
        XCTAssertTrue(preview.commitPreview(current))
        XCTAssertEqual(model.playingChannelID, focused)
    }

    func testEnablingKeepWatchingDoesNotRetuneAnEarlierWatchedChannel() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        let current = model.channels[1].id
        preview.focus(current)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        preview.setKeepWatchingWhileBrowsing(true)
        preview.focus(model.channels[2].id)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, current)
    }

    func testPreferencesChangedDuringFullscreenApplyAfterReturnWithoutRetuningEarly() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model, followsFocus: false)
        let watched = model.channels[0].id
        let next = model.channels[1].id
        preview.watch(watched)
        preview.focus(next)
        preview.setFollowsFocus(true)
        preview.setKeepWatchingWhileBrowsing(true)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        preview.focus(next)
        XCTAssertNil(preview.pendingRequest)
        preview.setKeepWatchingWhileBrowsing(false)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
    }

    func testAutoPreviewOffStillRequiresSelectionAfterWatchingRegardlessOfHoldPreference() throws {
        for keepWatching in [false, true] {
            let model = LiveTVPrototypeModel()
            let preview = LiveTVPreviewController(
                model: model, followsFocus: false, keepWatchingWhileBrowsing: keepWatching
            )
            let watched = model.channels[0].id
            let focused = model.channels[1].id
            preview.watch(watched)
            preview.returnToGuide()
            preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
            preview.focus(focused)
            XCTAssertNil(preview.pendingRequest)
            preview.setKeepWatchingWhileBrowsing(!keepWatching)
            XCTAssertNil(preview.pendingRequest)
            XCTAssertFalse(preview.followsFocus)
            XCTAssertEqual(model.playingChannelID, watched)
            preview.setKeepWatchingWhileBrowsing(false)
            preview.setFollowsFocus(true)
            XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
            XCTAssertEqual(model.playingChannelID, focused)
        }
    }

    func testDisablingAutoPreviewCancelsPostWatchRequestAndReenablingUsesFreshRequest() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest)
        preview.focus(model.channels[1].id)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.setFollowsFocus(false)
        XCTAssertFalse(preview.commitPreview(stale))
        XCTAssertNil(preview.pendingRequest)
        preview.setFollowsFocus(true)
        let current = try XCTUnwrap(preview.pendingRequest)
        preview.setFollowsFocus(true)
        preview.setKeepWatchingWhileBrowsing(false)
        XCTAssertEqual(preview.pendingRequest, current)
        XCTAssertNotEqual(current, stale)
        XCTAssertTrue(preview.commitPreview(current))
    }

    func testRestoreGatesTransientFocusAndSettingsUntilFinalFocusIsDelivered() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let watched = model.channels[0].id
        let other = model.channels[1].id
        preview.watch(watched)
        preview.focus(other)
        preview.returnToGuide()
        preview.focus(other)
        preview.setFollowsFocus(false)
        preview.setKeepWatchingWhileBrowsing(true)
        preview.setFollowsFocus(true)
        preview.setKeepWatchingWhileBrowsing(false)
        XCTAssertNil(preview.pendingRequest)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.focus(other)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
    }

    func testRestorationToAnotherVisibleChannelStartsANewSettlingRequestOnlyAfterHandoff() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let watched = model.channels[0].id
        let fallback = model.channels[1].id
        preview.watch(watched)
        preview.returnToGuide()
        model.query = model.channels[1].name
        preview.focus(fallback)
        XCTAssertNil(preview.pendingRequest)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: fallback)
        let request = try XCTUnwrap(preview.pendingRequest)
        XCTAssertEqual(request.channelID, fallback)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.focus(fallback)
        XCTAssertEqual(preview.pendingRequest, request)
        XCTAssertTrue(preview.commitPreview(request))
        XCTAssertEqual(model.playingChannelID, fallback)
    }

    func testSupersededAndDuplicateRestoreCallbacksCannotChangeFocusOrRestartSettling() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.returnToGuide()
        let stale = preview.focusRestoreRequest
        preview.requestBrowsingFocus()
        let current = preview.focusRestoreRequest
        preview.completeGuideFocusRestore(stale, focusedChannelID: model.channels[2].id)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        XCTAssertNil(preview.pendingRequest)
        let focused = model.channels[1].id
        preview.completeGuideFocusRestore(current, focusedChannelID: focused)
        let pending = try XCTUnwrap(preview.pendingRequest)
        preview.completeGuideFocusRestore(current, focusedChannelID: model.channels[2].id)
        preview.completeGuideFocusRestore(current)
        XCTAssertEqual(preview.pendingRequest, pending)
        XCTAssertTrue(preview.commitPreview(pending))
        XCTAssertEqual(model.playingChannelID, focused)
    }

    func testInitialAndSidebarHandoffsRearmPreviewEvenWhenChannelFocusDoesNotChange() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let first = try XCTUnwrap(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
        preview.focus(first.channelID)
        XCTAssertNil(preview.pendingRequest)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: first.channelID)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.requestBrowsingFocus()
        XCTAssertFalse(preview.commitPreview(stale))
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: first.channelID)
        let current = try XCTUnwrap(preview.pendingRequest)
        XCTAssertNotEqual(current, stale)
        XCTAssertTrue(preview.commitPreview(current))
    }

    func testReturnWithoutFocusRestorationIgnoresHiddenFullscreenFocusThenAllowsNewFocus() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let watched = model.channels[0].id
        let other = model.channels[1].id
        preview.watch(watched)
        preview.focus(other)
        preview.returnToGuide(restoresFocus: false)
        XCTAssertFalse(preview.isRestoringGuideFocus)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.focus(other)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
    }

    func testInactiveRestorationCannotPreviewUntilBrowsingResumesAndOldWorkStaysCancelled() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.returnToGuide()
        preview.setBrowsingActive(false)
        let focused = model.channels[1].id
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: focused)
        XCTAssertNil(preview.pendingRequest)
        preview.setBrowsingActive(true)
        let stale = try XCTUnwrap(preview.pendingRequest)
        preview.setBrowsingActive(false)
        XCTAssertFalse(preview.commitPreview(stale))
        preview.setBrowsingActive(true)
        let current = try XCTUnwrap(preview.pendingRequest)
        XCTAssertNotEqual(current, stale)
        XCTAssertTrue(preview.commitPreview(current))
    }

    func testReturningToBackgroundCannotPreviewBeforeTheWatchedOccurrenceIsRestored() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let watched = model.channels[0].id
        let next = model.channels[1].id
        preview.watch(watched)
        preview.setBrowsingActive(false)
        preview.returnToGuide()
        preview.focus(next)
        preview.setBrowsingActive(true)
        XCTAssertTrue(preview.isRestoringGuideFocus)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertEqual(model.playingChannelID, watched)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        XCTAssertNil(preview.pendingRequest)
        preview.focus(next)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
    }

    func testStopAndPlaybackEndCancelRestorationAndResetOnlyTheSessionHold() throws {
        for endsNaturally in [false, true] {
            let model = LiveTVPrototypeModel()
            let preview = LiveTVPreviewController(model: model, keepWatchingWhileBrowsing: true)
            preview.watch(model.channels[0].id)
            preview.returnToGuide()
            let stale = preview.focusRestoreRequest
            if endsNaturally {
                model.stop()
                preview.playbackEnded()
            } else {
                preview.stop()
            }
            preview.completeGuideFocusRestore(stale, focusedChannelID: model.channels[2].id)
            XCTAssertNil(preview.pendingRequest)
            XCTAssertFalse(preview.isRestoringGuideFocus)
            XCTAssertNil(preview.watchOrigin)
            XCTAssertTrue(preview.followsFocus)
            XCTAssertTrue(preview.keepWatchingWhileBrowsing)
            XCTAssertFalse(preview.isHoldingWatchedChannel)
            preview.focus(model.channels[1].id)
            XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
            XCTAssertEqual(model.playingChannelID, model.channels[1].id)
        }
    }

    func testRestorationWithNoRemainingFocusDoesNotPreviewRememberedSelection() {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        preview.watch(model.channels[0].id)
        preview.returnToGuide()
        preview.focus(model.channels[1].id)
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: nil)
        XCTAssertNil(preview.pendingRequest)
        preview.setBrowsingActive(false)
        preview.setBrowsingActive(true)
        XCTAssertNil(preview.pendingRequest)
    }

    func testFailedWatchDoesNotActivateHoldWatchedPolicy() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model, keepWatchingWhileBrowsing: true)
        model.simulateTunerBusy = true
        preview.watch(model.channels[0].id)
        XCTAssertTrue(model.tuneFailed)
        XCTAssertFalse(preview.isExpanded)
        model.simulateTunerBusy = false
        preview.focus(model.channels[1].id)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
    }

    func testPreviewAndUnconfirmedWatchNeverWriteRecentsAndPostWatchPreviewKeepsConfirmedRecents() throws {
        let model = LiveTVPrototypeModel()
        let preview = LiveTVPreviewController(model: model)
        let watched = model.channels[0].id
        preview.focus(watched)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        preview.watch(watched)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        XCTAssertFalse(model.recordWatched(model.channels[1].id))
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        // The playback host calls this only after the selected stream's matching first frame.
        XCTAssertTrue(model.recordWatched(watched))
        preview.returnToGuide()
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: watched)
        preview.focus(model.channels[1].id)
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        XCTAssertEqual(model.recentChannelIDs, [watched])
    }
}

@MainActor
final class LiveTVGuideFocusTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReturnChoosesPlayingProgramRatherThanAnotherBrowsedChannel() throws {
        let model = try makeModel()
        model.tune("playing")
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "other"),
            .program(channelID: "playing", programID: "current")
        )
    }

    func testReturnFollowsProgramRolloverWhileWatching() throws {
        let model = try makeModel()
        model.tune("playing")
        model.synchronizeClock(to: now.addingTimeInterval(1_801))
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "playing"),
            .program(channelID: "playing", programID: "next")
        )
    }

    func testMissingGuideReturnsToThePlayingChannelContentRatherThanItsLogo() throws {
        let model = try makeModel()
        model.tune("other")
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "playing"),
            .channelContent("other")
        )
    }

    func testReturnHonorsFiltersAndHandlesAnEmptyGuide() throws {
        let model = try makeModel()
        model.tune("playing")
        model.query = "other"
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "playing"),
            .channelContent("other")
        )
        XCTAssertEqual(model.query, "other")
        model.query = "no matching channel"
        XCTAssertNil(LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "playing"))
    }

    func testDuplicateChannelAndProgrammeOccurrencesHaveDistinctFocusIDs() {
        let sections: [LiveTVGuideSection] = [.recent, .favorites, .channels]
        let channels = sections.map { LiveTVGuideFocusTarget.channel("same", section: $0) }
        let programs = sections.map {
            LiveTVGuideFocusTarget.program(channelID: "same", programID: "current", section: $0)
        }
        let content = sections.map { LiveTVGuideFocusTarget.channelContent("same", section: $0) }
        let gaps = sections.map { LiveTVGuideFocusTarget.channelContent("same", slotID: "gap:0", section: $0) }
        XCTAssertEqual(Set(channels + programs + content + gaps).count, 12)
        XCTAssertEqual(Set((channels + programs + content + gaps).map(\.rowID)).count, 3)
    }

    func testReturnStaysInEachOriginSectionAfterRecentPromotion() throws {
        let model = try makeModel()
        model.toggleFavorite("playing")
        model.tune("playing")
        model.recordWatched("playing")
        for section in [LiveTVGuideSection.channels, .favorites, .recent] {
            XCTAssertEqual(
                LiveTVGuideFocusTarget.returningToPlayback(
                    in: model, selectedChannelID: "other",
                    originRow: LiveTVGuideRowID(channelID: "playing", section: section)
                ),
                .program(channelID: "playing", programID: "current", section: section)
            )
        }
    }

    func testRemovedShortcutFallsBackToTheSameChannelInMainList() throws {
        let model = try makeModel()
        model.toggleFavorite("playing")
        model.tune("playing")
        model.recordWatched("playing")
        let origin = LiveTVGuideRowID(channelID: "playing", section: .favorites)
        model.toggleFavorite("playing")
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "other", originRow: origin),
            .program(channelID: "playing", programID: "current", section: .channels)
        )
        model.synchronizeClock(to: now.addingTimeInterval(1_801))
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: "other", originRow: origin),
            .program(channelID: "playing", programID: "next", section: .channels)
        )
    }

    func testMissingListingsKeepTheOriginOccurrenceAndFiltersStillApply() throws {
        let model = try makeModel()
        model.toggleFavorite("other")
        model.tune("other")
        model.recordWatched("other")
        let origin = LiveTVGuideRowID(channelID: "other", section: .favorites)
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: nil, originRow: origin),
            .channelContent("other", section: .favorites)
        )
        model.query = "playing"
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: nil, originRow: origin),
            .program(channelID: "playing", programID: "current")
        )
    }

    func testInitialContentTargetChoosesTheActiveShowAndKeepsLogoSeparate() throws {
        let model = try makeModel()
        let row = LiveTVGuideRowID(channelID: "playing", section: .channels)
        let target = LiveTVGuideFocusTarget.defaultContent(in: model, row: row, from: now)
        XCTAssertEqual(target, .program(channelID: "playing", programID: "current"))
        XCTAssertTrue(target.isAvailable(in: model, from: now))
        XCTAssertTrue(LiveTVGuideFocusTarget.channel("playing").isAvailable(in: model, from: now))
    }

    func testNoGuideContentTargetBecomesUnavailableWhenRealListingsArrive() throws {
        let model = try makeModel()
        let row = LiveTVGuideRowID(channelID: "other", section: .channels)
        let original = LiveTVGuideFocusTarget.defaultContent(in: model, row: row, from: now)
        XCTAssertEqual(original, .channelContent("other"))
        XCTAssertTrue(original.isAvailable(in: model, from: now))
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "arrived", channelID: "other", title: "New listing", subtitle: "",
                start: now, end: now.addingTimeInterval(1_800)
            )
        ])
        XCTAssertFalse(original.isAvailable(in: model, from: now))
        XCTAssertEqual(
            LiveTVGuideFocusTarget.defaultContent(in: model, row: row, from: now),
            .program(channelID: "other", programID: "arrived")
        )
    }

    func testPartialGuideFocusesTheCurrentGapWithoutInventingAProgramme() throws {
        let model = try makeModel()
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "future", channelID: "playing", title: "Later", subtitle: "",
                start: now.addingTimeInterval(900), end: now.addingTimeInterval(1_800)
            )
        ])
        let row = LiveTVGuideRowID(channelID: "playing", section: .channels)
        let slots = LiveTVGuideTimeline.slots(
            programs: model.programs(for: "playing", from: now, hours: 6),
            from: now, to: now.addingTimeInterval(21_600)
        )
        let gap = try XCTUnwrap(slots.first)
        let target = LiveTVGuideFocusTarget.defaultContent(in: model, row: row, from: now)
        XCTAssertEqual(target, .channelContent("playing", slotID: gap.id))
        XCTAssertTrue(target.isAvailable(in: model, from: now))
        XCTAssertNotEqual(target, .channelContent("playing"))
        XCTAssertNil(model.currentProgram(for: "playing"))
        XCTAssertNotEqual(slots.first?.id, slots.last?.id)
        XCTAssertFalse(
            LiveTVGuideFocusTarget.channelContent("playing", slotID: "missing").isAvailable(in: model, from: now)
        )
    }

    func testCompactContentFocusUsesOnlyItsVisibleGuideHorizon() throws {
        let model = try makeModel()
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "late", channelID: "playing", title: "Later", subtitle: "",
                start: now.addingTimeInterval(10_800), end: now.addingTimeInterval(12_600)
            )
        ])
        let row = LiveTVGuideRowID(channelID: "playing", section: .channels)
        let target = LiveTVGuideFocusTarget.defaultContent(in: model, row: row, from: now, hours: 2)
        XCTAssertEqual(target, .channelContent("playing"))
        XCTAssertTrue(target.isAvailable(in: model, from: now, hours: 2))
        XCTAssertFalse(target.isAvailable(in: model, from: now, hours: 6))
    }

    func testPlaybackReturnUsesNowEvenWhenTheOldGuideWasInTheFuture() throws {
        let model = try makeModel()
        model.tune("playing")
        XCTAssertEqual(
            LiveTVGuideFocusTarget.returningToPlayback(
                in: model, selectedChannelID: nil, from: now.addingTimeInterval(21_600)
            ),
            .program(channelID: "playing", programID: "current")
        )
    }

    func testHidingChoosesTheNextRowThenPreviousWithoutAnotherOccurrenceOfTheHiddenChannel() throws {
        let model = try makeModel()
        model.toggleFavorite("playing")
        let main = LiveTVGuideRowID(channelID: "playing", section: .channels)
        let favorite = LiveTVGuideRowID(channelID: "playing", section: .favorites)
        let other = LiveTVGuideRowID(channelID: "other", section: .channels)
        XCTAssertEqual(LiveTVGuideFocusTarget.rowAfterHiding(main, in: model.guideChannels), other)
        XCTAssertEqual(LiveTVGuideFocusTarget.rowAfterHiding(favorite, in: model.guideChannels), other)
        XCTAssertEqual(LiveTVGuideFocusTarget.rowAfterHiding(other, in: model.guideChannels), main)
        model.query = "playing"
        XCTAssertNil(LiveTVGuideFocusTarget.rowAfterHiding(main, in: model.guideChannels))
    }

    private func makeModel() throws -> LiveTVPrototypeModel {
        let channels = ["playing", "other"].enumerated().map { number, id in
            LiveTVPrototypeChannel(
                id: id, number: number, name: id, category: "News",
                symbol: "tv", accent: 0, source: .iptv, tagline: ""
            )
        }
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "current", channelID: "playing", title: "Current show", subtitle: "",
                start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800)
            ),
            LiveTVPrototypeProgram(
                id: "next", channelID: "playing", title: "Next show", subtitle: "",
                start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(3_600)
            )
        ])
        return model
    }
}
