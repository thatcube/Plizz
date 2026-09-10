#if os(tvOS)
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class NativeFocusRegionObserverTests: XCTestCase {
    func testNativeSeasonButtonReportsEntryWithoutSwiftUIFocusState() {
        let (window, root, observer) = fixture()
        let hero = button(in: root, x: 80, y: 160)
        let season = button(in: root, x: 900, y: 285)
        let episode = button(in: root, x: 80, y: 460)
        var entered = 0
        observer.onFocusEntered = { entered += 1 }
        observer.isEnabled = true
        observer.reportFocus(hero)
        XCTAssertEqual(entered, 0)
        observer.reportFocus(season)
        XCTAssertEqual(entered, 1)
        observer.reportFocus(season)
        XCTAssertEqual(entered, 1)
        observer.reportFocus(episode)
        observer.reportFocus(season)
        XCTAssertEqual(entered, 2)
        observer.stop()
        withExtendedLifetime(window) {}
    }

    func testVirtualSwiftUIFocusUsesTheContainingCoordinateSpace() {
        let (window, root, observer) = fixture()
        let season = RegionVirtualFocusItem(
            parent: root, frame: CGRect(x: 900, y: 285, width: 160, height: 50)
        )
        let hero = RegionVirtualFocusItem(
            parent: root, frame: CGRect(x: 80, y: 160, width: 160, height: 50)
        )
        XCTAssertTrue(observer.containsFocus(season))
        XCTAssertFalse(observer.containsFocus(hero))
        withExtendedLifetime(window) {}
    }

    func testMovingTheBrowserDoesNotLoseItsFocusedSeason() {
        let (window, root, observer) = fixture()
        let season = button(in: root, x: 80, y: 285)
        for offset in [CGFloat(0), 588, 110] {
            root.transform = CGAffineTransform(translationX: 0, y: offset)
            XCTAssertTrue(observer.containsFocus(season))
        }
        withExtendedLifetime(window) {}
    }

    func testDisabledDetachedAndOtherWindowTargetsDoNotTriggerEntry() {
        let (window, root, observer) = fixture()
        let season = button(in: root, x: 80, y: 285)
        season.isEnabled = false
        XCTAssertFalse(observer.containsFocus(season))
        XCTAssertFalse(observer.containsFocus(nil))
        let other = UIWindow(frame: window.frame)
        let otherSeason = button(in: other, x: 80, y: 285)
        XCTAssertFalse(observer.containsFocus(otherSeason))
        season.isEnabled = true
        observer.removeFromSuperview()
        XCTAssertFalse(observer.containsFocus(season))
        withExtendedLifetime((window, other)) {}
    }

    func testOverlappingPresentationOutsideThePageDoesNotRecedeIt() {
        let (window, _, observer) = fixture()
        let overlayButton = button(in: window, x: 80, y: 285)
        XCTAssertFalse(observer.containsFocus(overlayButton))
        let overlayVirtual = RegionVirtualFocusItem(parent: window, frame: overlayButton.frame)
        XCTAssertFalse(observer.containsFocus(overlayVirtual))
    }

    func testStoppingObservationPreventsFurtherCallbacks() {
        let (window, root, observer) = fixture()
        let season = button(in: root, x: 80, y: 285)
        var entered = 0
        observer.onFocusEntered = { entered += 1 }
        observer.isEnabled = true
        observer.reportFocus(season)
        observer.stop()
        observer.reportFocus(nil)
        observer.reportFocus(season)
        XCTAssertEqual(entered, 1)
        withExtendedLifetime(window) {}
    }

    private func fixture() -> (UIWindow, UIView, NativeFocusRegionObserver.ObserverView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        let observer = NativeFocusRegionObserver.ObserverView(
            frame: CGRect(x: 0, y: 272, width: 1920, height: 88)
        )
        root.addSubview(observer)
        return (window, root, observer)
    }

    private func button(in parent: UIView, x: CGFloat, y: CGFloat) -> UIButton {
        let button = UIButton(frame: CGRect(x: x, y: y, width: 160, height: 50))
        parent.addSubview(button)
        return button
    }
}

@MainActor
private final class RegionVirtualFocusItem: NSObject, UIFocusItem {
    let frame: CGRect
    weak var parentFocusEnvironment: (any UIFocusEnvironment)?
    var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
    var focusItemContainer: (any UIFocusItemContainer)? { nil }
    var canBecomeFocused: Bool { true }

    init(parent: any UIFocusEnvironment, frame: CGRect) {
        self.parentFocusEnvironment = parent
        self.frame = frame
    }

    func setNeedsFocusUpdate() {}
    func updateFocusIfNeeded() {}
    func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }
    func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {}
}
#endif
