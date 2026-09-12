#if os(tvOS)
import SwiftUI
import UIKit
import FeatureHome

/// Resolves the actual focusable control containing a row's label, rather than
/// asking SwiftUI to focus a non-focusable layout/binding container.
struct NavigationRowFocusRequester: UIViewRepresentable {
    let request: Int?
    let onCompleted: (Int, Bool) -> Void

    func makeUIView(context: Context) -> RequestView {
        let view = RequestView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: RequestView, context: Context) {
        uiView.onCompleted = onCompleted
        uiView.request = request
    }

    static func dismantleUIView(_ uiView: RequestView, coordinator: ()) {
        uiView.request = nil
        uiView.onCompleted = nil
    }

    final class RequestView: UIView {
        var onCompleted: ((Int, Bool) -> Void)?
        var request: Int? {
            didSet {
                if request != oldValue {
                    pending?.cancel()
                    pending = nil
                    scheduleFocus()
                }
            }
        }
        private var pending: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleFocus()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleFocus()
        }

        private func scheduleFocus() {
            guard pending == nil, let request, window != nil else { return }
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.request == request else { return }
                guard let window = self.window else {
                    self.complete(request, didFocus: false)
                    return
                }
                // Finish the ScrollViewReader's reveal and focus eligibility
                // changes before looking up the control. Never leave an entry
                // request armed to steal focus during some later unrelated layout.
                window.layoutIfNeeded()
                guard let system = UIFocusSystem.focusSystem(for: window),
                      let target = NavigationRowFocusRequester.target(for: self, in: window) else {
                    HeroFocusDiagnostics.emit("sidebar.native-request no-target token=\(request) bounds=\(self.bounds)")
                    self.complete(request, didFocus: false)
                    return
                }
                HeroFocusDiagnostics.emit("sidebar.native-request token=\(request) target=\(String(describing: target)) frame=\(target.frame)")
                let didFocus = NavigationRowFocusRequester.handoff(to: target, in: window, using: system)
                HeroFocusDiagnostics.emit("sidebar.native-request result=\(didFocus) focused=\(String(describing: system.focusedItem))")
                self.complete(request, didFocus: didFocus)
            }
        }

        private func complete(_ request: Int, didFocus: Bool) {
            guard self.request == request else { return }
            self.request = nil
            onCompleted?(request, didFocus)
        }

        deinit { pending?.cancel() }
    }

    static func handoff(
        to target: any UIFocusItem,
        in window: UIWindow,
        using system: any NavigationFocusUpdating
    ) -> Bool {
        system.requestFocusUpdate(to: target)
        system.updateFocusIfNeeded()
        if system.focusedItem === target { return true }
        // Native Search retains focus across its presentation boundary.
        // Re-evaluate from their shared window, whose preferred rail row is the
        // requested destination, only if the direct request did not succeed.
        // Two requests before an update let the window override the chosen row.
        system.requestFocusUpdate(to: window)
        system.updateFocusIfNeeded()
        return system.focusedItem === target
    }

    static func target(
        for marker: UIView,
        in root: any UIFocusItemContainer
    ) -> (any UIFocusItem)? {
        guard !marker.bounds.isEmpty else { return nil }
        var containers: [any UIFocusItemContainer] = [root]
        var environment: (any UIFocusEnvironment)? = marker
        var seenEnvironments = Set<ObjectIdentifier>()
        while let current = environment, seenEnvironments.insert(ObjectIdentifier(current)).inserted {
            if let container = current.focusItemContainer { containers.append(container) }
            environment = current.parentFocusEnvironment
        }
        var seen = Set<ObjectIdentifier>()
        var best: (item: any UIFocusItem, area: CGFloat)?
        // A scrolled SwiftUI row's focus frame can exclude part of its styled
        // label. Hit-test the label's center instead of requiring full enclosure.
        let point = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        let searchSpace: UIView = marker.window ?? marker
        let searchBounds = searchSpace.bounds
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            // The collapsed rail intentionally sits outside the hosting view's
            // title-safe bounds. A marker-sized query misses that ancestor
            // entirely, even though its unclipped scroll view contains the row.
            // Discover visible containers first, then match the row itself.
            let query = container.coordinateSpace.convert(searchBounds, from: searchSpace)
            for item in container.focusItems(in: query) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                guard item.canBecomeFocused, !(item is UIScrollView) else { continue }
                guard let frame = frame(of: item, relativeTo: marker),
                      !frame.isEmpty, !frame.isInfinite, !frame.isNull,
                      frame.insetBy(dx: -0.5, dy: -0.5).contains(point) else { continue }
                let area = frame.width * frame.height
                if let best, area >= best.area { continue }
                best = (item, area)
            }
        }
        return best?.item
    }

    static func frame(of item: any UIFocusItem, relativeTo marker: UIView) -> CGRect? {
        if let view = item as? UIView {
            return view.convert(view.bounds, to: marker)
        }
        // SwiftUI buttons are virtual focus items. Their frames belong to the
        // nearest containing environment, not necessarily the container whose
        // query returned them. This matters inside a scrolled destination list.
        let coordinates: any UICoordinateSpace = marker
        var parent = item.parentFocusEnvironment
        var seen = Set<ObjectIdentifier>()
        while let environment = parent, seen.insert(ObjectIdentifier(environment)).inserted {
            if let container = environment.focusItemContainer {
                return coordinates.convert(item.frame, from: container.coordinateSpace)
            }
            parent = environment.parentFocusEnvironment
        }
        return nil
    }
}

@MainActor
protocol NavigationFocusUpdating: AnyObject {
    var focusedItem: (any UIFocusItem)? { get }
    func requestFocusUpdate(to environment: any UIFocusEnvironment)
    func updateFocusIfNeeded()
}

extension UIFocusSystem: NavigationFocusUpdating {}

#endif
