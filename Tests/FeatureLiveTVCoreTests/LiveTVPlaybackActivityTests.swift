import XCTest
@testable import FeatureLiveTVCore

final class LiveTVPlaybackActivityTests: XCTestCase {
    func testExternalPlaybackDoesNotOverrideAuthorizationOrNetworkPolicy() {
        for authorized in [false, true] {
            for network in [false, true] {
                let activity = LiveTVPlaybackActivity(
                    isDestinationActive: false, isSceneActive: false, isInBackground: true,
                    isAuthorized: authorized, allowsPlayback: network,
                    hasAuthorizedExternalPresentation: true
                )
                XCTAssertEqual(activity.isPlaybackActive, authorized && network)
                XCTAssertFalse(activity.acceptsInteraction)
                XCTAssertEqual(
                    activity.countsAsWatching(
                        isUserRequested: true, isPictureVisible: false, isExternallyPresented: true
                    ),
                    authorized && network
                )
            }
        }
    }

    func testOrdinaryHiddenOrBackgroundPlaybackStops() {
        for destination in [false, true] {
            for background in [false, true] {
                let activity = LiveTVPlaybackActivity(
                    isDestinationActive: destination, isSceneActive: !background,
                    isInBackground: background, isAuthorized: true, allowsPlayback: true,
                    hasAuthorizedExternalPresentation: false
                )
                XCTAssertEqual(activity.isPlaybackActive, destination && !background)
                XCTAssertEqual(activity.acceptsInteraction, destination && !background)
            }
        }
    }

    func testTransientInactivityKeepsSessionButBlocksNewInteraction() {
        let activity = LiveTVPlaybackActivity(
            isDestinationActive: true, isSceneActive: false, isInBackground: false,
            isAuthorized: true, allowsPlayback: true, hasAuthorizedExternalPresentation: false
        )
        XCTAssertTrue(activity.isPlaybackActive)
        XCTAssertFalse(activity.acceptsInteraction)
        XCTAssertFalse(activity.countsAsWatching(
            isUserRequested: true, isPictureVisible: true, isExternallyPresented: false
        ))
    }

    func testPreviewAndOccludedPicturesDoNotCountAsWatching() {
        let activity = LiveTVPlaybackActivity(
            isDestinationActive: true, isSceneActive: true, isInBackground: false,
            isAuthorized: true, allowsPlayback: true, hasAuthorizedExternalPresentation: false
        )
        for requested in [false, true] {
            for visible in [false, true] {
                XCTAssertEqual(
                    activity.countsAsWatching(
                        isUserRequested: requested, isPictureVisible: visible, isExternallyPresented: false
                    ),
                    requested && visible
                )
            }
        }
    }
}
