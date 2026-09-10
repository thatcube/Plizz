#if os(tvOS)
import SwiftUI
import UIKit

/// Observes UIKit focus entering a region, including native Menu controls whose
/// focus can arrive before SwiftUI's FocusState binding catches up.
public struct NativeFocusRegionObserver: UIViewRepresentable {
    private let isEnabled: Bool
    private let onFocusEntered: () -> Void

    public init(isEnabled: Bool = true, onFocusEntered: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onFocusEntered = onFocusEntered
    }

    public func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    public func updateUIView(_ view: ObserverView, context: Context) {
        view.onFocusEntered = onFocusEntered
        view.isEnabled = isEnabled
    }

    public static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.stop()
    }

    public final class ObserverView: UIView {
        var onFocusEntered: (() -> Void)?
        var isEnabled = false {
            didSet {
                if isEnabled != oldValue { updateObservation() }
            }
        }
        private var containsCurrentFocus = false
        private var pendingCheck: Task<Void, Never>?

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            updateObservation()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            scheduleCurrentFocusCheck()
        }

        func stop() {
            isEnabled = false
            onFocusEntered = nil
        }

        private func updateObservation() {
            NotificationCenter.default.removeObserver(self)
            pendingCheck?.cancel()
            containsCurrentFocus = false
            guard isEnabled, window != nil else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification, object: nil
            )
            scheduleCurrentFocusCheck()
        }

        private func scheduleCurrentFocusCheck() {
            pendingCheck?.cancel()
            guard isEnabled, window != nil else { return }
            pendingCheck = Task { @MainActor [weak self] in
                // Never mutate SwiftUI state during its layout/representable update.
                await Task.yield()
                guard !Task.isCancelled, let self, self.isEnabled,
                      let window = self.window,
                      let system = UIFocusSystem.focusSystem(for: window) else { return }
                self.reportFocus(system.focusedItem)
            }
        }

        @objc private func focusDidUpdate(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                as? UIFocusUpdateContext else { return }
            reportFocus(context.nextFocusedItem)
        }

        func reportFocus(_ item: (any UIFocusItem)?) {
            guard isEnabled else { return }
            let inside = containsFocus(item)
            let entered = inside && !containsCurrentFocus
            containsCurrentFocus = inside
            if entered { onFocusEntered?() }
        }

        func containsFocus(_ item: (any UIFocusItem)?) -> Bool {
            guard let window, let root = contentRoot, let item,
                  item.canBecomeFocused, !bounds.isEmpty else { return false }
            let frame: CGRect
            if let view = item as? UIView {
                guard view.window === window, view.isDescendant(of: root) else { return false }
                frame = view.convert(view.bounds, to: self)
            } else {
                var parent = item.parentFocusEnvironment
                var container: (any UIFocusItemContainer)?
                var belongsToContent = false
                while let environment = parent {
                    if let view = environment as? UIView {
                        guard view.window === window else { return false }
                        if view.isDescendant(of: root) { belongsToContent = true }
                    }
                    if container == nil { container = environment.focusItemContainer }
                    if belongsToContent, container != nil { break }
                    parent = environment.parentFocusEnvironment
                }
                guard belongsToContent, let container else { return false }
                let coordinates: any UICoordinateSpace = self
                frame = coordinates.convert(item.frame, from: container.coordinateSpace)
            }
            guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else { return false }
            return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }

        private var contentRoot: UIView? {
            var responder = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.viewIfLoaded
                }
                responder = current.next
            }
            return superview
        }

        deinit {
            pendingCheck?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
#endif
