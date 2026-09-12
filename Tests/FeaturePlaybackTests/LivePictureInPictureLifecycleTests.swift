import XCTest
@testable import FeaturePlayback

final class LivePictureInPictureLifecycleTests: XCTestCase {
    func testUnsupportedPresentationCannotBeginOrRetainPlayback() {
        var lifecycle = LivePictureInPictureLifecycle()
        XCTAssertFalse(lifecycle.beginStart(isPossible: false))
        XCTAssertFalse(lifecycle.continuesPlayback)
        XCTAssertFalse(lifecycle.didStart())
    }

    func testPendingStartAlreadyRetainsTheSession() {
        var lifecycle = LivePictureInPictureLifecycle()
        XCTAssertTrue(lifecycle.beginStart(isPossible: true))
        XCTAssertTrue(lifecycle.continuesPlayback)
        XCTAssertFalse(lifecycle.beginStart(isPossible: true))
        XCTAssertTrue(lifecycle.didStart())
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testFailedOrExpiredStartCannotBeRevivedByLateDidStart() {
        var lifecycle = LivePictureInPictureLifecycle()
        lifecycle.beginStart(isPossible: true)
        lifecycle.finish()
        XCTAssertFalse(lifecycle.didStart())
        XCTAssertFalse(lifecycle.continuesPlayback)
    }

    func testStopWhileStartingRetainsUntilFinalCallbackAndRejectsLateStart() {
        var lifecycle = LivePictureInPictureLifecycle()
        lifecycle.beginStart(isPossible: true)
        XCTAssertTrue(lifecycle.requestStop())
        XCTAssertTrue(lifecycle.continuesPlayback)
        XCTAssertFalse(lifecycle.didStart())
        lifecycle.finish()
        XCTAssertFalse(lifecycle.continuesPlayback)
    }

    func testHidingRetainsPresentationButAuthorizationDetachNeverDoes() {
        var lifecycle = LivePictureInPictureLifecycle()
        XCTAssertTrue(lifecycle.shouldDetach(preservingPresentation: true))
        lifecycle.beginStart(isPossible: true)
        XCTAssertFalse(lifecycle.shouldDetach(preservingPresentation: true))
        lifecycle.didStart()
        XCTAssertFalse(lifecycle.shouldDetach(preservingPresentation: true))
        XCTAssertTrue(lifecycle.shouldDetach(preservingPresentation: false))
        lifecycle.requestStop()
        XCTAssertFalse(lifecycle.shouldDetach(preservingPresentation: true))
        lifecycle.finish()
        XCTAssertTrue(lifecycle.shouldDetach(preservingPresentation: true))
    }

    func testAirPlayWithoutPiPKeepsControllerBoundOnlyForNonterminalDetach() {
        let lifecycle = LivePictureInPictureLifecycle()
        XCTAssertFalse(lifecycle.shouldDetach(preservingPresentation: true, externalPlaybackActive: true))
        XCTAssertTrue(lifecycle.shouldDetach(preservingPresentation: false, externalPlaybackActive: true))
        XCTAssertTrue(lifecycle.shouldDetach(preservingPresentation: true, externalPlaybackActive: false))
    }
}
