import XCTest
@testable import CoreUI

final class PlaybackControlsInactivityTests: XCTestCase {
    func testNoInputRetainsTheExistingFourSecondGrace() {
        let inactivity = PlaybackControlsInactivity()
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 10), 4)
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 13), 1)
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 14), 0)
    }

    func testNativeMovementExtendsAlreadyRunningFullscreenCountdown() {
        var inactivity = PlaybackControlsInactivity()
        inactivity.recordInteraction(at: 5.23)
        inactivity.recordInteraction(at: 5.65)
        XCTAssertEqual(
            inactivity.remainingDelay(startedAt: 1.8, now: 5.89),
            3.76,
            accuracy: 0.001
        )
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 1.8, now: 9.65), 0, accuracy: 0.001)
    }

    func testMovementAtRowBoundaryAlsoRenewsGraceWithoutFocusChanging() {
        var inactivity = PlaybackControlsInactivity()
        inactivity.recordInteraction(at: 13)
        inactivity.recordInteraction(at: 16)
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 17), 3)
    }

    func testLateOlderActivityCannotShortenCurrentDeadline() {
        var inactivity = PlaybackControlsInactivity()
        inactivity.recordInteraction(at: 20)
        inactivity.recordInteraction(at: 19)
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 21), 3)
    }

    func testCallerCanUseALongerReadingGraceWithoutChangingTheSharedDefault() {
        let inactivity = PlaybackControlsInactivity()
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 14), 0)
        XCTAssertEqual(inactivity.remainingDelay(startedAt: 10, now: 14, grace: 9), 5)
    }
}

#if DEBUG && os(tvOS)
import UIKit

@MainActor
final class TVFocusActivityObserverTests: XCTestCase {
    func testNativeFocusAndDirectionalPressesRefreshOnlyThisHUDWithoutConsumingInput() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let observer = TVFocusActivityObserver.ObserverView(
            frame: CGRect(x: 100, y: 100, width: 300, height: 100)
        )
        let control = FocusItem(frame: CGRect(x: 140, y: 120, width: 60, height: 44))
        let outside = FocusItem(frame: CGRect(x: 440, y: 120, width: 60, height: 44))
        window.addSubview(observer)
        window.addSubview(control)
        window.addSubview(outside)
        defer { observer.stop() }
        var events = 0
        var frames: [CGRect] = []
        observer.onActivity = { events += 1 }
        observer.onFocusedFrame = { frames.append($0) }

        observer.reportActivity(for: control)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(frames, [CGRect(x: 40, y: 20, width: 60, height: 44)])
        XCTAssertFalse(observer.observePress(.rightArrow, focusedItem: control))
        XCTAssertFalse(observer.observePress(.rightArrow, focusedItem: control))
        XCTAssertEqual(events, 3)
        XCTAssertFalse(observer.observePress(.select, focusedItem: control))
        XCTAssertFalse(observer.observePress(.playPause, focusedItem: control))
        XCTAssertEqual(events, 3)
        observer.reportActivity(for: outside)
        XCTAssertFalse(observer.observePress(.leftArrow, focusedItem: outside))
        XCTAssertEqual(events, 3)
    }

    func testOtherWindowsAndDetachedHUDCannotReportActivity() {
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let secondWindow = UIWindow(frame: firstWindow.frame)
        let observer = TVFocusActivityObserver.ObserverView(frame: firstWindow.bounds)
        let otherControl = FocusItem(frame: CGRect(x: 10, y: 10, width: 80, height: 44))
        firstWindow.addSubview(observer)
        secondWindow.addSubview(otherControl)
        var events = 0
        observer.onActivity = { events += 1 }
        observer.reportActivity(for: otherControl)
        XCTAssertEqual(events, 0)
        observer.removeFromSuperview()
        observer.reportActivity(for: otherControl)
        XCTAssertEqual(events, 0)
        XCTAssertFalse(firstWindow.gestureRecognizers?.contains { $0.delegate === observer } ?? false)
    }

    func testPlaybackPressObservationIsOptInAndNeverConsumesSelectOrPlayPause() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let observer = TVFocusActivityObserver.ObserverView(frame: window.bounds)
        let control = FocusItem(frame: CGRect(x: 40, y: 40, width: 100, height: 100))
        window.addSubview(observer)
        window.addSubview(control)
        defer { observer.stop() }
        var events = 0
        observer.onActivity = { events += 1 }
        observer.observesPlaybackPresses = true
        let recognizer = try XCTUnwrap(window.gestureRecognizers?.first { $0.delegate === observer })
        let select = NSNumber(value: UIPress.PressType.select.rawValue)
        XCTAssertTrue(recognizer.allowedPressTypes.contains(select))
        XCTAssertFalse(observer.observePress(.select, focusedItem: control))
        XCTAssertFalse(observer.observePress(.playPause, focusedItem: control))
        XCTAssertEqual(events, 2)
        XCTAssertFalse(observer.observePress(.menu, focusedItem: control))
        XCTAssertEqual(events, 2)
        observer.observesPlaybackPresses = false
        XCTAssertFalse(recognizer.allowedPressTypes.contains(select))
        XCTAssertFalse(observer.observePress(.select, focusedItem: control))
        XCTAssertEqual(events, 2)
    }

    func testStopRemovesOwnedPressObserverAndDoesNotChangeExistingRecognizers() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let existing = UITapGestureRecognizer()
        window.addGestureRecognizer(existing)
        let observer = TVFocusActivityObserver.ObserverView(frame: window.bounds)
        window.addSubview(observer)
        XCTAssertTrue(window.gestureRecognizers?.contains { $0.delegate === observer } ?? false)
        observer.stop()
        XCTAssertFalse(window.gestureRecognizers?.contains { $0.delegate === observer } ?? false)
        XCTAssertTrue(window.gestureRecognizers?.contains { $0 === existing } ?? false)
    }

    func testVirtualSwiftUIFocusItemsUseTheirHostingViewsCoordinates() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIView(frame: CGRect(x: 120, y: 80, width: 300, height: 180))
        let observer = TVFocusActivityObserver.ObserverView(
            frame: CGRect(x: 100, y: 60, width: 320, height: 200))
        window.addSubview(host)
        window.addSubview(observer)
        defer { observer.stop() }
        let item = VirtualFocusItem(
            frame: CGRect(x: 20, y: 30, width: 50, height: 40), parent: host)
        var frames: [CGRect] = []
        observer.onFocusedFrame = { frames.append($0) }
        observer.reportActivity(for: item)
        XCTAssertEqual(frames, [CGRect(x: 40, y: 50, width: 50, height: 40)])
        let otherWindow = UIWindow(frame: window.frame)
        otherWindow.addSubview(host)
        observer.reportActivity(for: item)
        XCTAssertEqual(frames.count, 1, "Virtual focus in a different window must remain excluded")
    }

    private final class VirtualFocusItem: NSObject, UIFocusItem {
        let frame: CGRect
        weak var parentFocusEnvironment: (any UIFocusEnvironment)?
        var canBecomeFocused: Bool { true }
        var focusItemContainer: (any UIFocusItemContainer)? { nil }
        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }

        init(frame: CGRect, parent: any UIFocusEnvironment) {
            self.frame = frame
            self.parentFocusEnvironment = parent
        }

        func setNeedsFocusUpdate() {}
        func updateFocusIfNeeded() {}
        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }
        func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {}
    }

    private final class FocusItem: UIView {
        override var canBecomeFocused: Bool { true }
    }
}
#endif
