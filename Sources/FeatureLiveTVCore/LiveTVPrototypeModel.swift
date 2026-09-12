#if DEBUG
import CoreModels
import Foundation
import Observation

public enum LiveTVPrototypeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case iptv
    case jellyfin
    case plex
    case emby
    case plozz

    public var id: String { rawValue }
}

public enum LiveTVPrototypeScenario: String, CaseIterable, Identifiable, Sendable {
    case noGuide
    case mixedGuide
    case fullGuide
    case staleGuide
    case failedGuide

    public var id: String { rawValue }
}

public enum LiveTVPrototypeSort: String, CaseIterable, Identifiable, Sendable {
    case channelNumber
    case name

    public var id: String { rawValue }
}

public enum LiveTVPrototypeDataError: Error {
    case duplicateChannelID
    case invalidProgram
}

public enum LiveTVPreferencesIssue: Equatable, Sendable {
    case loadFailed
    case saveFailed
}

public struct LiveTVPrototypeChannel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let name: String
    public let category: String
    public let symbol: String
    public let accent: Int
    public let source: LiveTVPrototypeSource
    public let tagline: String
    public let logoURL: URL?
    public let streamURL: URL?
    public let logoNeedsDarkBackground: Bool
    public let guideID: String?
    public let guideName: String?
    public let httpHeaders: [String: String]
    public let playlistSourceID: String?
    public let language: String?
    public let country: String?
    public let groups: [String]?
    public var languages: [String] { Self.metadataValues(language) }
    public var countries: [String] { Self.metadataValues(country) }
    public var categories: [String] { groups?.isEmpty == false ? (groups ?? []) : [category] }
    public var configuredSourceID: String? { playlistSourceID }

    public init(
        id: String,
        number: Int,
        name: String,
        category: String,
        symbol: String,
        accent: Int,
        source: LiveTVPrototypeSource,
        tagline: String,
        logoURL: URL? = nil,
        streamURL: URL? = nil,
        logoNeedsDarkBackground: Bool = false,
        guideID: String? = nil,
        guideName: String? = nil,
        httpHeaders: [String: String] = [:],
        playlistSourceID: String? = nil,
        configuredSourceID: String? = nil,
        language: String? = nil,
        country: String? = nil,
        groups: [String]? = nil
    ) {
        precondition((0...5).contains(accent), "Live TV fixture accent must be between 0 and 5.")
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.symbol = symbol
        self.accent = accent
        self.source = source
        self.tagline = tagline
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.logoNeedsDarkBackground = logoNeedsDarkBackground
        self.guideID = guideID
        self.guideName = guideName
        self.httpHeaders = httpHeaders
        self.playlistSourceID = configuredSourceID ?? playlistSourceID
        self.language = language
        self.country = country
        self.groups = groups
    }

    private static func metadataValues(_ value: String?) -> [String] {
        (value ?? "").split { $0 == ";" || $0 == "," || $0 == "/" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct LiveTVPrototypeProgram: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let channelID: String
    public let title: String
    public let subtitle: String
    public let start: Date
    public let end: Date
    public let details: LiveTVProgramDetails?

    public init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String,
        start: Date,
        end: Date,
        details: LiveTVProgramDetails? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.start = start
        self.end = end
        self.details = details
    }

    public func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return date < start ? 0 : 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}

public struct LiveTVProgramDetails: Codable, Equatable, Sendable {
    public var description: String?
    public var episode: String?
    public var categories: [String]
    public var languages: [String]
    public var rating: String?
    public var artworkURL: URL?
    public var endWasInferred: Bool

    public init(
        description: String? = nil, episode: String? = nil, categories: [String] = [],
        languages: [String] = [], rating: String? = nil, artworkURL: URL? = nil,
        endWasInferred: Bool = false
    ) {
        self.description = description
        self.episode = episode
        self.categories = categories
        self.languages = languages
        self.rating = rating
        self.artworkURL = artworkURL
        self.endWasInferred = endWasInferred
    }
}

@MainActor
@Observable
private final class LiveTVPrototypePreferencesState {
    var recentChannelIDs: [String] = []
    var favoriteIDs: Set<String> = []
    var favoriteMultiviews: [LiveTVMultiviewFavorite] = []
    var favoriteOrder: [String] = []
    var favoriteChannels: [LiveTVHiddenChannel] = []
    var channelOverrides: [String: LiveTVChannelMetadataOverride] = [:]
    var hiddenChannels: [LiveTVHiddenChannel] = []
    var issue: LiveTVPreferencesIssue?
}

@MainActor
@Observable
private final class LiveTVPrototypeGuideState {
    var programs: [String: [LiveTVPrototypeProgram]] = [:]
    var knownChannelIDs: Set<String> = []
}

@MainActor
@Observable
public final class LiveTVPrototypeModel {
    public var favoriteMultiviews: [LiveTVMultiviewFavorite] { preferences.favoriteMultiviews }

    @discardableResult
    public func saveMultiviewFavorite(_ favorite: LiveTVMultiviewFavorite) -> Bool {
        guard favorite.isValid else {
            preferencesIssue = .saveFailed
            return false
        }
        var updated = favoriteMultiviews
        updated.removeAll { $0.id == favorite.id }
        updated.append(favorite)
        return persistMultiviewFavorites(updated)
    }

    @discardableResult
    public func removeMultiviewFavorite(_ id: String) -> Bool {
        persistMultiviewFavorites(favoriteMultiviews.filter { $0.id != id })
    }

