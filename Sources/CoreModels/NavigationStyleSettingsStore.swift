import Foundation
import Observation

/// Persists the selected `NavigationStyle` and tvOS exit behavior across
/// launches in standard `UserDefaults`.
///
/// Mirrors `MusicPlayerSettingsStore`: both preferences are stored **per profile**
/// with namespace-scoped keys. The primary profile keeps the legacy un-suffixed
/// navigation-style key so existing installs upgrade cleanly and inherit the
/// choice they already made while it was an app-wide setting.
public protocol NavigationStyleSettingsStoring: Sendable {
    func load() -> NavigationStyle
    func save(_ style: NavigationStyle)
    func loadPreventsAccidentalExit() -> Bool
    func savePreventsAccidentalExit(_ preventsExit: Bool)
}

public final class NavigationStyleSettingsStore: NavigationStyleSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let styleKey: String
    private let preventsAccidentalExitKey: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key (`NavigationStyle.storageKey`);
    ///   other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.styleKey = SettingsKey.scoped(NavigationStyle.storageKey, namespace: namespace)
        self.preventsAccidentalExitKey = SettingsKey.scoped(
            "preventsAccidentalExit",
            namespace: namespace
        )
    }

    public func load() -> NavigationStyle {
        guard let raw = defaults.string(forKey: styleKey),
              let style = NavigationStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    public func save(_ style: NavigationStyle) {
        defaults.set(style.rawValue, forKey: styleKey)
    }

    public func loadPreventsAccidentalExit() -> Bool {
        defaults.bool(forKey: preventsAccidentalExitKey)
    }

    public func savePreventsAccidentalExit(_ preventsExit: Bool) {
        defaults.set(preventsExit, forKey: preventsAccidentalExitKey)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen navigation chrome persisted + broadcast to the view tree. Mirrors
/// `CardStyleSettingsModel`.
///
/// Owns all navigation preferences — which chrome, whether Back may leave the app
/// from top-level navigation, and how destinations are arranged in every style.
/// Keeping them together lets every shell and the Settings page share
/// one profile-scoped model.
@MainActor
@Observable
public final class NavigationStyleSettingsModel {
    public var style: NavigationStyle {
        didSet { store.save(style) }
    }

    /// Consumes short Back presses in the tvOS sidebar or tab bar without
    /// changing Back navigation inside content or system Home controls.
    public var preventsAccidentalExit: Bool {
        didSet { store.savePreventsAccidentalExit(preventsAccidentalExit) }
    }

    /// Which optional destinations and libraries navigation shows, plus the library
    /// order. Persisted regardless of style so switching chrome never loses it.
    public private(set) var libraryLayout: NavigationLibraryLayout

    public var showsWatchlist: Bool {
        get { libraryLayout.isVisible(NavigationLibraryLayout.watchlistKey) }
        set { setDestination(newValue, key: NavigationLibraryLayout.watchlistKey) }
    }

    public var showsMusic: Bool {
        get { libraryLayout.isVisible(NavigationLibraryLayout.musicKey) }
        set { setDestination(newValue, key: NavigationLibraryLayout.musicKey) }
    }

    private let store: NavigationStyleSettingsStoring
    private let layoutStore: NavigationLibraryLayoutStoring

    public init(
        store: NavigationStyleSettingsStoring = NavigationStyleSettingsStore(),
        layoutStore: NavigationLibraryLayoutStoring = NavigationLibraryLayoutStore()
    ) {
        self.store = store
        self.layoutStore = layoutStore
        self.style = store.load()
        self.preventsAccidentalExit = store.loadPreventsAccidentalExit()
        let loadedLayout = layoutStore.load()
        var layout = loadedLayout
        layout.enforceRequiredVisibility()
        self.libraryLayout = layout
        if layout != loadedLayout {
            layoutStore.save(layout)
        }
    }

    /// The editable enabled/hidden split for the Settings reorder control.
    public func librarySections(available: [String]) -> OrderedVisibilityList.Sections<String> {
        libraryLayout.sections(available: available)
    }

    /// Applies an edit from the reorder control and persists it.
    public func applyLibrarySections(
        _ sections: OrderedVisibilityList.Sections<String>,
        available: [String]
    ) {
        var next = libraryLayout
        next.apply(sections, available: available)
        guard next != libraryLayout else { return }
        libraryLayout = next
        layoutStore.save(next)
    }

    /// Restores every destination's default visibility and order.
    public func resetLibraryLayout() {
        let next = NavigationLibraryLayout.default
        guard libraryLayout != next else { return }
        libraryLayout = next
        layoutStore.save(libraryLayout)
    }

    private func setDestination(_ visible: Bool, key: String) {
        var next = libraryLayout
        next.setVisible(visible, for: key)
        guard next != libraryLayout else { return }
        libraryLayout = next
        layoutStore.save(next)
    }
}
