import Foundation

public enum LibraryChannelError: Error, Equatable, Sendable {
    case invalidRecipe, invalidSnapshot, emptyCatalog, catalogTooLarge, catalogChanged
    case authorizationChanged, sourceUnavailable, snapshotUnavailable, historyExpired
    case incompatiblePlaybackMode, mediaChanged, storageFailed, unsupportedVersion
    case publicationConflict, tooManyRevisions
    case unableToJoinLive, playbackFailed

    public var message: LocalizedStringResource {
        switch self {
        case .invalidRecipe: "Choose a name, accessible libraries and valid channel rules."
        case .invalidSnapshot: "The library returned invalid programme metadata."
        case .emptyCatalog: "No playable movies or episodes match these rules."
        case .catalogTooLarge: "This channel matches too many items. Choose fewer libraries or narrower rules."
        case .catalogChanged: "The library changed while loading. Preview the channel again."
        case .authorizationChanged: "Your profile or server access changed. Choose the channel again."
        case .sourceUnavailable: "A library used by this channel isn't available to this profile."
        case .snapshotUnavailable: "This channel's saved schedule isn't available on this device."
        case .historyExpired: "This delayed programme is no longer retained. Go Live to continue."
        case .incompatiblePlaybackMode: "This file requires a server playback mode that cannot safely separate watch history. Choose another channel."
        case .mediaChanged: "The scheduled file changed or is unavailable. The next programme will start on schedule."
        case .storageFailed: "Your channel couldn't be saved. Existing channels have not been replaced."
        case .unsupportedVersion: "This channel was saved by a newer version of Plozz."
        case .publicationConflict: "This channel changed while editing. Open it again before saving."
        case .tooManyRevisions: "This channel has too many retained schedule changes. Wait until older programmes expire."
        case .unableToJoinLive: "This file couldn't join the current programme in time. Retry or choose another channel."
        case .playbackFailed: "This programme couldn't play. Retry or wait for the next scheduled programme."
        }
    }
}

public enum LibraryChannelOrdering: String, Codable, CaseIterable, Sendable {
    case roundRobin, seededShuffle, movies

    public var title: LocalizedStringResource {
        switch self {
        case .roundRobin: "Shows in episode order"
        case .seededShuffle: "Seeded shuffle"
        case .movies: "Movies"
        }
    }
}

/// Only provider-native identifiers; never URLs, access tokens or resume state.
public struct LibraryChannelLibrary: Codable, Hashable, Identifiable, Sendable {
    public let accountID: String
    public let libraryID: String
    public var id: String { "\(accountID.utf8.count):\(accountID)\(libraryID)" }

    public init(accountID: String, libraryID: String) {
        self.accountID = accountID
        self.libraryID = libraryID
    }

