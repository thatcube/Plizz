import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI

final class MediaRowEpisodeEntryPolicyTests: XCTestCase {
    func testLoadedDataDoesNotRetireThePlaceholderUntilTheTargetIsOnScreen() {
        let id = "episode-998"
        let offscreen = MediaRowEntryLayout(
            target: .init(id: id, frame: CGRect(x: 4000, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady(id, layout: offscreen))
        XCTAssertTrue(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: false, focusEngaged: false
        ))
        let onscreen = MediaRowEntryLayout(
            target: .init(id: id, frame: CGRect(x: 100, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )
        XCTAssertTrue(MediaRowEpisodeEntryPolicy.targetReady(id, layout: onscreen))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: true, focusEngaged: false
        ))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("other-season", layout: onscreen))
    }

    func testUnknownGeometryNeverCountsAsARealizedTarget() {
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init()))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init(
            target: .init(id: "episode", frame: .zero), viewportWidth: 1920
        )))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init(
            target: .init(id: "episode", frame: CGRect(x: -250, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )))
    }

    func testBrowsingDoesNotResurrectAnEntryGateDuringLazyRecycling() {
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: false, focusEngaged: true
        ))
    }

    func testFirstEntryUsesResumeAndLaterEntryRemembersTheBrowsedEpisode() {
        let ids = Set((0..<1000).map { "episode-\($0)" })
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: nil, defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-998")
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: "episode-650", defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-650")
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: "other-season", defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-998")
        XCTAssertNil(MediaRowEpisodeEntryPolicy.target(
            rememberedID: nil, defaultID: "not-loaded-yet", itemIDs: ids, firstID: "episode-0"
        ))
    }

    func testLoadingEmptyAndFailedStatesKeepAnHonestFocusableDestination() {
        for phase in [MediaRowEpisodeEntry.Phase.loading, .empty, .failed] {
            XCTAssertTrue(MediaRowEpisodeEntryPolicy.showsPlaceholder(
                phase: phase, targetReady: false, focusEngaged: false
            ))
        }
    }
}
