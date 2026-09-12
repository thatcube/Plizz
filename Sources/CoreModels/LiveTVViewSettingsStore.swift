import Foundation

/// Profile-scoped preferences that control how Live TV channels are presented.
public struct LiveTVViewSettings: Equatable, Sendable {
    public var sortByName: Bool
    public var autoPreview: Bool
    public var keepWatchingWhileBrowsing: Bool
    public var favoritesOnly: Bool
    public var guideOnly: Bool
    public var wifiOnly: Bool

    public init(
        sortByName: Bool = false,
        autoPreview: Bool = true,
        keepWatchingWhileBrowsing: Bool = false,
        favoritesOnly: Bool = false,
        guideOnly: Bool = false,
        wifiOnly: Bool = false
    ) {
        self.sortByName = sortByName
        self.autoPreview = autoPreview
        self.keepWatchingWhileBrowsing = keepWatchingWhileBrowsing
        self.favoritesOnly = favoritesOnly
        self.guideOnly = guideOnly
        self.wifiOnly = wifiOnly
    }
}

public protocol LiveTVViewSettingsStoring: Sendable {
    func load() -> LiveTVViewSettings
    func save(_ settings: LiveTVViewSettings)
}

/// Persists Live TV view preferences as independent typed values.
///
/// Each key is profile-scoped so changing channel presentation for one household
/// profile does not affect another profile.
public final class LiveTVViewSettingsStore: LiveTVViewSettingsStoring, @unchecked Sendable {
    public static let didChange = Notification.Name("com.plozz.liveTV.view.didChange")
    static let sortByNameKey = "com.plozz.liveTV.view.sortByName"
    static let autoPreviewKey = "com.plozz.liveTV.view.autoPreview"
    static let keepWatchingWhileBrowsingKey = "com.plozz.liveTV.view.keepWatchingWhileBrowsing"
    static let favoritesOnlyKey = "com.plozz.liveTV.view.favoritesOnly"
    static let guideOnlyKey = "com.plozz.liveTV.view.guideOnly"
    static let wifiOnlyKey = "com.plozz.liveTV.view.wifiOnly"

    private let defaults: UserDefaults
    private let sortByNameKey: String
    private let autoPreviewKey: String
    private let keepWatchingWhileBrowsingKey: String
    private let favoritesOnlyKey: String
    private let guideOnlyKey: String
    private let wifiOnlyKey: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses un-suffixed keys; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.sortByNameKey = SettingsKey.scoped(Self.sortByNameKey, namespace: namespace)
        self.autoPreviewKey = SettingsKey.scoped(Self.autoPreviewKey, namespace: namespace)
        self.keepWatchingWhileBrowsingKey = SettingsKey.scoped(
            Self.keepWatchingWhileBrowsingKey, namespace: namespace
        )
        self.favoritesOnlyKey = SettingsKey.scoped(Self.favoritesOnlyKey, namespace: namespace)
        self.guideOnlyKey = SettingsKey.scoped(Self.guideOnlyKey, namespace: namespace)
        self.wifiOnlyKey = SettingsKey.scoped(Self.wifiOnlyKey, namespace: namespace)
    }

    public func load() -> LiveTVViewSettings {
        let fallback = LiveTVViewSettings()
        return LiveTVViewSettings(
            sortByName: value(forKey: sortByNameKey, default: fallback.sortByName),
            autoPreview: value(forKey: autoPreviewKey, default: fallback.autoPreview),
            keepWatchingWhileBrowsing: value(
                forKey: keepWatchingWhileBrowsingKey, default: fallback.keepWatchingWhileBrowsing
            ),
            favoritesOnly: value(forKey: favoritesOnlyKey, default: fallback.favoritesOnly),
            guideOnly: value(forKey: guideOnlyKey, default: fallback.guideOnly),
            wifiOnly: value(forKey: wifiOnlyKey, default: fallback.wifiOnly)
        )
    }

    public func save(_ settings: LiveTVViewSettings) {
        defaults.set(settings.sortByName, forKey: sortByNameKey)
        defaults.set(settings.autoPreview, forKey: autoPreviewKey)
        defaults.set(settings.keepWatchingWhileBrowsing, forKey: keepWatchingWhileBrowsingKey)
        defaults.set(settings.favoritesOnly, forKey: favoritesOnlyKey)
        defaults.set(settings.guideOnly, forKey: guideOnlyKey)
        defaults.set(settings.wifiOnly, forKey: wifiOnlyKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func value(forKey key: String, default fallback: Bool) -> Bool {
        guard let stored = defaults.object(forKey: key) else { return fallback }
        return stored as? Bool ?? fallback
    }
}