    static func isSafeAccountIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.|"))
        return !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public struct LibraryChannelRecipe: Codable, Equatable, Sendable {
    public var name: String
    public var symbol: String
    public var libraries: [LibraryChannelLibrary]
    public var includeTitles: [String]
    public var excludeTitles: [String]
    public var genres: [String]
    public var allowedRatings: [String]
    public var includeUnrated: Bool
    public var includesMovies: Bool
    public var includesEpisodes: Bool
    public var timeZoneID: String
    public var ordering: LibraryChannelOrdering
    public var seed: UInt64

    public init(
        name: String = "", symbol: String = "tv", libraries: [LibraryChannelLibrary] = [],
        includeTitles: [String] = [], excludeTitles: [String] = [], genres: [String] = [],
        allowedRatings: [String] = [], includeUnrated: Bool = true,
        includesMovies: Bool = true, includesEpisodes: Bool = true,
        timeZoneID: String = TimeZone.current.identifier,
        ordering: LibraryChannelOrdering = .roundRobin, seed: UInt64 = 1
    ) {
        self.name = name
        self.symbol = symbol
        self.libraries = libraries
        self.includeTitles = includeTitles
        self.excludeTitles = excludeTitles
        self.genres = genres
        self.allowedRatings = allowedRatings
        self.includeUnrated = includeUnrated
        self.includesMovies = includesMovies
        self.includesEpisodes = includesEpisodes
        self.timeZoneID = timeZoneID
        self.ordering = ordering
        self.seed = seed
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 512, symbol.utf8.count <= 128,
              !libraries.isEmpty, libraries.count <= 64,
              Set(libraries).count == libraries.count,
              libraries.allSatisfy({
                  LibraryChannelLibrary.isSafeAccountIdentifier($0.accountID)
                      && LibraryChannelItem.isNativeIdentifier($0.libraryID)
              }),
              includesMovies || includesEpisodes,
              ordering != .movies || includesMovies,
              TimeZone(identifier: timeZoneID) != nil,
              [includeTitles, excludeTitles, genres, allowedRatings].allSatisfy({
                  $0.count <= 256 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
              }) else { throw LibraryChannelError.invalidRecipe }
    }

    public func includes(_ item: MediaItem) -> Bool {
        guard (item.kind == .movie && includesMovies)
                || (item.kind == .episode && includesEpisodes && ordering != .movies) else { return false }
        let titles = [item.title, item.parentTitle].compactMap { $0 }.map(Self.normalized)
        if !includeTitles.isEmpty && !includeTitles.contains(where: { titles.contains(Self.normalized($0)) }) {
            return false
        }
        if excludeTitles.contains(where: { titles.contains(Self.normalized($0)) }) { return false }
        if !genres.isEmpty && !genres.contains(where: { genre in
            item.genres.contains { Self.normalized($0) == Self.normalized(genre) }
        }) { return false }
        guard let rating = item.officialRating, !rating.isEmpty else { return includeUnrated }
        return allowedRatings.isEmpty || allowedRatings.contains { Self.normalized($0) == Self.normalized(rating) }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct LibraryChannelItem: Codable, Hashable, Identifiable, Sendable {
    public let library: LibraryChannelLibrary
    public let serverID: String
    public let userID: String
    public let itemID: String
    public let mediaSourceID: String?
    public let sourceSizeBytes: Int64?
    public let sourceRevision: String?
    public let edition: String?
    public let title: String
    public let kind: MediaItemKind
    public let seriesID: String?
    public let seriesTitle: String?
    public let season: Int?
    public let episode: Int?
    public let rating: String?
    public let durationSeconds: Int64
    public var id: String { "\(library.id):\(itemID.utf8.count):\(itemID)" }

    public init(item: MediaItem, library: LibraryChannelLibrary, serverID: String, userID: String) throws {
        guard (item.kind == .movie || item.kind == .episode),
              Self.isNativeIdentifier(item.id),
              Self.isNativeIdentifier(library.libraryID),
              LibraryChannelLibrary.isSafeAccountIdentifier(library.accountID),
              Self.isNativeIdentifier(serverID), Self.isNativeIdentifier(userID),
              item.selectedVersionID.map(Self.isNativeIdentifier) ?? true,
              (item.versions.first?.id).map(Self.isNativeIdentifier) ?? true,
              let runtime = item.runtime, runtime.isFinite,
              runtime >= 1, runtime <= 604_800 else { throw LibraryChannelError.invalidSnapshot }
        self.library = library
        self.serverID = serverID
        self.userID = userID
        itemID = item.id
        let selectedID = item.selectedVersionID ?? item.versions.first?.id
        mediaSourceID = selectedID
        let version = item.versions.first { $0.id == selectedID } ?? item.versions.first
        sourceSizeBytes = version?.sizeBytes
        sourceRevision = version?.sourceMetadata?.sourceRevision
        edition = version?.edition
        title = item.title
        kind = item.kind
        seriesID = item.seriesID
        seriesTitle = item.parentTitle
        season = item.seasonNumber
        episode = item.episodeNumber
        rating = item.officialRating
        durationSeconds = Int64(runtime.rounded(.down))
        try validate()
    }

    public func validate() throws {
        guard kind == .movie || kind == .episode,
              (1...604_800).contains(durationSeconds),
              Self.isNativeIdentifier(itemID), Self.isNativeIdentifier(library.libraryID),
              LibraryChannelLibrary.isSafeAccountIdentifier(library.accountID),
              Self.isNativeIdentifier(serverID), Self.isNativeIdentifier(userID),
              mediaSourceID.map(Self.isNativeIdentifier) ?? true,
              seriesID.map(Self.isNativeIdentifier) ?? true,
              sourceRevision.map(Self.isNativeIdentifier) ?? true,
              sourceSizeBytes.map({ $0 >= 0 }) ?? true,
              title.utf8.count <= 8_192,
              seriesTitle.map({ $0.utf8.count <= 8_192 }) ?? true,
              edition.map({ $0.utf8.count <= 1_024 }) ?? true,
              rating.map({ $0.utf8.count <= 512 }) ?? true else {
            throw LibraryChannelError.invalidSnapshot
        }
    }

    static func isNativeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
        }
    }
}

public struct LibraryChannelSnapshot: Codable, Equatable, Identifiable, Sendable {
    public static let maximumItems = 50_000
    public let version: Int
    public let id: UUID
    public let items: [LibraryChannelItem]
    public let createdAt: Date
    public let ineligibleDurationCount: Int

