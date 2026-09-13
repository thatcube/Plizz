#if os(tvOS)
import SwiftUI
import UIKit
import FeatureHome
import CoreUI

/// Resolves a directional press that had nowhere else to go: Left opens the
/// navigation rail, Right returns focus to the page.
///
/// ### Why this is not a focusable view
/// Left must reach the navigation from anywhere on the page, and no amount of
/// geometry achieves that. The page's grids and rails are `.focusSection()`s, and
/// so is the rail; moving Left off a poster therefore asks the focus engine to
/// leave one section and enter another, which it frequently declines. That is why
/// Left worked from a page header (whose section has nothing to its left, forcing
/// a clean exit) and did nothing from the grid below it — and why adding a
/// full-height focusable target down the leading edge changed nothing: the target
/// was always there and focusable, the engine simply never moved to it.
///
/// ### What this does instead
/// Passive recognizers observe arrow presses and touchpad swipes. Neither consumes
/// input, so existing Left behaviour is untouched — stepping between hero
/// buttons, paging the carousel, moving along a row. It then checks whether focus
/// actually moved. Only when it did NOT — a Left that went nowhere — does the
/// rail claim focus.
///
/// The same is true leaving the rail. Right out of a rail row only reached the
/// page when something happened to sit level with it — the hero's buttons are far
/// down the screen, so Right from Home or Search did nothing at all. A Right that
/// resolves to nothing hands focus back to the page instead.
///
/// This is deliberately a *fallback* rather than an interception: neither
/// direction can steal a press that had a real use, and a press that dead ends
/// anywhere in the app still does the obvious thing.
struct NavigationRailEdgeCatcher: UIViewRepresentable {
    /// Called when a Left press resolved to nothing, so the rail should take focus.
    var onOpenNavigation: () -> Void
    /// Called when a Right press inside the rail resolved to nothing, so focus
    /// should return to the page.
    var onLeaveNavigation: () -> Void
    /// Whether the rail currently holds focus. Decides which direction is the
    /// meaningful one: Left into the rail, or Right back out of it.
    var railHasFocus: Bool
    /// Whether the catcher is listening at all — false while the rail is hidden
    /// (a detail page).
    var isEnabled: Bool

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.recognizer.onOpenNavigation = onOpenNavigation
        view.recognizer.onLeaveNavigation = onLeaveNavigation
        view.recognizer.railHasFocus = railHasFocus
        view.recognizer.isEnabled = isEnabled
        view.swipeRecognizer.isEnabled = isEnabled
        view.swipeRecognizer.railHasFocus = railHasFocus
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        if uiView.recognizer.isEnabled != isEnabled || uiView.recognizer.railHasFocus != railHasFocus {
            HeroFocusDiagnostics.emit("sidebar observer enabled=\(isEnabled) rail=\(railHasFocus)")
        }
        uiView.recognizer.onOpenNavigation = onOpenNavigation
        uiView.recognizer.onLeaveNavigation = onLeaveNavigation
        uiView.recognizer.railHasFocus = railHasFocus
        uiView.recognizer.isEnabled = isEnabled
        uiView.swipeRecognizer.isEnabled = isEnabled
        uiView.swipeRecognizer.railHasFocus = railHasFocus
    }

    /// Hosts the recognizer on the window.
    ///
    /// The recognizer has to live on the window, not on this view: a press is
    /// delivered to the focused element's responder chain, which a zero-size view
    /// off to one side is never part of.
    final class InstallerView: UIView {
        let recognizer = LeftPressRecognizer()
        let swipeRecognizer = BoundarySwipeRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            swipeRecognizer.onSwipe = { [weak recognizer] before, wasInRail, epoch in
                recognizer?.checkFocusAfterInput(before: before, wasInRail: wasInRail, inputEpoch: epoch)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard recognizer.view !== window else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            swipeRecognizer.view?.removeGestureRecognizer(swipeRecognizer)
            window?.addGestureRecognizer(recognizer)
            window?.addGestureRecognizer(swipeRecognizer)
        }

        deinit {
            MainActor.assumeIsolated {
                recognizer.view?.removeGestureRecognizer(recognizer)
                swipeRecognizer.view?.removeGestureRecognizer(swipeRecognizer)
            }
        }
    }

    final class BoundarySwipeRecognizer: UIGestureRecognizer {
        var onSwipe: ((UIFocusItem?, Bool, UInt64) -> Void)?
        var railHasFocus = false
        private var before: UIFocusItem?
        private var wasInRail = false
        private var allowsFallback = false
        private var travel = SwipeTravel()
        private var inputEpoch: UInt64?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            allowedPressTypes = []
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() { self.init(target: nil, action: nil) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            before = NavigationRailEdgeCatcher.focusedItem(in: view)
            wasInRail = railHasFocus
            inputEpoch = DetailTransitionNavigation.navigationInputEpoch(in: view)
            allowsFallback = inputEpoch != nil
                && (wasInRail || NavigationRailEdgeCatcher.permitsNavigationFallback(from: before))
            travel = SwipeTravel()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first else { return }
            let position = touch.location(in: view)
            travel.moved(to: position)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            HeroFocusDiagnostics.emit("sidebar touch ended travel=\(travel.translation) rail=\(wasInRail)")
            if allowsFallback, let inputEpoch,
               DetailTransitionNavigation.navigationInputEpoch(in: view) == inputEpoch,
               travel.direction == (wasInRail ? .right : .left) {
                onSwipe?(before, wasInRail, inputEpoch)
            }
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }

        override func reset() {
            super.reset()
            before = nil
            allowsFallback = false
            inputEpoch = nil
            travel = SwipeTravel()
        }

        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    }

    struct SwipeTravel {
        private var origin: CGPoint?
        private(set) var translation = CGPoint.zero

        mutating func moved(to point: CGPoint) {
            // Indirect touch-down can be in a different coordinate frame from
            // the movement samples inside a scrolling row. Anchor on movement.
            guard let origin else {
                self.origin = point
                return
            }
            translation = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        }

        var direction: UISwipeGestureRecognizer.Direction? {
            guard abs(translation.x) >= 40, abs(translation.x) > abs(translation.y) * 1.5 else { return nil }
            return translation.x < 0 ? .left : .right
        }
    }

    /// Observes directional presses and reports the ones that changed nothing.
    final class LeftPressRecognizer: UIGestureRecognizer {
        var onOpenNavigation: (() -> Void)?
        var onLeaveNavigation: (() -> Void)?
        var railHasFocus = false

        /// How long to wait before deciding a press went nowhere.
        ///
        /// This is dead time on the fallback path — the rail cannot open until it
        /// elapses — so it is kept as short as the check allows. A focus update
        /// completes within a frame or two (~16-33ms); 70ms is several frames of
        /// margin while staying under the threshold where a delay reads as lag.
        private static let settleDelay = Duration.milliseconds(70)

        private var pendingCheck: Task<Void, Never>?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedPressTypes = [
                NSNumber(value: UIPress.PressType.leftArrow.rawValue),
                NSNumber(value: UIPress.PressType.rightArrow.rawValue)
            ]
            allowedTouchTypes = []
            // Purely an observer: it must never swallow the press, delay it, or
            // interfere with the gestures that implement normal navigation.
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() {
            self.init(target: nil, action: nil)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            // Only the direction that would cross the rail boundary is watched:
            // Left while focus is on the page, Right while it is in the rail.
            let watched: UIPress.PressType = railHasFocus ? .rightArrow : .leftArrow
            guard isEnabled, presses.contains(where: { $0.type == watched }),
                  let epoch = DetailTransitionNavigation.navigationInputEpoch(in: view) else {
                super.pressesBegan(presses, with: event)
                return
            }

            let before = NavigationRailEdgeCatcher.focusedItem(in: view)
            let wasInRail = railHasFocus
            checkFocusAfterInput(before: before, wasInRail: wasInRail, inputEpoch: epoch)

            // Never recognise: the press belongs to whatever the page does with it.
            state = .failed
            super.pressesBegan(presses, with: event)
        }

        func checkFocusAfterInput(before: UIFocusItem?, wasInRail: Bool, inputEpoch: UInt64? = nil) {
            guard let before, let inputView = view,
                  let epoch = inputEpoch ?? DetailTransitionNavigation.navigationInputEpoch(in: view),
                  DetailTransitionNavigation.navigationInputEpoch(in: view) == epoch else { return }
            guard wasInRail || NavigationRailEdgeCatcher.permitsNavigationFallback(from: before) else { return }
            pendingCheck?.cancel()
            pendingCheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, let self, self.isEnabled,
                      self.view === inputView,
                      self.railHasFocus == wasInRail,
                      DetailTransitionNavigation.navigationInputEpoch(in: self.view) == epoch else { return }
                // Focus moved, so the press had a genuine use and neither the
                // navigation nor the page needs to intervene.
                guard NavigationRailEdgeCatcher.focusedItem(in: self.view) === before else { return }
                guard wasInRail || NavigationRailEdgeCatcher.permitsNavigationFallback(from: before) else { return }
                HeroFocusDiagnostics.emit("sidebar fallback \(wasInRail ? "leave" : "open")")
                if wasInRail {
                    self.onLeaveNavigation?()
                } else {
                    self.onOpenNavigation?()
                }
            }
        }

        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    }

    /// Cursor movement does not change UIKit focus. Only offer navigation when
    /// a text input was already at its leading edge, with no selected text.
    static func permitsNavigationFallback(from item: UIFocusItem?) -> Bool {
        guard let item else { return false }
        var view = item as? UIView
        while let current = view {
            if let input = current as? any UITextInput {
                guard let selection = input.selectedTextRange else { return false }
                return selection.isEmpty
                    && input.compare(selection.start, to: input.beginningOfDocument) == .orderedSame
            }
            view = current.superview
        }
        return true
    }

    private static func focusedItem(in view: UIView?) -> UIFocusItem? {
        guard let window = (view as? UIWindow) ?? view?.window else { return nil }
        return UIFocusSystem(for: window)?.focusedItem
    }
}
#endif
