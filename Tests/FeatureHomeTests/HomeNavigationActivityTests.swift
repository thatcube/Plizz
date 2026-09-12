#if canImport(SwiftUI)
import Observation
import XCTest
@testable import FeatureHome

@MainActor
final class HomeNavigationActivityTests: XCTestCase {
    func testIdleGraceStartsAtCreationAndIncludesItsBoundary() {
        let start = ContinuousClock.now
        let activity = HomeNavigationActivity(now: start)

        XCTAssertFalse(activity.isIdle(for: .seconds(30), at: start))
        XCTAssertFalse(activity.isIdle(for: .seconds(30), at: start + .seconds(29)))
        XCTAssertTrue(activity.isIdle(for: .seconds(30), at: start + .seconds(30)))
    }

    func testEveryRemoteRepeatDelaysRefreshWithoutReplacingTheClock() {
        let start = ContinuousClock.now
        let activity = HomeNavigationActivity(now: start)
        let refreshObserverClock = activity

        for second in 1...100 {
            activity.recordInteraction(at: start + .seconds(second))
            XCTAssertFalse(refreshObserverClock.isIdle(
                for: .seconds(30), at: start + .seconds(second + 29)
            ))
        }
        XCTAssertTrue(refreshObserverClock.isIdle(
            for: .seconds(30), at: start + .seconds(130)
        ))
    }

    func testMovementDoesNotPublishAnObservationChange() async {
        let start = ContinuousClock.now
        let activity = HomeNavigationActivity(now: start)
        let invalidation = expectation(description: "Navigation must not invalidate a view")
        invalidation.isInverted = true
        withObservationTracking {
            _ = activity.isIdle(for: .seconds(30), at: start)
        } onChange: {
            invalidation.fulfill()
        }

        activity.recordInteraction(at: start + .seconds(10))

        XCTAssertFalse(activity.isIdle(for: .seconds(30), at: start + .seconds(30)))
        await fulfillment(of: [invalidation], timeout: 0.05)
    }

    func testSeparateHomeInstancesDoNotShareActivity() {
        let start = ContinuousClock.now
        let first = HomeNavigationActivity(now: start)
        let second = HomeNavigationActivity(now: start)

        first.recordInteraction(at: start + .seconds(25))

        XCTAssertFalse(first.isIdle(for: .seconds(30), at: start + .seconds(30)))
        XCTAssertTrue(second.isIdle(for: .seconds(30), at: start + .seconds(30)))
    }
}
#endif
