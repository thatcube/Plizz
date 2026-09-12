import Foundation

/// A top-level destination in the custom navigation rail.
///
/// Unlike the native tab styles — where the compact destinations are fixed — the
/// rail treats each of the viewer's libraries as a first-class destination, so a
/// library grid is a *root* screen with chrome rather than a page pushed on top of
/// Home.
public enum NavigationRailDestination: Hashable, Sendable {
    case home
    case search
    case watchlist
    #if DEBUG
    /// Development-only Live TV prototype. Release builds deliberately cannot
    /// restore this destination from persisted scene storage.
    case liveTV
    #endif
    case music
    case settings
    /// A single library, addressed by its ``AggregatedLibrary/key``.
    case library(String)
    /// The synthetic combined browse over every visible library.
    case allLibraries

    /// A stable string form for scene storage.
    public var storageValue: String {
        switch self {
        case .home: return "home"
        case .search: return "search"
        case .watchlist: return "watchlist"
        #if DEBUG
        case .liveTV: return "liveTV"
        #endif
        case .music: return "music"
        case .settings: return "settings"
        case .allLibraries: return "allLibraries"
        case let .library(key): return "library:\(key)"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "home": self = .home
        case "search": self = .search
        case "watchlist": self = .watchlist
        #if DEBUG
        case "liveTV": self = .liveTV
        #endif
        case "music": self = .music
        case "settings": self = .settings
        case "allLibraries": self = .allLibraries
        default:
            guard storageValue.hasPrefix("library:") else { return nil }
            self = .library(String(storageValue.dropFirst("library:".count)))
        }
    }
}

/// One library slot in the rail: either a real library or the synthetic
/// "All Libraries" entry.
public struct NavigationRailLibraryEntry: Hashable, Sendable, Identifiable {
    /// The arrangement key — an ``AggregatedLibrary/key``, or
    /// ``NavigationLibraryLayout/allLibrariesKey`` for the combined entry.
    public let key: String
    /// The backing library; `nil` for the combined "All Libraries" entry.
    public let library: AggregatedLibrary?

    public init(key: String, library: AggregatedLibrary?) {
        self.key = key
        self.library = library
    }

    public var id: String { key }

    /// Whether this is the synthetic combined entry.
    public var isAllLibraries: Bool { library == nil }

    public var destination: NavigationRailDestination {
        library == nil ? .allLibraries : .library(key)
    }
}

/// Pure resolution of the rail's library slots from the live library set plus the
/// profile's saved arrangement. SwiftUI-free so the ordering/visibility rules are
/// unit-testable without a running view hierarchy.
public enum NavigationDestinationDefaults {
    public static func compact(hasMusic: Bool) -> [String] {
        var keys = [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey]
        #if DEBUG
        keys.append(NavigationLibraryLayout.liveTVKey)
        #endif
        keys.append(NavigationLibraryLayout.searchKey)
        if hasMusic { keys.append(NavigationLibraryLayout.musicKey) }
        keys.append(NavigationLibraryLayout.settingsKey)
        return keys
    }

    public static func sidebar(visibleLibraries: [AggregatedLibrary], hasMusic: Bool) -> [String] {
        var keys = compact(hasMusic: hasMusic)
        keys.insert(
            contentsOf: NavigationRailPlan.availableKeys(visibleLibraries: visibleLibraries),
            at: keys.count - 1
        )
        return keys
    }

    public static func rail(visibleLibraries: [AggregatedLibrary], hasMusic: Bool) -> [String] {
        var keys = sidebar(visibleLibraries: visibleLibraries, hasMusic: hasMusic)
        keys.removeAll { $0 == NavigationLibraryLayout.searchKey }
        keys.insert(NavigationLibraryLayout.searchKey, at: 0)
        return keys
    }

    public static var iOS: [String] {
        var keys = [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey]
        #if DEBUG
        keys.append(NavigationLibraryLayout.liveTVKey)
        #endif
        return keys + [
            NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.settingsKey,
            NavigationLibraryLayout.searchKey,
        ]
    }
}

public enum NavigationRailPlan {
    /// Every key offered by Settings' shared navigation arranger. Built-ins are
    /// present even with no connected libraries so a temporarily-offline server
    /// cannot make Home, Search, Settings, or another app destination disappear
    /// from the editor.
    public static func customizableKeys(
        visibleLibraries: [AggregatedLibrary],
        style: NavigationStyle = .sidebar
    ) -> [String] {
        let keys: [String]
        switch style {
        case .tabBar: keys = NavigationDestinationDefaults.compact(hasMusic: true)
        case .sidebar: keys = NavigationDestinationDefaults.sidebar(visibleLibraries: visibleLibraries, hasMusic: true)
        case .rail: keys = NavigationDestinationDefaults.rail(visibleLibraries: visibleLibraries, hasMusic: true)
        }
        return deduplicated(keys)
    }

