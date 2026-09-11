import Foundation

/// A profile's navigation list: which built-in and library destinations appear
/// in the app shell, and in what order.
///
/// Deliberately separate from ``HomeLibraryVisibility``: that answers "is this
/// library available at all / does it appear on Home", which is a *content*
/// decision the whole app honours. This answers "does this destination get a slot
/// in the navigation chrome", which is a *layout* decision — a household may well
/// want a rarely-used library still browsable from Home while keeping navigation
/// short. A library that is disabled outright never reaches navigation regardless,
/// because the shell is fed the already-visible library set.
///
/// Per the "build for flexibility" mandate, layout is DATA: an explicit order plus
/// a hidden set, persisted per profile, resolved against the live library list via
/// the shared ``OrderedVisibilityList`` so a newly discovered library appears
/// (enabled, at the end) instead of silently vanishing.
public struct NavigationLibraryLayout: Codable, Equatable, Sendable {
    /// Reserved keys for first-class destinations. Keeping these in the existing
    /// order/hidden payload preserves the on-disk format and profile scoping.
    public static let homeKey = "plozz.navigation.home"
    public static let searchKey = "plozz.navigation.search"
    public static let watchlistKey = "plozz.navigation.watchlist"
    #if DEBUG
    public static let liveTVKey = "plozz.navigation.liveTV"
    #endif
    public static let musicKey = "plozz.navigation.music"
    public static let downloadsKey = "plozz.navigation.downloads"
    public static let settingsKey = "plozz.navigation.settings"

    /// The reserved key of the synthetic **All Libraries** entry — a single
    /// combined browse over every visible library on every signed-in server. Not a
    /// real `AggregatedLibrary.key` (which is always `"accountID:libraryID"`, so
    /// the reserved form can never collide) but it participates in ordering and
    /// hiding exactly like one.
    public static let allLibrariesKey = "plozz.navigation.allLibraries"

    /// Navigation entry keys in the viewer's explicit order. Advisory: keys no
    /// longer present are ignored, and live keys missing from it are appended.
    public var order: [String]

    /// Entry keys the viewer has removed from navigation. Library content remains
    /// browsable from Home — this only hides the top-level shortcut.
    public var hiddenKeys: Set<String>

    public init(order: [String] = [], hiddenKeys: Set<String> = []) {
        self.order = order
        self.hiddenKeys = hiddenKeys.subtracting([Self.settingsKey])
    }

    /// Every supported destination is on by default. Each shell supplies its
    /// platform-specific default order when resolving this empty layout.
    public static let `default` = NavigationLibraryLayout()

    /// Whether an entry is shown in navigation.
    public func isVisible(_ key: String) -> Bool {
        key == Self.settingsKey || !hiddenKeys.contains(key)
    }

    /// Shows/hides one navigation entry.
    public mutating func setVisible(_ visible: Bool, for key: String) {
        guard key != Self.settingsKey else {
            hiddenKeys.remove(key)
            return
        }
        if visible {
            hiddenKeys.remove(key)
        } else {
            hiddenKeys.insert(key)
        }
    }

    /// Resolves the persisted order + hidden set against the live entry keys.
    ///
    /// `available` must already be filtered to entries that exist right now (the
    /// All Libraries key plus every visible library key). The result's `enabled`
    /// section is exactly what the rail renders, top to bottom.
    public func sections(available: [String]) -> OrderedVisibilityList.Sections<String> {
        let available = deduplicated(available)
        let hidden = hiddenKeys.subtracting([Self.settingsKey])
        let sections: OrderedVisibilityList.Sections<String>

        if hasExplicitDestinationOrder {
            sections = OrderedVisibilityList.resolving(
                available: available,
                order: order,
                hidden: hidden
            )
        } else {
            // Before built-in destinations became arrangeable, `order` contained
            // only All Libraries and real library keys. Preserve that library
            // arrangement while letting each navigation style keep its historical
            // built-in default order.
            let libraryKeys = available.filter { !Self.destinationKeys.contains($0) }
            let orderedLibraries = OrderedVisibilityList.resolving(
                available: libraryKeys,
                order: order,
                hidden: []
            ).combined
            var libraryIterator = orderedLibraries.makeIterator()
            let resolvedOrder = available.map { key in
                Self.destinationKeys.contains(key) ? key : (libraryIterator.next() ?? key)
            }
            sections = OrderedVisibilityList.resolving(
                available: available,
                order: resolvedOrder,
                hidden: hidden
            )
        }

        guard available.contains(Self.settingsKey),
              !sections.enabled.contains(Self.settingsKey) else {
            return sections
        }
        return OrderedVisibilityList.Sections(
            enabled: sections.enabled + [Self.settingsKey],
            disabled: sections.disabled.filter { $0 != Self.settingsKey }
        )
    }