    public init(id: UUID = UUID(), items: [LibraryChannelItem], createdAt: Date, ineligibleDurationCount: Int = 0) throws {
        version = 1
        self.id = id
        self.items = items.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        self.createdAt = createdAt
        self.ineligibleDurationCount = ineligibleDurationCount
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw LibraryChannelError.unsupportedVersion }
        guard !items.isEmpty else { throw LibraryChannelError.emptyCatalog }
        guard items.count <= Self.maximumItems else { throw LibraryChannelError.catalogTooLarge }
        guard createdAt.timeIntervalSince1970.isFinite, ineligibleDurationCount >= 0,
              Set(items.map(\.id)).count == items.count else { throw LibraryChannelError.invalidSnapshot }
        for item in items { try item.validate() }
    }
}

public struct LibraryChannelRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let snapshotID: UUID
    public let recipe: LibraryChannelRecipe
    public let epochSeconds: Int64
    public let algorithmVersion: Int

    public init(id: UUID = UUID(), snapshotID: UUID, recipe: LibraryChannelRecipe, epochSeconds: Int64) {
        self.id = id
        self.snapshotID = snapshotID
        self.recipe = recipe
        self.epochSeconds = epochSeconds
        algorithmVersion = 1
    }
}

public struct LibraryChannelDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let profileID: String
    public var revisions: [LibraryChannelRevision]
    public var isEnabled: Bool
    /// The entire published guide, not just the currently playing slot, is frozen.
    public var publishedThrough: Int64
    public var catalogID: String { "library:\(id.uuidString)" }

    public init(
        id: UUID = UUID(), sourceID: UUID = UUID(), profileID: String,
        revisions: [LibraryChannelRevision], isEnabled: Bool = true, publishedThrough: Int64 = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.profileID = profileID
        self.revisions = revisions
        self.isEnabled = isEnabled
        self.publishedThrough = publishedThrough
    }

    public func validate() throws {
        guard !profileID.isEmpty, !revisions.isEmpty, revisions.count <= 32,
              publishedThrough >= 0, publishedThrough < 253_402_300_799,
              Set(revisions.map(\.id)).count == revisions.count else { throw LibraryChannelError.invalidRecipe }
        var previous: Int64?
        for revision in revisions {
            guard revision.algorithmVersion == 1 else { throw LibraryChannelError.unsupportedVersion }
            try revision.recipe.validate()
            guard revision.epochSeconds > -253_402_300_799, revision.epochSeconds < 253_402_300_799,
                  previous.map({ revision.epochSeconds > $0 }) ?? true else {
                throw LibraryChannelError.invalidRecipe
            }
            previous = revision.epochSeconds
        }
    }
}

public struct LibraryChannelSlot: Equatable, Identifiable, Sendable {
    public let channelID: UUID
    public let revisionID: UUID
    public let item: LibraryChannelItem
    public let startSeconds: Int64
    public let endSeconds: Int64
    public var id: String { "\(channelID.uuidString):\(revisionID.uuidString):\(startSeconds)" }
    public var start: Date { Date(timeIntervalSince1970: Double(startSeconds)) }
    public var end: Date { Date(timeIntervalSince1970: Double(endSeconds)) }
    public func offset(at date: Date) -> TimeInterval {
        min(Double(item.durationSeconds), max(0, date.timeIntervalSince1970 - Double(startSeconds)))
    }
}

/// An infinite, seekable virtual broadcast. Its only inputs are immutable data
/// and UTC; timezone affects presentation, never schedule identity or DST.
public struct LibraryChannelSchedule: Sendable {
    public let definition: LibraryChannelDefinition
    private let cycles: [UUID: Cycle]

    private struct Cycle: Sendable {
        let items: [LibraryChannelItem]
        let ends: [Int64]
        let duration: Int64
    }