    /// The arrangeable library keys: the combined entry first, then each visible
    /// non-music library in discovery order.
    public static func availableKeys(visibleLibraries: [AggregatedLibrary]) -> [String] {
        [NavigationLibraryLayout.allLibrariesKey] + browsableLibraries(visibleLibraries).map(\.key)
    }

    /// The libraries the rail can offer: everything that is not a music library.
    public static func browsableLibraries(_ libraries: [AggregatedLibrary]) -> [AggregatedLibrary] {
        libraries.filter { !$0.library.isMusic }
    }

    /// The rail's library slots, in the viewer's order, with hidden entries removed.
    public static func entries(
        visibleLibraries: [AggregatedLibrary],
        layout: NavigationLibraryLayout
    ) -> [NavigationRailLibraryEntry] {
        let browsable = browsableLibraries(visibleLibraries)
        let byKey = Dictionary(
            browsable.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let available = availableKeys(visibleLibraries: visibleLibraries)
        return layout.visibleKeys(available: available).compactMap { key in
            if key == NavigationLibraryLayout.allLibrariesKey {
                // The combined entry is pointless with nothing to combine, and
                // actively misleading with exactly one library.
                guard browsable.count > 1 else { return nil }
                return NavigationRailLibraryEntry(key: key, library: nil)
            }
            guard let library = byKey[key] else { return nil }
            return NavigationRailLibraryEntry(key: key, library: library)
        }
    }

    /// Resolves the complete ordered destination list for one navigation style.
    ///
    /// `availableKeys` is both the style's supported set and its historical
    /// default order. A compact top bar therefore omits libraries, while the
    /// native sidebar and custom rail include them. Once a profile has explicitly
    /// arranged built-ins, that saved order wins wherever the style supports the
    /// destination.
    public static func destinations(
        visibleLibraries: [AggregatedLibrary],
        layout: NavigationLibraryLayout,
        availableKeys: [String]
    ) -> [NavigationRailDestination] {
        let libraryEntries = entries(visibleLibraries: visibleLibraries, layout: layout)
        let libraryDestinations = Dictionary(
            uniqueKeysWithValues: libraryEntries.map { ($0.key, $0.destination) }
        )
        let validKeys = deduplicated(availableKeys).filter { key in
            if key == NavigationLibraryLayout.allLibrariesKey {
                return libraryDestinations[key] != nil
            }
            if isBuiltInKey(key) {
                return true
            }
            return libraryDestinations[key] != nil
        }
        let orderedKeys = layout.visibleKeys(available: validKeys)
        var destinations = orderedKeys.compactMap { key -> NavigationRailDestination? in
            if let libraryDestination = libraryDestinations[key] {
                return libraryDestination
            }
            return destination(for: key)
        }

        if validKeys.contains(NavigationLibraryLayout.settingsKey),
           !destinations.contains(.settings) {
            destinations.append(.settings)
        }
        return destinations
    }

    /// Maps a persisted arrangement key to its built-in destination.
    public static func destination(for key: String) -> NavigationRailDestination? {
        switch key {
        case NavigationLibraryLayout.homeKey: return .home
        case NavigationLibraryLayout.searchKey: return .search
        case NavigationLibraryLayout.watchlistKey: return .watchlist
        #if DEBUG
        case NavigationLibraryLayout.liveTVKey: return .liveTV
        #endif
        case NavigationLibraryLayout.musicKey: return .music
        case NavigationLibraryLayout.settingsKey: return .settings
        case NavigationLibraryLayout.allLibrariesKey: return .allLibraries
        default: return nil
        }
    }

    /// Stable arrangement key for any destination.
    public static func key(for destination: NavigationRailDestination) -> String {
        switch destination {
        case .home: return NavigationLibraryLayout.homeKey
        case .search: return NavigationLibraryLayout.searchKey
        case .watchlist: return NavigationLibraryLayout.watchlistKey
        #if DEBUG
        case .liveTV: return NavigationLibraryLayout.liveTVKey
        #endif
        case .music: return NavigationLibraryLayout.musicKey
        case .settings: return NavigationLibraryLayout.settingsKey
        case .allLibraries: return NavigationLibraryLayout.allLibrariesKey
        case let .library(key): return key
        }
    }

    /// Resolves a selected destination to the first destination the active style
    /// can actually show. Settings is the final invariant fallback.
    public static func resolvedSelection(
        _ selection: NavigationRailDestination,
        destinations: [NavigationRailDestination]
    ) -> NavigationRailDestination {
        destinations.contains(selection) ? selection : (destinations.first ?? .settings)
    }

    private static func isBuiltInKey(_ key: String) -> Bool {
        destination(for: key) != nil
    }

    private static func deduplicated(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }
}