    /// The visible entries, in order.
    public func visibleKeys(available: [String]) -> [String] {
        sections(available: available).enabled
    }

    /// Replaces the layout from an edited pair of sections (the reorder control's
    /// output). Keys absent from `available` keep their persisted position/hidden
    /// state so a temporarily-offline server doesn't lose the viewer's arrangement.
    public mutating func apply(
        _ sections: OrderedVisibilityList.Sections<String>,
        available: [String]
    ) {
        let available = deduplicated(available)
        let availableSet = Set(available)
        var enabled = sections.enabled
        var disabled = sections.disabled
        if availableSet.contains(Self.settingsKey) {
            disabled.removeAll { $0 == Self.settingsKey }
            if !enabled.contains(Self.settingsKey) {
                enabled.append(Self.settingsKey)
            }
        }
        let edited = enabled + disabled
        // Splice the edited (live) keys back into the persisted order, keeping any
        // remembered key that isn't currently available exactly where it was.
        var result: [String] = []
        var editedIterator = edited.makeIterator()
        for key in order {
            if availableSet.contains(key) {
                if let next = editedIterator.next() { result.append(next) }
            } else {
                result.append(key)
            }
        }
        while let next = editedIterator.next() { result.append(next) }

        var seen: Set<String> = []
        order = result.filter { seen.insert($0).inserted }
        hiddenKeys = hiddenKeys
            .subtracting(availableSet)
            .union(disabled)
            .subtracting([Self.settingsKey])
    }

    /// Removes impossible persisted state while preserving every unknown key for
    /// future/offline restoration.
    public mutating func enforceRequiredVisibility() {
        hiddenKeys.remove(Self.settingsKey)
    }

    /// Built-ins whose presence in `order` proves the profile has used the newer
    /// whole-navigation arranger. All Libraries is intentionally excluded because
    /// it was already persisted by the legacy library-only arranger.
    private static var destinationKeys: Set<String> {
        var keys: Set<String> = [
            homeKey,
            searchKey,
            watchlistKey,
            musicKey,
            downloadsKey,
            settingsKey,
        ]
        #if DEBUG
        keys.insert(liveTVKey)
        #endif
        return keys
    }

    private var hasExplicitDestinationOrder: Bool {
        order.contains(where: Self.destinationKeys.contains)
    }

    private func deduplicated(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }
}

/// Persists ``NavigationLibraryLayout`` across launches, scoped per profile.
public protocol NavigationLibraryLayoutStoring: Sendable {
    func load() -> NavigationLibraryLayout
    func save(_ layout: NavigationLibraryLayout)
}

public final class NavigationLibraryLayoutStore: NavigationLibraryLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let defaultLayout: NavigationLibraryLayout

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their `Profile.id`
    ///   so each profile arranges its own navigation.
    public init(
        defaults: UserDefaults = .standard,
        namespace: String? = nil,
        defaultLayout: NavigationLibraryLayout = .default
    ) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.navigationLibraryLayout", namespace: namespace)
        self.defaultLayout = defaultLayout
    }

    public func load() -> NavigationLibraryLayout {
        guard let data = defaults.data(forKey: key),
              var layout = try? JSONDecoder().decode(NavigationLibraryLayout.self, from: data) else {
            var layout = defaultLayout
            layout.enforceRequiredVisibility()
            return layout
        }
        layout.enforceRequiredVisibility()
        return layout
    }

    public func save(_ layout: NavigationLibraryLayout) {
        var layout = layout
        layout.enforceRequiredVisibility()
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: key)
        }
    }
}