    private func persistMultiviewFavorites(_ favorites: [LiveTVMultiviewFavorite]) -> Bool {
        persistPreferences(LiveTVPreferences(
            favoriteIDs: favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browsePreferences, favoriteMultiviews: favorites))
    }

    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var category: String? {
        didSet {
            guard category != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var source: LiveTVPrototypeSource? {
        didSet {
            guard source != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var language: String? {
        didSet { if language != oldValue { refreshVisibleChannels() } }
    }
    public var country: String? {
        didSet { if country != oldValue { refreshVisibleChannels() } }
    }

    public var playlistSourceID: String? {
        didSet {
            guard playlistSourceID != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var configuredSourceID: String? {
        get { playlistSourceID }
        set { playlistSourceID = newValue }
    }

    public var favoritesOnly = false {
        didSet {
            guard favoritesOnly != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var guideOnly = false {
        didSet {
            guard guideOnly != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var sort: LiveTVPrototypeSort = .channelNumber {
        didSet {
            guard sort != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var scenario: LiveTVPrototypeScenario {
        didSet {
            if guideOnly && scenario != oldValue { refreshVisibleChannels() }
        }
    }

    public var isLargeCatalog: Bool {
        didSet {
            guard isLargeCatalog != oldValue else { return }
            rebuildCatalog()
        }
    }

    public private(set) var visibleChannels: [LiveTVPrototypeChannel] = []
    public private(set) var guideChannels: [LiveTVGuideChannel] = []
    @ObservationIgnored private var orderedGuideRowIDs: [LiveTVGuideRowID] = []
    @ObservationIgnored private var guideEntries: [LiveTVGuideRowID: LiveTVGuideChannel] = [:]
    public var guideRowIDs: [LiveTVGuideRowID] {
        _ = guideChannels
        return orderedGuideRowIDs
    }

    public func guideEntry(for row: LiveTVGuideRowID) -> LiveTVGuideChannel? {
        _ = guideChannels
        return guideEntries[row]
    }
    private let preferences = LiveTVPrototypePreferencesState()
    public private(set) var recentChannelIDs: [String] {
        get { preferences.recentChannelIDs }
        set { preferences.recentChannelIDs = newValue }
    }
    public private(set) var channels: [LiveTVPrototypeChannel] = []
    public private(set) var catalogRevision = 0
    public private(set) var favoriteIDs: Set<String> {
        get { preferences.favoriteIDs }
        set { preferences.favoriteIDs = newValue }
    }
    public private(set) var favoriteOrder: [String] {
        get { preferences.favoriteOrder }
        set { preferences.favoriteOrder = newValue }
    }
    public private(set) var favoriteChannels: [LiveTVHiddenChannel] {
        get { preferences.favoriteChannels }
        set { preferences.favoriteChannels = newValue }
    }
    public private(set) var channelOverrides: [String: LiveTVChannelMetadataOverride] {
        get { preferences.channelOverrides }
        set { preferences.channelOverrides = newValue }
    }
    public var unavailableFavorites: [LiveTVHiddenChannel] {
        let saved = Dictionary(uniqueKeysWithValues: favoriteChannels.map { ($0.id, $0) })
        return favoriteOrder.filter { channelsByID[$0] == nil }.map { id in
            saved[id] ?? LiveTVHiddenChannel(id: id, name: "Unavailable channel")
        }
    }
    public var programmeSearchChannelIDs: Set<String> {
        let hidden = effectiveHiddenChannelIDs
        return Set(channels.filter {
            !hidden.contains($0.id)
                && (category == nil || $0.categories.contains { Self.normalized($0) == category.map(Self.normalized) })
                && (source == nil || $0.source == source)
                && (playlistSourceID == nil || $0.playlistSourceID == playlistSourceID)
                && (language == nil || $0.languages.contains { Self.normalized($0) == language.map(Self.normalized) })
                && (country == nil || $0.countries.contains { Self.normalized($0) == country.map(Self.normalized) })
                && (!favoritesOnly || favoriteIDs.contains($0.id))
                && (!guideOnly || hasGuide(for: $0))
        }.map(\.id))
    }
    public private(set) var languages: [String] = []
    public private(set) var countries: [String] = []
    public private(set) var hiddenChannels: [LiveTVHiddenChannel] {
        get { preferences.hiddenChannels }
        set { preferences.hiddenChannels = newValue }
    }
    public var hiddenChannelIDs: Set<String> { Set(hiddenChannels.map(\.id)) }
    public private(set) var scanHiddenChannelIDs: Set<String> = []
    public var effectiveHiddenChannelIDs: Set<String> { hiddenChannelIDs.union(scanHiddenChannelIDs) }

    public func setScanHiddenChannelIDs(_ ids: Set<String>) {
        guard scanHiddenChannelIDs != ids else { return }
        scanHiddenChannelIDs = ids
        catalogRevision &+= 1
        refreshCategories()
        refreshVisibleChannels()
    }
    /// Source authorization is enforced when admitting the catalog. Picker results
    /// exclude hidden channels but never depend on the main guide's browse filters.
    public var unhiddenCatalogChannels: [LiveTVPrototypeChannel] {
        let hidden = effectiveHiddenChannelIDs
        return channels.filter { !hidden.contains($0.id) }
    }

    /// Apply the current profile's IPTV approval and optional scan exclusions.
    /// Server/library catalogs must already have passed their provider authorization.
    public func catalogChannels(
        authorizedBy authorization: LiveTVSourceAuthorization, excluding additionalHiddenIDs: Set<String> = []
    ) -> [LiveTVPrototypeChannel] {
        unhiddenCatalogChannels.filter {
            !additionalHiddenIDs.contains($0.id)
                && ($0.source != .iptv || authorization.allowsPlaylist($0.playlistSourceID))
        }
    }

    public private(set) var preferencesIssue: LiveTVPreferencesIssue? {
        get { preferences.issue }
        set { preferences.issue = newValue }
    }
    public private(set) var now: Date
    public private(set) var categories: [String] = []

    public private(set) var playingChannelID: String?
    public private(set) var previousChannelID: String?
    public private(set) var isPaused = false
    public private(set) var behindLiveSeconds: TimeInterval = 0
    public var simulateTunerBusy = false
    public private(set) var tuneFailed = false

    @ObservationIgnored private var channelsByID: [String: LiveTVPrototypeChannel] = [:]
    @ObservationIgnored private var channelOrdinalsByID: [String: Int] = [:]
    @ObservationIgnored private var isBatchingFilterChanges = false
    @ObservationIgnored private var suppliedChannels: [LiveTVPrototypeChannel]?
    @ObservationIgnored private let preferencesStore: (any LiveTVPreferencesStoring)?
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var pendingPreferences: LiveTVPreferences?
    @ObservationIgnored private var savedBrowse = LiveTVBrowsePreferences()
    private let guideState = LiveTVPrototypeGuideState()
    private var importedPrograms: [String: [LiveTVPrototypeProgram]] {
        get { guideState.programs }
        set { guideState.programs = newValue }
    }
    private var knownGuideChannelIDs: Set<String> {
        get { guideState.knownChannelIDs }
        set { guideState.knownChannelIDs = newValue }
    }

    public var usesPublicStreams: Bool { suppliedChannels != nil }
    public var guideChannelCount: Int { importedPrograms.count }

    public init(
        now: Date = Date(timeIntervalSince1970: 1_788_719_400),
        scenario: LiveTVPrototypeScenario = .mixedGuide,
        isLargeCatalog: Bool = false,
        channels: [LiveTVPrototypeChannel]? = nil,
        preferencesStore: (any LiveTVPreferencesStoring)? = nil
    ) {
        self.now = now
        self.scenario = scenario
        self.isLargeCatalog = isLargeCatalog
        self.preferencesStore = preferencesStore
        suppliedChannels = channels
        favoriteIDs = channels == nil && preferencesStore == nil ? Set((1...5).map(Self.channelID)) : []
        if preferencesStore != nil { loadPreferences() }
        rebuildCatalog()
    }

    public func replaceChannels(_ channels: [LiveTVPrototypeChannel]) throws {
        guard Set(channels.map(\.id)).count == channels.count else {
            throw LiveTVPrototypeDataError.duplicateChannelID
        }
        suppliedChannels = channels
        let ids = Set(channels.map(\.id))
        importedPrograms = importedPrograms.filter { ids.contains($0.key) }
        rebuildCatalog()
    }

    public func replacePrograms(_ programs: [LiveTVPrototypeProgram]) throws {
        guard Set(programs.map(\.id)).count == programs.count,
              programs.allSatisfy({
                  channelsByID[$0.channelID] != nil
                      && $0.start.timeIntervalSince1970.isFinite
                      && $0.end.timeIntervalSince1970.isFinite
                      && $0.start < $0.end
              }) else {
            throw LiveTVPrototypeDataError.invalidProgram
        }

        let updatedPrograms = Dictionary(grouping: programs, by: \.channelID)
            .mapValues { values in
                values.sorted { lhs, rhs in
                    lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
                }
            }
        guard importedPrograms != updatedPrograms else { return }
        importedPrograms = updatedPrograms
        catalogRevision &+= 1
        if guideOnly { refreshVisibleChannels() }
    }

    public func setKnownGuideChannels(_ ids: Set<String>) {
        guard knownGuideChannelIDs != ids else { return }
        knownGuideChannelIDs = ids
        catalogRevision &+= 1
        if guideOnly { refreshVisibleChannels() }
    }

    public func replaceCatalog(channels: [LiveTVPrototypeChannel], programs: [LiveTVPrototypeProgram]) throws {
        if suppliedChannels == channels {
            try replacePrograms(programs)
            return
        }
        let ids = Set(channels.map(\.id))
        guard ids.count == channels.count else { throw LiveTVPrototypeDataError.duplicateChannelID }
        guard Set(programs.map(\.id)).count == programs.count, programs.allSatisfy({
            ids.contains($0.channelID) && $0.start.timeIntervalSince1970.isFinite
                && $0.end.timeIntervalSince1970.isFinite && $0.start < $0.end
        }) else { throw LiveTVPrototypeDataError.invalidProgram }
        suppliedChannels = channels
        importedPrograms = Dictionary(grouping: programs, by: \.channelID).mapValues {
            $0.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        }
        rebuildCatalog()
    }

    public func synchronizeClock(to date: Date = Date()) {
        now = date
    }

    func cachedNativePrograms(
        matching matcher: LiveTVProgramSearchMatcher, range: DateInterval, limit: Int,
        allowedChannelIDs: Set<String>
    ) -> [LiveTVPrototypeProgram] {
        var result = LiveTVProgramSearchResults(limit: limit)
        for id in allowedChannelIDs {
            guard let channel = channelsByID[id], channel.source != .iptv else { continue }
            for program in importedPrograms[id] ?? [] where
                program.start < range.end && program.end > range.start && matcher.matches(program.title) {
                result.insert(program)
            }
        }
        return result.sorted
    }

    public func channel(id: String) -> LiveTVPrototypeChannel? {
        channelsByID[id]
    }

    public func guideRow(for channelID: String, preferring section: LiveTVGuideSection? = nil) -> LiveTVGuideRowID? {
        if let section, let entry = guideEntry(for: .init(channelID: channelID, section: section)) {
            return entry.id
        }
        return guideEntry(for: .init(channelID: channelID, section: .channels))?.id
            ?? guideEntry(for: .init(channelID: channelID, section: .recent))?.id
            ?? guideEntry(for: .init(channelID: channelID, section: .favorites))?.id
    }

    public func toggleFavorite(_ id: String) {
        var favorites = favoriteIDs
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: favorites,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder + (favorites.contains(id) ? [id] : []),
            favoriteChannels: favoriteChannels + (channelsByID[id].map { [.init(id: id, name: $0.name)] } ?? []),
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews
        )) else { return }
        if favoritesOnly {
            refreshVisibleChannels()
        } else {
            refreshGuideChannels()
        }
    }

    /// Called only after deliberate watching has presented live video.
    /// A stale-source confirmation is rejected without changing the lineup.
    @discardableResult
    public func recordWatched(_ id: String) -> Bool {
        guard id == playingChannelID, channelsByID[id] != nil else { return false }
        guard recentChannelIDs.first != id else { return true }
        let recent = [id] + recentChannelIDs.filter { $0 != id }.prefix(2)
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: favoriteIDs,
            recentChannelIDs: recent,
            hiddenChannels: hiddenChannels, favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels,
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews
        )) else { return false }
        refreshGuideChannels()
        return true
    }

    /// Hides every rendered occurrence of a channel while retaining its
    /// favorite, recent, guide, and source records for later restoration.
    @discardableResult
    public func hideChannel(_ channel: LiveTVPrototypeChannel) -> Bool {
        let current = currentPreferences
        guard !current.hiddenChannelIDs.contains(channel.id) else { return true }
        guard persistPreferences(current.hidingChannel(id: channel.id, name: channel.name)) else {
            return false
        }
        refreshCategories()
        refreshVisibleChannels()
        return true
    }

    public func dismissPreferencesIssue() {
        preferencesIssue = nil
    }

    @discardableResult
    public func migrateChannelIDs(_ migration: [String: String]) -> Bool {
        let migrated = currentPreferences.migratingChannelIDs(migration)
        guard migrated != currentPreferences else { return true }
        guard persistPreferences(migrated) else { return false }
        refreshVisibleChannels()
        return true
    }

    @discardableResult
    public func setFavoriteOrder(_ ids: [String]) -> Bool {
        guard Set(ids) == favoriteIDs, ids.count == favoriteIDs.count else { return false }
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: ids, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browsePreferences, favoriteMultiviews: favoriteMultiviews
        )) else { return false }
        refreshGuideChannels()
        return true
    }

    @discardableResult
    public func setMetadataOverride(_ value: LiveTVChannelMetadataOverride?, channelID: String) -> Bool {
        if let value {
            guard [value.name, value.category, value.language, value.country].compactMap({ $0 }).allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
            }) else { return false }
        }
        var updated = channelOverrides
        updated[channelID] = value
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: updated,
            browse: browsePreferences, favoriteMultiviews: favoriteMultiviews
        )) else { return false }
        rebuildCatalog()
        return true
    }

    public func retryPreferences() {
        reloadPreferences()
    }

    /// Reloads profile-scoped preferences after Settings may have restored
    /// channels. A failed pending mutation is retried first so re-entry never
    /// silently discards it.
    public func reloadPreferences() {
        if let pendingPreferences, let preferencesStore {
            do {
                let latest = try preferencesStore.load()
                _ = persistPreferences(rebasing(pendingPreferences, onto: latest), retrying: true)
            } catch {
                preferencesIssue = .loadFailed
            }
        } else {
            loadPreferences()
        }
        rebuildCatalog()
    }

    private func loadPreferences() {
        guard let preferencesStore else { return }
        do {
            let preferences = try preferencesStore.load()
            favoriteIDs = preferences.favoriteIDs
            self.preferences.favoriteMultiviews = preferences.favoriteMultiviews
            recentChannelIDs = preferences.recentChannelIDs
            hiddenChannels = preferences.hiddenChannels
            favoriteOrder = preferences.favoriteOrder
            favoriteChannels = preferences.favoriteChannels
            channelOverrides = preferences.channelOverrides
            isBatchingFilterChanges = true
            category = preferences.browse.category
            language = preferences.browse.language
            country = preferences.browse.country
            source = preferences.browse.sourceType.flatMap(LiveTVPrototypeSource.init(rawValue:))
            playlistSourceID = preferences.browse.configuredSourceID
            sort = LiveTVPrototypeSort(rawValue: preferences.browse.sort) ?? .channelNumber
            favoritesOnly = preferences.browse.favoritesOnly
            guideOnly = preferences.browse.guideOnly
            savedBrowse = preferences.browse
            isBatchingFilterChanges = false
            preferencesLoaded = true
            preferencesIssue = nil
        } catch {
            preferencesIssue = .loadFailed
        }
    }

    private func persistPreferences(_ preferences: LiveTVPreferences, retrying: Bool = false) -> Bool {
        if let preferencesStore {
            guard preferencesLoaded else {
                preferencesIssue = .loadFailed
                return false
            }
            if !retrying { pendingPreferences = preferences }
            do {
                try preferencesStore.save(preferences)
            } catch {
                preferencesIssue = .saveFailed
                return false
            }
        }
        favoriteIDs = preferences.favoriteIDs
        self.preferences.favoriteMultiviews = preferences.favoriteMultiviews
        recentChannelIDs = preferences.recentChannelIDs
        hiddenChannels = preferences.hiddenChannels
        favoriteOrder = preferences.favoriteOrder
        favoriteChannels = preferences.favoriteChannels
        channelOverrides = preferences.channelOverrides
        savedBrowse = preferences.browse
        preferencesIssue = nil
        pendingPreferences = nil
        return true
    }

    private var currentPreferences: LiveTVPreferences {
        LiveTVPreferences(
            favoriteIDs: favoriteIDs,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels, favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels,
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews
        )
    }

    private var browsePreferences: LiveTVBrowsePreferences {
        .init(
            category: category, language: language, country: country, sourceType: source?.rawValue,
            configuredSourceID: playlistSourceID, sort: sort.rawValue, favoritesOnly: favoritesOnly, guideOnly: guideOnly
        )
    }

    private func rebasing(_ pending: LiveTVPreferences, onto latest: LiveTVPreferences) -> LiveTVPreferences {
        let base = currentPreferences
        let favorites = latest.favoriteIDs
            .subtracting(base.favoriteIDs.subtracting(pending.favoriteIDs))
            .union(pending.favoriteIDs.subtracting(base.favoriteIDs))
        let removedHidden = base.hiddenChannelIDs.subtracting(pending.hiddenChannelIDs)
        let knownHidden = base.hiddenChannelIDs.union(latest.hiddenChannelIDs)
        let hidden = latest.hiddenChannels.filter { !removedHidden.contains($0.id) }
            + pending.hiddenChannels.filter { !knownHidden.contains($0.id) }
        var recent = latest.recentChannelIDs
        if pending.recentChannelIDs != base.recentChannelIDs, let watched = pending.recentChannelIDs.first {
            recent = [watched] + recent.filter { $0 != watched }
        }
        let removedMultiviews = Set(base.favoriteMultiviews.map(\.id)).subtracting(pending.favoriteMultiviews.map(\.id))
        let changedMultiviews = pending.favoriteMultiviews.filter { item in
            base.favoriteMultiviews.first(where: { $0.id == item.id }) != item
        }
        let changedIDs = Set(changedMultiviews.map(\.id))
        let multiviews = latest.favoriteMultiviews.filter {
            !removedMultiviews.contains($0.id) && !changedIDs.contains($0.id)
        } + changedMultiviews
        // Retry only the failed changes; Settings may have restored channels meanwhile.
        return LiveTVPreferences(
            favoriteIDs: favorites, recentChannelIDs: recent, hiddenChannels: hidden,
            favoriteOrder: pending.favoriteOrder == base.favoriteOrder ? latest.favoriteOrder : pending.favoriteOrder,
            favoriteChannels: latest.favoriteChannels + pending.favoriteChannels,
            channelOverrides: pending.channelOverrides == base.channelOverrides ? latest.channelOverrides : pending.channelOverrides,
            browse: pending.browse == base.browse ? latest.browse : pending.browse,
            favoriteMultiviews: multiviews
        )
    }

    public func resetFilters() {
        isBatchingFilterChanges = true
        query = ""
        category = nil
        source = nil
        language = nil
        country = nil
        playlistSourceID = nil
        favoritesOnly = false
        guideOnly = false
        isBatchingFilterChanges = false
        refreshVisibleChannels()
    }

    public func currentProgram(for channelID: String) -> LiveTVPrototypeProgram? {
        programs(for: channelID, from: now, hours: 1).first {
            $0.start <= now && now < $0.end
        }
    }

    public func programs(
        for channelID: String,
        from date: Date,
        hours: Int = 3
    ) -> [LiveTVPrototypeProgram] {
        guard hours > 0,
              let channel = channelsByID[channelID],
              hasGuide(for: channel)
        else { return [] }

        let boundedHours = min(hours, 24)
        let requestedEnd = date.addingTimeInterval(TimeInterval(boundedHours) * 3_600)
        if usesPublicStreams {
            return (importedPrograms[channelID] ?? []).filter {
                $0.start < requestedEnd && $0.end > date
            }
        }
        let duration = programDuration(for: channelID)
        var slotStartSeconds = floor(date.timeIntervalSince1970 / duration) * duration
        var result: [LiveTVPrototypeProgram] = []
        result.reserveCapacity(
            Int(ceil((requestedEnd.timeIntervalSince1970 - slotStartSeconds) / duration))
        )

        while slotStartSeconds < requestedEnd.timeIntervalSince1970 {
            let start = Date(timeIntervalSince1970: slotStartSeconds)
            let end = start.addingTimeInterval(duration)
            result.append(program(for: channel, start: start, end: end))
            slotStartSeconds += duration
        }
        return result
    }

    public func advanceClock(by interval: TimeInterval) {
        precondition(interval.isFinite && interval >= 0, "Live TV prototype clock only advances forward.")
        now = now.addingTimeInterval(interval)
        if isPaused, playingChannelID != nil {
            behindLiveSeconds += interval
        }
    }

    /// Invalid fixture IDs and simulated tuner contention report through
    /// `tuneFailed`; neither condition changes the current stream.
    public func tune(_ id: String) {
        guard channelsByID[id] != nil else {
            tuneFailed = true
            return
        }
        if playingChannelID == id {
            tuneFailed = false
            return
        }
        guard !simulateTunerBusy else {
            tuneFailed = true
            return
        }

        previousChannelID = playingChannelID
        playingChannelID = id
        isPaused = false
        behindLiveSeconds = 0
        tuneFailed = false
    }

    public func stop() {
        playingChannelID = nil
        previousChannelID = nil
        isPaused = false
        behindLiveSeconds = 0
        tuneFailed = false
    }

    public func togglePause() {
        guard playingChannelID != nil else { return }
        isPaused.toggle()
    }

    public func goLive() {
        guard playingChannelID != nil else { return }
        isPaused = false
        behindLiveSeconds = 0
    }

    public func tunePrevious() {
        guard let previousChannelID else { return }
        tune(previousChannelID)
    }

    public func clearTuneFailure() {
        tuneFailed = false
    }

    private func rebuildCatalog() {
        catalogRevision &+= 1
        if let suppliedChannels {
            let count = suppliedChannels.isEmpty ? 0 : (isLargeCatalog ? 5_000 : suppliedChannels.count)
            channels = (0..<count).map { index in
                let channel = suppliedChannels[index % suppliedChannels.count]
                let copy = index / suppliedChannels.count
                guard copy > 0 else { return channel }
                return LiveTVPrototypeChannel(
                    id: "\(channel.id)-copy-\(copy)", number: index + 1,
                    name: "\(channel.name) (copy \(copy + 1))", category: channel.category,
                    symbol: channel.symbol, accent: channel.accent, source: channel.source,
                    tagline: channel.tagline, logoURL: channel.logoURL, streamURL: channel.streamURL,
                    logoNeedsDarkBackground: channel.logoNeedsDarkBackground,
                    guideID: channel.guideID, guideName: channel.guideName,
                    httpHeaders: channel.httpHeaders,
                    playlistSourceID: channel.playlistSourceID, language: channel.language, country: channel.country,
                    groups: channel.groups
                )
            }
        } else {
            let count = isLargeCatalog ? 5_000 : Self.baseStations.count
            channels = (1...count).map(Self.makeChannel)
        }
        channels = channels.map { channel in
            guard let value = channelOverrides[channel.id] else { return channel }
            return LiveTVPrototypeChannel(
                id: channel.id, number: channel.number, name: value.name ?? channel.name,
                category: value.category ?? channel.category, symbol: channel.symbol, accent: channel.accent,
                source: channel.source, tagline: channel.tagline, logoURL: channel.logoURL,
                streamURL: channel.streamURL, logoNeedsDarkBackground: channel.logoNeedsDarkBackground,
                guideID: channel.guideID, guideName: channel.guideName, httpHeaders: channel.httpHeaders,
                playlistSourceID: channel.playlistSourceID, language: value.language ?? channel.language,
                country: value.country ?? channel.country, groups: value.category.map { [$0] } ?? channel.groups
            )
        }
        channelsByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        channelOrdinalsByID = Dictionary(
            uniqueKeysWithValues: channels.enumerated().map { ($0.element.id, $0.offset + 1) }
        )
        refreshCategories()
        if let playingChannelID, channelsByID[playingChannelID] == nil {
            stop()
        } else if let previousChannelID, channelsByID[previousChannelID] == nil {
            self.previousChannelID = nil
        }
        refreshVisibleChannels()
    }

    private func refreshVisibleChannels() {
        guard !isBatchingFilterChanges else { return }
        if preferencesLoaded, savedBrowse != browsePreferences {
            _ = persistPreferences(currentPreferences)
        }
        let normalizedQuery = Self.normalized(query)
        let selectedCategory = category.map(Self.normalized)
        let hiddenChannelIDs = effectiveHiddenChannelIDs

        visibleChannels = channels.compactMap { channel -> (LiveTVPrototypeChannel, Int)? in
            guard !hiddenChannelIDs.contains(channel.id),
                  selectedCategory == nil || channel.categories.contains(where: { Self.normalized($0) == selectedCategory }),
                  source == nil || channel.source == source,
                  language == nil || channel.languages.contains(where: { Self.normalized($0) == language.map(Self.normalized) }),
                  country == nil || channel.countries.contains(where: { Self.normalized($0) == country.map(Self.normalized) }),
                  playlistSourceID == nil || channel.playlistSourceID == playlistSourceID,
                  !favoritesOnly || favoriteIDs.contains(channel.id),
                  !guideOnly || hasGuide(for: channel)
            else { return nil }

            guard !normalizedQuery.isEmpty else { return (channel, 0) }
            let number = String(channel.number)
            if number == normalizedQuery {
                return (channel, 0)
            }
            let fields = [
                Self.normalized(channel.name),
                number,
                Self.normalized(channel.categories.joined(separator: " ")),
                Self.normalized(channel.source.rawValue)
            ]
            if fields.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                return (channel, 1)
            }
            if fields.contains(where: { $0.contains(normalizedQuery) }) {
                return (channel, 2)
            }
            return nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            return channelsAreOrdered(lhs.0, before: rhs.0)
        }
        .map(\.0)
        refreshGuideChannels()
    }

    private func refreshCategories() {
        let hiddenChannelIDs = effectiveHiddenChannelIDs
        categories = Set(
            channels.lazy
                .filter { !hiddenChannelIDs.contains($0.id) }
                .flatMap(\.categories)
        ).sorted {
            Self.normalized($0) < Self.normalized($1)
        }
        languages = Set(unhiddenCatalogChannels.flatMap(\.languages)).sorted()
        countries = Set(unhiddenCatalogChannels.flatMap(\.countries)).sorted()
    }

    private func refreshGuideChannels() {
        let visibleByID = Dictionary(uniqueKeysWithValues: visibleChannels.map { ($0.id, $0) })
        let recent = recentChannelIDs.compactMap { visibleByID[$0] }
        let orderedIDs = Set(favoriteOrder)
        let favorites = favoriteOrder.compactMap { visibleByID[$0] }
            + visibleChannels.filter { favoriteIDs.contains($0.id) && !orderedIDs.contains($0.id) }
        let groups: [(LiveTVGuideSection, [LiveTVPrototypeChannel])] = [
            (.recent, recent), (.favorites, favorites), (.channels, visibleChannels)
        ]
        let updated = groups.flatMap { section, channels in
            channels.enumerated().map { index, channel in
                LiveTVGuideChannel(channel: channel, section: section, startsSection: index == 0)
            }
        }
        orderedGuideRowIDs = updated.map(\.id)
        guideEntries = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        guideChannels = updated
    }

    private func channelsAreOrdered(
        _ lhs: LiveTVPrototypeChannel,
        before rhs: LiveTVPrototypeChannel
    ) -> Bool {
        switch sort {
        case .channelNumber:
            if lhs.number != rhs.number {
                return lhs.number < rhs.number
            }
        case .name:
            let lhsName = Self.normalized(lhs.name)
            let rhsName = Self.normalized(rhs.name)
            if lhsName != rhsName {
                return lhsName < rhsName
            }
        }
        return lhs.id < rhs.id
    }

    private func hasGuide(for channel: LiveTVPrototypeChannel) -> Bool {
        // Imported channels use only provider listings, never synthetic schedules.
        if usesPublicStreams {
            return knownGuideChannelIDs.contains(channel.id) || importedPrograms[channel.id]?.isEmpty == false
        }
        switch scenario {
        case .noGuide, .failedGuide:
            return false
        case .fullGuide, .staleGuide:
            return true
        case .mixedGuide:
            let ordinal = channelOrdinalsByID[channel.id] ?? 0
            return channel.source == .plozz || ordinal.isMultiple(of: 3)
        }
    }

    private func programDuration(for channelID: String) -> TimeInterval {
        let ordinal = channelOrdinalsByID[channelID] ?? 1
        return ordinal.isMultiple(of: 4) ? 3_600 : 1_800
    }

    private func program(
        for channel: LiveTVPrototypeChannel,
        start: Date,
        end: Date
    ) -> LiveTVPrototypeProgram {
        let duration = end.timeIntervalSince(start)
        let slot = Int(start.timeIntervalSince1970 / duration)
        let ordinal = channelOrdinalsByID[channel.id] ?? 1
        let fixture = Self.programFixtures[Self.positiveModulo(slot + ordinal, Self.programFixtures.count)]
        let startSeconds = Int(start.timeIntervalSince1970)
        return LiveTVPrototypeProgram(
            id: "\(channel.id)-\(startSeconds)-\(Int(duration))",
            channelID: channel.id,
            title: fixture.title,
            subtitle: fixture.subtitle,
            start: start,
            end: end
        )
    }

    private static func makeChannel(ordinal: Int) -> LiveTVPrototypeChannel {
        let baseIndex = (ordinal - 1) % baseStations.count
        let variant = (ordinal - 1) / baseStations.count + 1
        let station = baseStations[baseIndex]
        let name = variant == 1 ? station.name : "\(station.name) \(variant)"
        let tagline = variant == 1
            ? station.tagline
            : "\(station.tagline) Catalog variant \(variant)."
        return LiveTVPrototypeChannel(
            id: channelID(ordinal),
            number: ordinal,
            name: name,
            category: station.category,
            symbol: station.symbol,
            accent: (station.accent + variant - 1) % 6,
            source: station.source,
            tagline: tagline
        )
    }

    private static func channelID(_ ordinal: Int) -> String {
        String(format: "live-tv-%04d", ordinal)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private struct StationFixture {
        let name: String
        let category: String
        let symbol: String
        let accent: Int
        let source: LiveTVPrototypeSource
        let tagline: String
    }

    private static let baseStations: [StationFixture] = [
        .init(name: "World Desk", category: "News", symbol: "globe", accent: 0, source: .iptv, tagline: "Headlines from a fictional global newsroom."),
        .init(name: "Cinema Club", category: "Movies", symbol: "film", accent: 1, source: .jellyfin, tagline: "Made-up movies and friendly introductions."),
        .init(name: "Comedy Hour", category: "Comedy", symbol: "theatermasks", accent: 2, source: .plex, tagline: "Sketches, stand-up, and improvised mishaps."),
        .init(name: "Wild Earth", category: "Nature", symbol: "leaf", accent: 3, source: .emby, tagline: "Quiet journeys through imaginary habitats."),
        .init(name: "Arena Central", category: "Sports", symbol: "sportscourt", accent: 4, source: .plozz, tagline: "Fixture matches, recaps, and studio analysis."),
        .init(name: "Café Society", category: "Culture", symbol: "paintpalette", accent: 5, source: .iptv, tagline: "Artists and ideas meet over a fictional cup."),
        .init(name: "Storybook", category: "Kids", symbol: "book.closed", accent: 0, source: .jellyfin, tagline: "Gentle animated tales for young viewers."),
        .init(name: "Neighborhood Live", category: "Community", symbol: "person.3", accent: 1, source: .plex, tagline: "Local events from an entirely invented town."),
        .init(name: "Science Window", category: "Science", symbol: "atom", accent: 2, source: .emby, tagline: "Simple experiments and curious questions."),
        .init(name: "Retro Rewind", category: "Classics", symbol: "clock.arrow.circlepath", accent: 3, source: .plozz, tagline: "Freshly fictional favorites from decades past."),
        .init(name: "Kitchen Table", category: "Food", symbol: "fork.knife", accent: 4, source: .iptv, tagline: "Comfort cooking with pantry-sized challenges."),
        .init(name: "Road Atlas", category: "Travel", symbol: "map", accent: 5, source: .jellyfin, tagline: "Scenic routes through places that never existed."),
        .init(name: "Night Signals", category: "Music", symbol: "music.note", accent: 0, source: .plex, tagline: "Late sets from original imaginary performers."),
        .init(name: "Market Brief", category: "Business", symbol: "chart.line.uptrend.xyaxis", accent: 1, source: .emby, tagline: "Demo markets, explainers, and fictional figures."),
        .init(name: "Weather Watch", category: "Weather", symbol: "cloud.sun", accent: 2, source: .plozz, tagline: "Forecasts for the prototype coast."),
        .init(name: "Open Stage", category: "Culture", symbol: "music.mic", accent: 3, source: .iptv, tagline: "New plays and performances from a demo venue."),
        .init(name: "Game Day Extra", category: "Sports", symbol: "trophy", accent: 4, source: .jellyfin, tagline: "More fictional fixtures and postgame conversation."),
        .init(name: "Documentary Room", category: "Documentary", symbol: "doc.text.image", accent: 5, source: .plex, tagline: "Original short documentaries about imagined subjects."),
        .init(name: "Morning Mix", category: "Lifestyle", symbol: "sun.max", accent: 0, source: .emby, tagline: "A bright fixture blend of guests and ideas."),
        .init(name: "Pixel Play", category: "Gaming", symbol: "gamecontroller", accent: 1, source: .plozz, tagline: "Invented tournaments and relaxed game talk."),
        .init(name: "History Vault", category: "History", symbol: "building.columns", accent: 2, source: .iptv, tagline: "Stories recovered from a fictional archive."),
        .init(name: "Makers Workshop", category: "Education", symbol: "hammer", accent: 3, source: .jellyfin, tagline: "Small builds demonstrated one careful step at a time."),
        .init(name: "Cozy Mysteries", category: "Drama", symbol: "sparkles.tv", accent: 4, source: .plex, tagline: "Low-stakes cases in a made-up village."),
        .init(name: "Late Night Shorts", category: "Comedy", symbol: "rectangle.stack", accent: 5, source: .emby, tagline: "Compact comedies made for this fixture."),
        .init(name: "Ocean View", category: "Nature", symbol: "water.waves", accent: 0, source: .plozz, tagline: "Calm expeditions across imaginary seas."),
        .init(name: "Festival Screen", category: "Movies", symbol: "ticket", accent: 1, source: .iptv, tagline: "Original festival selections and filmmaker chats."),
        .init(name: "Junior Lab", category: "Kids", symbol: "testtube.2", accent: 2, source: .jellyfin, tagline: "Safe science puzzles for curious young minds."),
        .init(name: "City Council", category: "Civic", symbol: "building.2", accent: 3, source: .plex, tagline: "Proceedings from a purely fictional municipality."),
        .init(name: "Quiet Channel", category: "Uncategorized", symbol: "questionmark.square", accent: 4, source: .emby, tagline: "A useful home for uncategorized demo programming."),
        .init(name: "Plozz Preview", category: "Entertainment", symbol: "play.tv", accent: 5, source: .plozz, tagline: "Prototype highlights from across the fixture lineup.")
    ]

    private static let programFixtures: [(title: String, subtitle: String)] = [
        ("First Edition", "A concise start to the next block."),
        ("Open Window", "Stories gathered from around the demo schedule."),
        ("The Long Route", "A thoughtful trip with an unexpected turn."),
        ("Studio Session", "Original guests share work and process."),
        ("Field Notes", "Small observations from a fictional expedition."),
        ("Half-Time Table", "Friendly analysis without real-world results."),
        ("Picture House", "A short feature from the prototype archive."),
        ("Bright Ideas", "Curious questions meet practical demonstrations."),
        ("Local Color", "People and places from an invented community."),
        ("Night Shift", "A calm late block of stories and conversation."),
        ("Second Look", "Another angle on the day's fixture topics."),
        ("Next Stop", "A compact journey to a newly imagined destination.")
    ]
}
#endif
