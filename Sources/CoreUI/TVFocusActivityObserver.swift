#if DEBUG && os(tvOS)
import SwiftUI
import UIKit

/// Observes the presented HUD's native input without changing focus or consuming presses.
public struct TVFocusActivityObserver: UIViewRepresentable {
    let onActivity: () -> Void
    let observesPlaybackPresses: Bool
    let onFocusedFrame: ((CGRect) -> Void)?

    public init(
        onActivity: @escaping () -> Void,
        observesPlaybackPresses: Bool = false,
        onFocusedFrame: ((CGRect) -> Void)? = nil
    ) {
        self.onActivity = onActivity
        self.observesPlaybackPresses = observesPlaybackPresses
        self.onFocusedFrame = onFocusedFrame
    }

    public func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onActivity = onActivity
        view.onFocusedFrame = onFocusedFrame
        view.observesPlaybackPresses = observesPlaybackPresses
        return view
    }

    public func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onActivity = onActivity
        uiView.onFocusedFrame = onFocusedFrame
        uiView.observesPlaybackPresses = observesPlaybackPresses
    }

    public static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) {
        uiView.stop()
    }

    public final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var onActivity: (() -> Void)?
        var onFocusedFrame: ((CGRect) -> Void)?
        var observesPlaybackPresses = false {
            didSet {
                guard oldValue != observesPlaybackPresses else { return }
                pressObserver?.allowedPressTypes = allowedPressTypes
            }
        }
        private weak var observedWindow: UIWindow?
        private var pressObserver: UITapGestureRecognizer?

        private var allowedPressTypes: [NSNumber] {
            var types: [UIPress.PressType] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
            if observesPlaybackPresses { types += [.select, .playPause] }
            return types.map { NSNumber(value: $0.rawValue) }
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            detachObservers()
            guard let window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification,
                object: nil
            )
            let presses = UITapGestureRecognizer()
            presses.allowedPressTypes = allowedPressTypes
            presses.allowedTouchTypes = []
            presses.cancelsTouchesInView = false
            presses.delaysTouchesBegan = false
            presses.delaysTouchesEnded = false
            presses.delegate = self
            window.addGestureRecognizer(presses)
            pressObserver = presses
        }

        func stop() {
            detachObservers()
            onActivity = nil
            onFocusedFrame = nil
        }

        private func detachObservers() {
            NotificationCenter.default.removeObserver(self)
            if let pressObserver { observedWindow?.removeGestureRecognizer(pressObserver) }
            pressObserver = nil
            observedWindow = nil
        }

        @objc private func focusDidUpdate(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
            reportActivity(for: context.nextFocusedItem)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            guard gestureRecognizer === pressObserver else { return false }
            let item = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
            return observePress(press.type, focusedItem: item)
        }

        func observePress(_ type: UIPress.PressType, focusedItem: (any UIFocusItem)?) -> Bool {
            switch type {
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                reportActivity(for: focusedItem)
            case .select, .playPause:
                if observesPlaybackPresses { reportActivity(for: focusedItem) }
            default: break
            }
            // Receiving an arrow at the end of a row is still activity. Reject
            // recognition so UIKit alone performs navigation and press replay.
            return false
        }

        func reportActivity(for item: (any UIFocusItem)?) {
            guard let frame = focusedFrame(for: item) else { return }
            onFocusedFrame?(frame)
            onActivity?()
        }

        func contains(_ item: (any UIFocusItem)?) -> Bool {
            focusedFrame(for: item) != nil
        }

        private func focusedFrame(for item: (any UIFocusItem)?) -> CGRect? {
            guard let window, let item, item.canBecomeFocused, !bounds.isEmpty else { return nil }
            let frame: CGRect
            if let view = item as? UIView {
                guard view.window === window else { return nil }
                frame = view.convert(view.bounds, to: self)
            } else {
                var environment = item.parentFocusEnvironment
                var container: (any UIFocusItemContainer)?
                var parentView: UIView?
                while let current = environment {
                    if let view = current as? UIView {
                        guard view.window === window else { return nil }
                        parentView = view
                        if container == nil { container = view.focusItemContainer }
                        break
                    }
                    if container == nil { container = current.focusItemContainer }
                    environment = current.parentFocusEnvironment
                }
                if let container {
                    let coordinates: any UICoordinateSpace = self
                    frame = coordinates.convert(item.frame, from: container.coordinateSpace)
                } else if let parentView {
                    // SwiftUI's virtual focus items use their hosting view's coordinates
                    // without exposing a UIFocusItemContainer.
                    frame = parentView.convert(item.frame, to: self)
                } else {
                    return nil
                }
            }
            guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                  bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return frame
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            if let pressObserver {
                let window = observedWindow
                Task { @MainActor in window?.removeGestureRecognizer(pressObserver) }
            }
        }
    }
}
#endif
