import Foundation

/// Non-secret metadata retained for a channel hidden by one profile.
///
/// The display name lets Settings offer restoration even while the channel's
/// source is offline. Stream URLs, request headers, and credentials never enter
/// this record.
public struct LiveTVHiddenChannel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LiveTVChannelMetadataOverride: Codable, Equatable, Sendable {
    public var name: String?
    public var category: String?
    public var language: String?
    public var country: String?

    public init(name: String? = nil, category: String? = nil, language: String? = nil, country: String? = nil) {
        self.name = name
        self.category = category
        self.language = language
        self.country = country
    }
}

/// Device-local browse layout only. Active focus, query, playback and playback position are never synced.
public struct LiveTVBrowsePreferences: Codable, Equatable, Sendable {
    public var category: String?
    public var language: String?
    public var country: String?
    public var sourceType: String?
    public var configuredSourceID: String?
    public var sort: String
    public var favoritesOnly: Bool
    public var guideOnly: Bool

    public init(
        category: String? = nil, language: String? = nil, country: String? = nil, sourceType: String? = nil,
        configuredSourceID: String? = nil, sort: String = "channelNumber",
        favoritesOnly: Bool = false, guideOnly: Bool = false
    ) {
        self.category = category
        self.language = language
        self.country = country
        self.sourceType = sourceType
        self.configuredSourceID = configuredSourceID
        self.sort = sort
        self.favoritesOnly = favoritesOnly
        self.guideOnly = guideOnly
    }
}

/// Profile-scoped, non-secret Live TV metadata.
///
/// Channel identifiers are retained even when the current catalog is empty or
/// temporarily unavailable. The catalog may resolve them again on a later load.
public struct LiveTVPreferences: Codable, Equatable, Sendable {
    public static let maximumRecentChannelCount = 3
    public static let empty = LiveTVPreferences()

    public let favoriteIDs: Set<String>
    public let recentChannelIDs: [String]
    public let hiddenChannels: [LiveTVHiddenChannel]
    public let favoriteOrder: [String]
    public let favoriteChannels: [LiveTVHiddenChannel]
    public let channelOverrides: [String: LiveTVChannelMetadataOverride]
    public let browse: LiveTVBrowsePreferences
    public let favoriteMultiviews: [LiveTVMultiviewFavorite]
    public var hiddenChannelIDs: Set<String> { Set(hiddenChannels.map(\.id)) }

    public init(
        favoriteIDs: Set<String> = [],
        recentChannelIDs: [String] = [],
        hiddenChannels: [LiveTVHiddenChannel] = [],
        favoriteOrder: [String] = [],
        favoriteChannels: [LiveTVHiddenChannel] = [],
        channelOverrides: [String: LiveTVChannelMetadataOverride] = [:],
        browse: LiveTVBrowsePreferences = .init(),
        favoriteMultiviews: [LiveTVMultiviewFavorite] = []
    ) {
        self.favoriteIDs = favoriteIDs
        var ordered = Set<String>()
        self.favoriteOrder = favoriteOrder.filter { favoriteIDs.contains($0) && ordered.insert($0).inserted }
            + favoriteIDs.subtracting(ordered).sorted()
        var named = Set<String>()
        self.favoriteChannels = favoriteChannels.filter { favoriteIDs.contains($0.id) && named.insert($0.id).inserted }
        self.channelOverrides = channelOverrides
        self.browse = browse
        self.favoriteMultiviews = favoriteMultiviews

        var seen = Set<String>()
        self.recentChannelIDs = Array(
            recentChannelIDs
                .filter { seen.insert($0).inserted }
                .prefix(Self.maximumRecentChannelCount)
        )

        seen.removeAll(keepingCapacity: true)
        self.hiddenChannels = hiddenChannels.filter {
            seen.insert($0.id).inserted
        }
    }