    public init(definition: LibraryChannelDefinition, snapshots: [UUID: LibraryChannelSnapshot]) throws {
        try definition.validate()
        self.definition = definition
        var cycles: [UUID: Cycle] = [:]
        var previousRevision: LibraryChannelRevision?
        for revision in definition.revisions {
            guard let snapshot = snapshots[revision.snapshotID] else { throw LibraryChannelError.snapshotUnavailable }
            try snapshot.validate()
            guard snapshot.items.allSatisfy({
                revision.recipe.libraries.contains($0.library)
                    && ($0.kind == .movie ? revision.recipe.includesMovies : revision.recipe.includesEpisodes)
            }) else { throw LibraryChannelError.invalidSnapshot }
            if let previousRevision, let previous = cycles[previousRevision.id] {
                let offset = (revision.epochSeconds - previousRevision.epochSeconds) % previous.duration
                guard offset == 0 || previous.ends.contains(offset) else {
                    throw LibraryChannelError.publicationConflict
                }
            }
            let ordered = Self.order(snapshot.items, recipe: revision.recipe)
            guard !ordered.isEmpty else { throw LibraryChannelError.emptyCatalog }
            var total: Int64 = 0
            let ends = ordered.map { item in total += item.durationSeconds; return total }
            cycles[revision.id] = Cycle(items: ordered, ends: ends, duration: total)
            previousRevision = revision
        }
        self.cycles = cycles
    }

    public func slot(at date: Date) throws -> LibraryChannelSlot {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 253_402_300_799 else { throw LibraryChannelError.invalidSnapshot }
        let instant = Int64(seconds.rounded(.down))
        guard let revision = definition.revisions.last(where: { $0.epochSeconds <= instant }),
              let cycle = cycles[revision.id] else { throw LibraryChannelError.historyExpired }
        let elapsed = instant - revision.epochSeconds
        let iteration = elapsed / cycle.duration
        let offset = elapsed % cycle.duration
        var low = 0
        var high = cycle.ends.count
        while low < high {
            let middle = (low + high) / 2
            if cycle.ends[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let start = revision.epochSeconds + iteration * cycle.duration + (low == 0 ? 0 : cycle.ends[low - 1])
        let naturalEnd = start + cycle.items[low].durationSeconds
        let nextRevision = definition.revisions.first { $0.epochSeconds > revision.epochSeconds }
        return LibraryChannelSlot(
            channelID: definition.id, revisionID: revision.id, item: cycle.items[low],
            startSeconds: start, endSeconds: min(naturalEnd, nextRevision?.epochSeconds ?? naturalEnd)
        )
    }

    public func slots(from start: Date, to end: Date, limit: Int = 512) throws -> [LibraryChannelSlot] {
        guard start < end, end.timeIntervalSince(start) <= 7 * 86_400, (1...10_000).contains(limit) else {
            throw LibraryChannelError.invalidRecipe
        }
        var cursor = start
        var result: [LibraryChannelSlot] = []
        while cursor < end, result.count < limit {
            let slot = try slot(at: cursor)
            result.append(slot)
            cursor = slot.end
        }
        return result
    }

    private static func order(_ input: [LibraryChannelItem], recipe: LibraryChannelRecipe) -> [LibraryChannelItem] {
        let items = input.filter { recipe.ordering != .movies || $0.kind == .movie }.sorted {
            $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
        }
        var random = LibraryChannelRandom(seed: recipe.seed)
        if recipe.ordering != .roundRobin { return random.shuffle(items) }
        let groups = Dictionary(grouping: items) { item in
            item.kind == .episode
                ? "\(item.library.id):series:\(item.seriesID ?? item.itemID)"
                : "\(item.library.id):movies"
        }
        let keys = random.shuffle(groups.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        let queues = keys.map { key in
            groups[key, default: []].sorted {
                let lhs = ($0.season ?? 0, $0.episode ?? 0)
                let rhs = ($1.season ?? 0, $1.episode ?? 0)
                return lhs == rhs ? $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) : lhs < rhs
            }
        }
        var result: [LibraryChannelItem] = []
        for index in 0..<(queues.map(\.count).max() ?? 0) {
            for queue in queues where index < queue.count { result.append(queue[index]) }
        }
        return result
    }
}

/// SplitMix64 plus unbiased Fisher–Yates; specified arithmetic is portable.
private struct LibraryChannelRandom {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9e3779b97f4a7c15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    mutating func shuffle<T>(_ input: [T]) -> [T] {
        var result = input
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let bound = UInt64(index + 1)
            let threshold = (0 &- bound) % bound
            var value = next()
            while value < threshold { value = next() }
            result.swapAt(index, Int(value % bound))
        }
        return result
    }
}
