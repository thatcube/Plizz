#if os(tvOS)
import SwiftUI
import UIKit
import FeatureHome
import CoreUI

/// The native keyboard moves between keys inside one UIKit focus item. Only
/// UIKit's failed-movement notification proves that Left reached its boundary.
struct SearchBoundaryNavigationObserver: UIViewRepresentable {
    let isEnabled: Bool
    let onOpenNavigation: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onOpenNavigation = onOpenNavigation
        uiView.isEnabled = isEnabled
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) {
        uiView.isEnabled = false
        uiView.onOpenNavigation = nil
    }

    final class ObserverView: UIView {
        var onOpenNavigation: (() -> Void)?
        var isEnabled = false {
            didSet {
                if oldValue != isEnabled { updateObservation() }
            }
        }
        private var pendingOpen: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateObservation()
        }

        private func updateObservation() {
            pendingOpen?.cancel()
            NotificationCenter.default.removeObserver(self)
            guard isEnabled, window != nil else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(movementFailed(_:)),
                name: UIFocusSystem.movementDidFailNotification,
                object: nil
            )
        }

        @objc private func movementFailed(_ notification: Notification) {
            guard isEnabled, let window,
                  let epoch = DetailTransitionNavigation.navigationInputEpoch(in: window),
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                  let current = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                  SearchBoundaryNavigationObserver.shouldOpen(
                    heading: context.focusHeading,
                    previous: context.previouslyFocusedItem,
                    current: current
                  ) else { return }
            pendingOpen?.cancel()
            pendingOpen = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.isEnabled,
                      self.window === window,
                      DetailTransitionNavigation.navigationInputEpoch(in: window) == epoch,
                      UIFocusSystem.focusSystem(for: window)?.focusedItem === current else { return }
                HeroFocusDiagnostics.emit("search.native-boundary left")
                self.onOpenNavigation?()
            }
        }

        deinit {
            pendingOpen?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }

    static func shouldOpen(
        heading: UIFocusHeading,
        previous: (any UIFocusItem)?,
        current: (any UIFocusItem)?
    ) -> Bool {
        guard heading == .left, let previous, previous === current,
              NavigationRailEdgeCatcher.permitsNavigationFallback(from: previous) else { return false }
        var environment: (any UIFocusEnvironment)? = previous
        while let candidate = environment {
            if candidate is UISearchController { return true }
            environment = candidate.parentFocusEnvironment
        }
        return false
    }
}
#endif
