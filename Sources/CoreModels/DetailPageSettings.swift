import Foundation
import Observation

/// The compact detail header is a preview; complete ratings remain in title information.
public struct DetailPageSettings: Codable, Equatable, Sendable {
    public var showsHeaderRatings: Bool
    public var maxHeaderRatings: Int {
        didSet { maxHeaderRatings = Self.boundedRatingCount(maxHeaderRatings) }
    }
    public var ratingSourceOrder: [RatingSource]
    public var enabledRatingSources: Set<RatingSource>

    public static let headerRatingCountRange = 1...RatingSource.allCases.count
    public static let defaultRatingOrder: [RatingSource] = [
        .rottenTomatoesAudience, .rottenTomatoes, .imdb, .anilist, .tmdb,
        .metacritic, .letterboxd, .community, .critic
    ]
    public static let `default` = DetailPageSettings()

    public init(
        showsHeaderRatings: Bool = true,
        maxHeaderRatings: Int = 2,
        ratingSourceOrder: [RatingSource] = defaultRatingOrder,
        enabledRatingSources: Set<RatingSource> = Set(RatingSource.allCases)
    ) {
        self.showsHeaderRatings = showsHeaderRatings
        self.maxHeaderRatings = Self.boundedRatingCount(maxHeaderRatings)
        self.ratingSourceOrder = ratingSourceOrder
        self.enabledRatingSources = enabledRatingSources
    }

    private enum CodingKeys: String, CodingKey {
        case showsHeaderRatings, maxHeaderRatings, ratingSourceOrder, enabledRatingSources
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            showsHeaderRatings: try values.decodeIfPresent(Bool.self, forKey: .showsHeaderRatings) ?? true,
            maxHeaderRatings: try values.decodeIfPresent(Int.self, forKey: .maxHeaderRatings) ?? 2,
            ratingSourceOrder: try values.decodeIfPresent([RatingSource].self, forKey: .ratingSourceOrder)
                ?? Self.defaultRatingOrder,
            enabledRatingSources: try values.decodeIfPresent(Set<RatingSource>.self, forKey: .enabledRatingSources)
                ?? Set(RatingSource.allCases)
        )
    }

    public var orderedSources: [RatingSource] {
        var seen: Set<RatingSource> = []
        return (ratingSourceOrder + Self.defaultRatingOrder).filter { seen.insert($0).inserted }
    }

    private static func boundedRatingCount(_ value: Int) -> Int {
        min(max(value, headerRatingCountRange.lowerBound), headerRatingCountRange.upperBound)
    }

    public func headerRatings(
        from available: [ExternalRating],
        isAnime: Bool,
        hidesRatings: Bool
    ) -> [ExternalRating] {
        guard showsHeaderRatings, !hidesRatings else { return [] }
        return Array(orderedSources.compactMap { source in
            guard enabledRatingSources.contains(source),
                  !source.isAnimeOnly || isAnime else { return nil }
            return available.first { $0.source == source }
        }.prefix(maxHeaderRatings))
    }
}

public protocol DetailPageSettingsStoring: Sendable {
    func load() -> DetailPageSettings
    func save(_ settings: DetailPageSettings)
}

/// Property-list values use the same per-profile key and transfer path as other settings.
public final class DetailPageSettingsStore: DetailPageSettingsStoring, @unchecked Sendable {
    public static let baseKey = "com.plozz.detailPageSettings"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
    }

    public func load() -> DetailPageSettings {
        guard let values = defaults.dictionary(forKey: key) else { return .default }
        return DetailPageSettings(
            showsHeaderRatings: values["showsHeaderRatings"] as? Bool ?? true,
            maxHeaderRatings: values["maxHeaderRatings"] as? Int ?? 2,
            ratingSourceOrder: (values["ratingSourceOrder"] as? [String])?
                .compactMap(RatingSource.init(rawValue:)) ?? DetailPageSettings.defaultRatingOrder,
            enabledRatingSources: (values["enabledRatingSources"] as? [String])
                .map { Set($0.compactMap(RatingSource.init(rawValue:))) }
                ?? Set(RatingSource.allCases)
        )
    }

    public func save(_ settings: DetailPageSettings) {
        defaults.set([
            "showsHeaderRatings": settings.showsHeaderRatings,
            "maxHeaderRatings": settings.maxHeaderRatings,
            "ratingSourceOrder": settings.orderedSources.map(\.rawValue),
            "enabledRatingSources": settings.enabledRatingSources.map(\.rawValue).sorted()
        ], forKey: key)
    }
}

@MainActor
@Observable
public final class DetailPageSettingsModel {
    public var settings: DetailPageSettings {
        didSet { store.save(settings) }
    }
    private let store: any DetailPageSettingsStoring

    public init(store: any DetailPageSettingsStoring = DetailPageSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
