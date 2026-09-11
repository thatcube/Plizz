#if DEBUG && os(tvOS)
import SwiftUI
import UIKit

/// Live TV is the navigation root, not a dismissible page above an empty root.
/// The owning stack receives chrome visibility without moving the live player.
public struct LiveTVNavigationContainer<Content: View>: View {
    private let hidesNavigation: Bool
    private let content: Content

    public init(hidesNavigation: Bool, @ViewBuilder content: () -> Content) {
        self.hidesNavigation = hidesNavigation
        self.content = content()
    }

    public var body: some View {
        NavigationStack { content }
            .toolbar(hidesNavigation ? .hidden : .visible, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// tvOS's inline keyboard and the existing guide share one search surface.
/// A TextField here would open another full-screen text-entry presentation.
struct PrototypeNativeSearch<Results: View>: UIViewControllerRepresentable {
    @Binding var query: String
    let restoresGuideFocus: Bool
    let isPresented: Bool
    let close: () -> Void
    let editing: () -> Void
    @ViewBuilder let results: (_ close: @escaping () -> Void) -> Results
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let host = UIHostingController(rootView: PrototypeSearchResults(content: results(context.coordinator.closeAction)))
        host.view.backgroundColor = .clear
        let search = PrototypeSearchController(searchResultsController: host)
        search.close = context.coordinator.closeAction
        search.reduceMotion = reduceMotion
        search.modalPresentationStyle = .custom
        search.searchBar.placeholder = String(localized: "Search channels", locale: locale)
        search.searchBar.text = query
        search.searchBar.autocorrectionType = .no
        search.searchBar.autocapitalizationType = .none
        search.searchResultsUpdater = context.coordinator
        search.searchBar.delegate = context.coordinator
        search.searchBar.accessibilityIdentifier = "live-tv-search-field"
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.view.backgroundColor = .clear
        search.restoresGuideFocus = restoresGuideFocus
        let container = UISearchContainerViewController(searchController: search)
        container.definesPresentationContext = true
        container.view.backgroundColor = .clear
        let base = UIViewController()
        base.view.backgroundColor = .clear
        let navigation = UINavigationController()
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.backgroundColor = .clear
        navigation.setViewControllers(isPresented ? [base, container] : [base], animated: false)
        navigation.delegate = context.coordinator
        context.coordinator.host = host
        context.coordinator.search = search
        context.coordinator.container = container
        context.coordinator.navigation = navigation
        context.coordinator.base = base
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = PrototypeSearchResults(content: results(context.coordinator.closeAction))
        guard let search = context.coordinator.search else {
            assertionFailure("Missing Live TV Search controller")
            return
        }
        if search.searchBar.text != query { search.searchBar.text = query }
        search.view.isUserInteractionEnabled = context.environment.isEnabled
        search.reduceMotion = reduceMotion
        if search.restoresGuideFocus != restoresGuideFocus {
            search.restoresGuideFocus = restoresGuideFocus
            search.setNeedsFocusUpdate()
        }
        context.coordinator.synchronizePresentation()
    }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        coordinator.isDismantled = true
        controller.delegate = nil
        coordinator.search?.searchResultsUpdater = nil
        coordinator.search?.searchBar.delegate = nil
        coordinator.search?.close = nil
        if let base = coordinator.base {
            controller.setViewControllers([base], animated: false)
        }
        coordinator.host = nil
        coordinator.search = nil
        coordinator.container = nil
        coordinator.navigation = nil
        coordinator.base = nil
    }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UINavigationControllerDelegate {
        var parent: PrototypeNativeSearch
        var host: UIHostingController<PrototypeSearchResults<Results>>?
        weak var search: PrototypeSearchController?
        var container: UISearchContainerViewController?
        weak var navigation: UINavigationController?
        weak var base: UIViewController?
        private(set) var isClosing = false
        private var changingPresentation = false
        private var closeNotified = false
        var isDismantled = false

        init(_ parent: PrototypeNativeSearch) { self.parent = parent }

        var closeAction: () -> Void {
            { [weak self] in self?.requestClose() }
        }

        func requestClose() {
            guard parent.isPresented, !isClosing, !isDismantled, let search else { return }
            isClosing = true
            search.fadeOut { [weak self] in
                guard let self, !self.isDismantled, let navigation = self.navigation, let base = self.base else { return }
                // UISearchContainer owns the search presentation. Pop its owner;
                // isActive only changes editing and dismiss() can leave it open.
                navigation.setViewControllers([base], animated: false)
                self.notifyClosed()
            }
        }

        private func notifyClosed() {
            guard !isDismantled, !closeNotified else { return }
            closeNotified = true
            parent.close()
        }

        func synchronizePresentation() {
            guard let search, let container, let navigation, let base,
                  !isClosing, !changingPresentation, !isDismantled else { return }
            let visible = navigation.topViewController === container
            guard visible != parent.isPresented else { return }
            changingPresentation = true
            search.searchBar.text = parent.query
            navigation.setViewControllers(parent.isPresented ? [base, container] : [base], animated: false)
            changingPresentation = false
        }

        func navigationController(
            _ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool
        ) {
            guard viewController === base, navigationController.topViewController === base,
                  parent.isPresented, !isClosing, !changingPresentation else { return }
            notifyClosed()
        }

        func updateSearchResults(for searchController: UISearchController) {
            guard parent.isPresented, !isClosing, !changingPresentation, !isDismantled else { return }
            let text = searchController.searchBar.text ?? ""
            if parent.query != text { parent.query = text }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            Task { @MainActor [weak self] in
                guard let self, self.parent.isPresented, !self.isClosing, !self.isDismantled,
                      !self.parent.restoresGuideFocus else { return }
                self.parent.editing()
            }
        }
    }
}

final class PrototypeSearchController: UISearchController {
    var restoresGuideFocus = false
    var reduceMotion = false
    var close: (() -> Void)?
    var fadeDuration: TimeInterval { reduceMotion ? 0 : 0.18 }
    private(set) lazy var backPress = UITapGestureRecognizer(target: self, action: #selector(closeFromRemote))

    override func viewDidLoad() {
        super.viewDidLoad()
        backPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        // Attach to Search itself, never the window: sheets, playback and native
        // context menus outside this subtree keep their own Back handling.
        view.addGestureRecognizer(backPress)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.alpha = reduceMotion ? 1 : 0
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Fade the actual presented view, not the SwiftUI representable behind it.
        UIView.animate(withDuration: fadeDuration, delay: fadeDuration, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.alpha = 1
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: fadeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.alpha = 0
        } completion: { _ in completion() }
    }

    @objc func closeFromRemote() {
        guard viewIfLoaded?.window != nil, !isBeingDismissed else { return }
        close?()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if restoresGuideFocus, let searchResultsController { return [searchResultsController] }
        return super.preferredFocusEnvironments
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if restoresGuideFocus, let next = context.nextFocusedView,
           let results = searchResultsController?.view, !next.isDescendant(of: results) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }
}
#endif
