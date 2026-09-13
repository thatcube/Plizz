@testable import AppShell
@testable import CoreUI
import UIKit
import XCTest

@MainActor
final class PinnedReturnInputHostedTests: XCTestCase {
    func testBlockedLeftCannotOpenRailAfterVisualReturnFinishes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        fixture.observer.checkFocusAfterInput(before: fixture.controller.contentButton, wasInRail: false)
        guardView.releaseWhenIdle()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 0)
        XCTAssertTrue(fixture.controller.contentButton.isFocused)

        fixture.observer.checkFocusAfterInput(before: fixture.controller.contentButton, wasInRail: false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 1, "A fresh Left after return must still open pinned navigation.")
        XCTAssertTrue(fixture.controller.navigationButton.isFocused)
    }

    func testTransitionInvalidatesAnAlreadyQueuedBoundaryCheck() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.observer.checkFocusAfterInput(before: fixture.controller.contentButton, wasInRail: false)
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        guardView.releaseWhenIdle()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 0)
    }

    func testHeldArrowRemainsConsumedUntilRelease() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        let press = TestPress(.leftArrow)
        let event = UIPressesEvent()
        guardView.pressesBegan([press], with: event)
        fixture.observer.pressesBegan([press], with: event)
        guardView.releaseWhenIdle()
        XCTAssertTrue(guardView.view === fixture.window)
        XCTAssertNil(DetailTransitionNavigation.navigationInputEpoch(in: fixture.window))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 0)

        guardView.pressesEnded([press], with: event)
        XCTAssertTrue(guardView.view === fixture.window, "Observers of the same release event must still see suppression.")
        fixture.observer.checkFocusAfterInput(before: fixture.controller.contentButton, wasInRail: false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(guardView.view)
        XCTAssertNotNil(DetailTransitionNavigation.navigationInputEpoch(in: fixture.window))
        XCTAssertEqual(fixture.openCount, 0)
    }

    func testSwipeBeginningDuringReturnCannotOpenNavigationAfterRelease() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        let swipe = NavigationRailEdgeCatcher.BoundarySwipeRecognizer()
        fixture.window.addGestureRecognizer(swipe)
        swipe.onSwipe = { [weak observer = fixture.observer] before, wasInRail, epoch in
            observer?.checkFocusAfterInput(before: before, wasInRail: wasInRail, inputEpoch: epoch)
        }
        let touch = TestTouch()
        let event = UIEvent()
        guardView.touchesBegan([touch], with: event)
        swipe.touchesBegan([touch], with: event)
        touch.point = CGPoint(x: 300, y: 100)
        swipe.touchesMoved([touch], with: event)
        touch.point = CGPoint(x: 100, y: 100)
        swipe.touchesMoved([touch], with: event)
        guardView.releaseWhenIdle()
        guardView.touchesEnded([touch], with: event)
        swipe.touchesEnded([touch], with: event)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 0)
        XCTAssertNil(guardView.view)

        let fresh = TestTouch()
        swipe.touchesBegan([fresh], with: event)
        fresh.point = CGPoint(x: 300, y: 100)
        swipe.touchesMoved([fresh], with: event)
        fresh.point = CGPoint(x: 100, y: 100)
        swipe.touchesMoved([fresh], with: event)
        swipe.touchesEnded([fresh], with: event)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.openCount, 1)
    }

    func testSwipeCannotCrossACompletedTransitionEpoch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let swipe = NavigationRailEdgeCatcher.BoundarySwipeRecognizer()
        fixture.window.addGestureRecognizer(swipe)
        var callbacks = 0
        swipe.onSwipe = { _, _, _ in callbacks += 1 }
        let touch = TestTouch()
        let event = UIEvent()
        swipe.touchesBegan([touch], with: event)
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        guardView.releaseWhenIdle()
        touch.point = CGPoint(x: 300, y: 100)
        swipe.touchesMoved([touch], with: event)
        touch.point = CGPoint(x: 100, y: 100)
        swipe.touchesMoved([touch], with: event)
        swipe.touchesEnded([touch], with: event)
        XCTAssertEqual(callbacks, 0)
    }

    func testMixedInputDrainsOnlyAfterBothPressAndTouchEnd() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        let press = TestPress(.downArrow)
        let touch = TestTouch()
        guardView.pressesBegan([press], with: UIPressesEvent())
        guardView.touchesBegan([touch], with: UIEvent())
        guardView.releaseWhenIdle()
        guardView.pressesEnded([press], with: UIPressesEvent())
        await Task.yield()
        XCTAssertTrue(guardView.view === fixture.window)
        guardView.touchesCancelled([touch], with: UIEvent())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(guardView.view)
    }

    func testBackIsNotCapturedAndForceTeardownDoesNotWaitForInput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        let back = TestPress(.menu)
        guardView.pressesBegan([back], with: UIPressesEvent())
        guardView.pressesEnded([back], with: UIPressesEvent())
        XCTAssertEqual(guardView.state, .possible)
        guardView.pressesBegan([TestPress(.leftArrow)], with: UIPressesEvent())
        guardView.invalidate()
        XCTAssertNil(guardView.view)
    }

    func testHeroNavigationRequestsRespectTheSameWindowGate() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let interaction = PlozzPinnedSidebarInteraction()
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        interaction.requestOpen()
        XCTAssertEqual(interaction.openRequest, 0)
        guardView.releaseWhenIdle()
        interaction.requestOpen()
        XCTAssertEqual(interaction.openRequest, 1)
    }

    func testLeavingTheAppCannotLeaveAWaitingGuardInstalled() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        guardView.pressesBegan([TestPress(.leftArrow)], with: UIPressesEvent())
        guardView.releaseWhenIdle()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(guardView.view)
    }

    private func makeFixture() async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        while !fixture.controller.contentButton.isFocused, ContinuousClock.now < deadline {
            fixture.window.rootViewController?.setNeedsFocusUpdate()
            fixture.window.rootViewController?.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(fixture.controller.contentButton.isFocused)
        return fixture
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let controller = Controller()
        let observer = NavigationRailEdgeCatcher.LeftPressRecognizer()
        var openCount = 0

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
            window.addGestureRecognizer(observer)
            observer.onOpenNavigation = { [weak self] in
                guard let self else { return }
                openCount += 1
                controller.prefersNavigation = true
                let system = UIFocusSystem.focusSystem(for: window)
                system?.requestFocusUpdate(to: controller)
                system?.updateFocusIfNeeded()
            }
        }

        func close() {
            for recognizer in window.gestureRecognizers ?? [] {
                if let guardView = recognizer as? DetailTransitionInputGuard { guardView.invalidate() }
            }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    private final class Controller: UIViewController {
        let contentButton = UIButton(type: .system)
        let navigationButton = UIButton(type: .system)
        var prefersNavigation = false
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [prefersNavigation ? navigationButton : contentButton]
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            contentButton.setTitle("Selected content", for: .normal)
            contentButton.frame = CGRect(x: 800, y: 450, width: 360, height: 100)
            navigationButton.setTitle("Navigation", for: .normal)
            navigationButton.frame = CGRect(x: 80, y: 450, width: 320, height: 100)
            view.addSubview(contentButton)
            view.addSubview(navigationButton)
        }
    }
}

private final class TestPress: UIPress {
    private let pressedType: UIPress.PressType
    init(_ type: UIPress.PressType) {
        pressedType = type
        super.init()
    }
    override var type: UIPress.PressType { pressedType }
}

private final class TestTouch: UITouch {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}