    private enum CodingKeys: String, CodingKey {
        case favoriteIDs
        case recentChannelIDs
        case hiddenChannels
        case favoriteOrder, favoriteChannels, channelOverrides, browse
        case favoriteMultiviews
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let multiviews = try container.decodeIfPresent([LiveTVMultiviewFavorite].self, forKey: .favoriteMultiviews) ?? []
        guard multiviews.allSatisfy(\.isValid), Set(multiviews.map(\.id)).count == multiviews.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .favoriteMultiviews, in: container, debugDescription: "Invalid Multiview favorites")
        }
        let hiddenChannels: [LiveTVHiddenChannel]
        if container.contains(.hiddenChannels) {
            hiddenChannels = try container.decode(
                [LiveTVHiddenChannel].self,
                forKey: .hiddenChannels
            )
        } else {
            hiddenChannels = []
        }
        self.init(
            favoriteIDs: try container.decode(Set<String>.self, forKey: .favoriteIDs),
            recentChannelIDs: try container.decode([String].self, forKey: .recentChannelIDs),
            hiddenChannels: hiddenChannels,
            favoriteOrder: try container.decodeIfPresent([String].self, forKey: .favoriteOrder) ?? [],
            favoriteChannels: try container.decodeIfPresent([LiveTVHiddenChannel].self, forKey: .favoriteChannels) ?? [],
            channelOverrides: try container.decodeIfPresent([String: LiveTVChannelMetadataOverride].self, forKey: .channelOverrides) ?? [:],
            browse: try container.decodeIfPresent(LiveTVBrowsePreferences.self, forKey: .browse) ?? .init(),
            favoriteMultiviews: multiviews
        )
    }

    public func hidingChannel(id: String, name: String) -> LiveTVPreferences {
        guard !hiddenChannelIDs.contains(id) else { return self }
        return LiveTVPreferences(
            favoriteIDs: favoriteIDs,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels + [LiveTVHiddenChannel(id: id, name: name)],
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browse, favoriteMultiviews: favoriteMultiviews
        )
    }

    public func restoringChannel(id: String) -> LiveTVPreferences {
        LiveTVPreferences(
            favoriteIDs: favoriteIDs,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels.filter { $0.id != id },
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browse, favoriteMultiviews: favoriteMultiviews
        )
    }

    public func restoringAllChannels() -> LiveTVPreferences {
        LiveTVPreferences(
            favoriteIDs: favoriteIDs,
            recentChannelIDs: recentChannelIDs,
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browse, favoriteMultiviews: favoriteMultiviews
        )
    }

    public func migratingChannelIDs(_ migration: [String: String]) -> Self {
        func identifier(_ old: String) -> String { migration[old] ?? old }
        var overrides: [String: LiveTVChannelMetadataOverride] = [:]
        for (id, value) in channelOverrides.sorted(by: { $0.key < $1.key }) {
            let newID = identifier(id)
            if overrides[newID] == nil || newID == id { overrides[newID] = value }
        }
        return Self(
            favoriteIDs: Set(favoriteIDs.map(identifier)), recentChannelIDs: recentChannelIDs.map(identifier),
            hiddenChannels: hiddenChannels.map { .init(id: identifier($0.id), name: $0.name) },
            favoriteOrder: favoriteOrder.map(identifier),
            favoriteChannels: favoriteChannels.map { .init(id: identifier($0.id), name: $0.name) },
            channelOverrides: overrides, browse: browse,
            favoriteMultiviews: favoriteMultiviews.map { $0.migratingChannelIDs(migration) }
        )
    }
}

public protocol LiveTVPreferencesStoring: Sendable {
    func load() throws -> LiveTVPreferences
    func save(_ preferences: LiveTVPreferences) throws
}

public enum LiveTVPreferencesStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
    case decodingFailed
    case encodingFailed
}

/// Persists Live TV favorites, recent channel identifiers, and hidden channel
/// metadata in `UserDefaults`.
///
/// A corrupt value is reported rather than treated as empty. `save(_:)` also
/// refuses to replace an unreadable existing value, preserving it for recovery
/// or diagnosis instead of silently erasing it.
public final class LiveTVPreferencesStore: LiveTVPreferencesStoring, @unchecked Sendable {
    static let baseKey = "com.plozz.liveTV.preferences"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; secondary profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
    }

    public func load() throws -> LiveTVPreferences {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ preferences: LiveTVPreferences) throws {
        guard preferences.favoriteMultiviews.allSatisfy(\.isValid),
              Set(preferences.favoriteMultiviews.map(\.id)).count == preferences.favoriteMultiviews.count else {
            throw LiveTVPreferencesStoreError.encodingFailed
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(preferences)
        } catch {
            throw LiveTVPreferencesStoreError.encodingFailed
        }

        lock.lock()
        defer { lock.unlock() }

        if defaults.object(forKey: key) != nil {
            _ = try loadLocked()
        }
        defaults.set(encoded, forKey: key)
    }

    private func loadLocked() throws -> LiveTVPreferences {
        guard let stored = defaults.object(forKey: key) else {
            return .empty
        }
        guard let data = stored as? Data else {
            throw LiveTVPreferencesStoreError.invalidStoredValue
        }
        do {
            return try JSONDecoder().decode(LiveTVPreferences.self, from: data)
        } catch {
            throw LiveTVPreferencesStoreError.decodingFailed
        }
    }
}
