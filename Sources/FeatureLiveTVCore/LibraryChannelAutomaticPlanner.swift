#if DEBUG
import CoreModels
import Foundation

public struct LibraryChannelAutomaticGenerationSummary: Equatable, Sendable {
    public let channelCount: Int
    public let eligibleItemCount: Int
    public let skippedItemCount: Int
    public let unavailableSources: [LibraryChannelSourceFailure]

    public init(
        channelCount: Int = 0, eligibleItemCount: Int = 0, skippedItemCount: Int = 0,
        unavailableSources: [LibraryChannelSourceFailure] = []
    ) {
        self.channelCount = channelCount
        self.eligibleItemCount = eligibleItemCount
        self.skippedItemCount = skippedItemCount
        self.unavailableSources = unavailableSources
    }
}

public struct LibraryChannelSourceFailure: Equatable, Identifiable, Sendable {
    public enum Reason: String, Sendable {
        case unreachable, authorization, invalidResponse, unknown

        public var message: LocalizedStringResource {
            switch self {
            case .unreachable: "This server couldn't be reached. Check its address and connection, then retry."
            case .authorization: "This server rejected library access. Check the account's sign-in and permissions."
            case .invalidResponse: "This server's library response couldn't be read. Retry when the server is ready."
            case .unknown: "This server's libraries couldn't be loaded. Retry to include them."
            }
        }
    }

    public let accountID: String
    public let serverName: String
    public let reason: Reason
    public var id: String { accountID }

    public init(accountID: String, serverName: String, error: Error) {
        self.accountID = accountID
        self.serverName = serverName
        switch error {
        case AppError.serverUnreachable, is URLError: reason = .unreachable
        case AppError.unauthorized, AppError.invalidCredentials: reason = .authorization
        case AppError.decoding, AppError.invalidResponse: reason = .invalidResponse
        default: reason = .unknown
        }
    }
}

struct LibraryChannelAutomaticCatalog: Sendable {
    struct Entry: Sendable {
        let item: LibraryChannelItem
        let genres: [String]
        let studios: [String]
        let directors: [String]
        let year: Int?
    }
    var entries: [Entry] = []
    var skippedItemCount = 0
    var queriedItemCount = 0
    var libraries: [LibraryChannelLibraryChoice] = []
    var accessibleLibraries: Set<LibraryChannelLibrary> = []

    private struct Parent {
        let title: String
        let genres: [String]
        let studios: [String]
        let rating: String?
        let year: Int?
    }

    static func fetch(
        contexts: [LibraryChannelProviderContext],
        policy: LibraryChannelAutomaticPlanner.Policy = .init(),
        reportProgress: @Sendable (LibraryChannelPreparationUpdate) async -> Void = { _ in },
        checkAuthorization: @Sendable () async throws -> Void
    ) async throws -> Self {
        var catalog = Self()
        var queriedCount = 0
        var movieCount = 0
        var episodeCount = 0
        for context in contexts.sorted(by: { $0.accountID < $1.accountID }) {
            try await checkAuthorization()
            await reportProgress(.init(
                stage: .checkingServers, serverName: context.provider.session.server.name,
                scannedItemCount: queriedCount))
            let libraries = try await context.provider.libraries()
            try await checkAuthorization()
            guard Set(libraries.map(\.id)).count == libraries.count else {
                throw LibraryChannelError.catalogChanged
            }
            catalog.accessibleLibraries.formUnion(libraries.filter { context.allowedLibraryIDs.contains($0.id) }.map {
                LibraryChannelLibrary(accountID: context.accountID, libraryID: $0.id)
            })
            for library in libraries.sorted(by: { $0.id < $1.id })
                where context.allowedLibraryIDs.contains(library.id) && !library.isMusic {
                // Unknown/mixed server libraries can contain either playable kind.
                guard [.movie, .series, .episode, .folder, .unknown, .collection, .video].contains(library.kind) else {
                    continue
                }
                let reference = LibraryChannelLibrary(accountID: context.accountID, libraryID: library.id)
                catalog.libraries.append(LibraryChannelLibraryChoice(
                    reference: reference, name: library.title, serverName: context.provider.session.server.name
                ))
                var parents: [String: Parent] = [:]
                var seen = Set<String>()
                let kinds: [MediaItemKind] = library.kind == .movie ? [.movie]
                    : (library.kind == .series || library.kind == .episode ? [.series, .episode] : [.series, .movie, .episode])
                for kind in kinds {
                    var page = PageRequest(limit: 250)
                    var total: Int?
                    repeat {
                        try Task.checkCancellation()
                        try await checkAuthorization()
                        await reportProgress(.init(
                            stage: .readingLibrary, serverName: context.provider.session.server.name,
                            libraryName: library.title, kind: kind, scannedItemCount: queriedCount,
                            completedItems: page.startIndex, totalItems: total))
                        let response = try await context.provider.libraryChannelItems(in: library.id, kind: kind, page: page)
                        try await checkAuthorization()
                        guard response.startIndex == page.startIndex, response.totalCount >= response.startIndex,
                              response.items.count <= page.limit,
                              response.items.count <= response.totalCount - response.startIndex,
                              total.map({ $0 == response.totalCount }) ?? true,
                              !response.items.isEmpty || page.startIndex == response.totalCount else {
                            throw LibraryChannelError.catalogChanged
                        }
                        total = response.totalCount
                        guard response.totalCount - response.startIndex <= LibraryChannelPortableState.maximumItems - queriedCount else {
                            throw LibraryChannelError.catalogTooLarge
                        }
                        guard queriedCount <= LibraryChannelPortableState.maximumItems - response.items.count else {
                            throw LibraryChannelError.catalogTooLarge
                        }
                        queriedCount += response.items.count
                        catalog.queriedItemCount = queriedCount
                        for var media in response.items {
                            try Task.checkCancellation()
                            guard media.kind == kind, media.libraryID == library.id else {
                                throw LibraryChannelError.invalidSnapshot
                            }
                            guard seen.insert(media.id).inserted else { throw LibraryChannelError.catalogChanged }
                            if kind == .series {
                                parents[media.id] = Parent(
                                    title: media.title,
                                    genres: LibraryChannelAutomaticPlanner.labels(media.genres, policy: policy),
                                    studios: LibraryChannelAutomaticPlanner.labels(media.studios, policy: policy),
                                    rating: media.officialRating, year: media.productionYear
                                )
                                continue
                            }
                            if let parentID = media.seriesID, let parent = parents[parentID] {
                                if media.genres.isEmpty { media.genres = parent.genres }
                                if media.studios.isEmpty { media.studios = parent.studios }
                                if media.officialRating?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                                    media.officialRating = parent.rating
                                }
                                if media.parentTitle == nil { media.parentTitle = parent.title }
                                if media.productionYear == nil { media.productionYear = parent.year }
                                // A series' director is not necessarily the episode's director.
                            }
                            guard let runtime = media.runtime, runtime.isFinite, (1...604_800).contains(runtime) else {
                                catalog.skippedItemCount += 1
                                continue
                            }
                            let item = try LibraryChannelItem(
                                item: media, library: reference, serverID: context.provider.session.server.id,
                                userID: context.provider.session.userID
                            )
                            if kind == .movie { movieCount += 1 }
                            else { episodeCount += 1 }
                            guard max(movieCount, episodeCount) <= LibraryChannelSnapshot.maximumItems else {
                                throw LibraryChannelError.catalogTooLarge
                            }
                            catalog.entries.append(Entry(
                                item: item,
                                genres: LibraryChannelAutomaticPlanner.labels(media.genres, policy: policy),
                                studios: LibraryChannelAutomaticPlanner.labels(media.studios, policy: policy),
                                directors: LibraryChannelAutomaticPlanner.labels(
                                    media.people.filter { $0.kind?.lowercased() == "director" }.map(\.name), policy: policy
                                ),
                                year: media.productionYear
                            ))
                        }
                        page.startIndex += response.items.count
                        await reportProgress(.init(
                            stage: .readingLibrary, serverName: context.provider.session.server.name,
                            libraryName: library.title, kind: kind, scannedItemCount: queriedCount,
                            completedItems: page.startIndex, totalItems: total))
                    } while page.startIndex < (total ?? 0)
                }
            }
        }
        return catalog
    }
}

enum LibraryChannelAutomaticPlanner {
    struct Policy: Sendable {
        var maximumThemedChannels = 24
        var minimumThemeItems = 4
        var minimumThemeTitles = 2
        var minimumDirectorTitles = 3
        var maximumLabelsPerField = 16
        var maximumMetadataGroups = 2_048
        var kidsRatings: Set<String> = ["g", "tv-y", "tv-g"]
        var familyRatings: Set<String> = ["g", "pg", "tv-y", "tv-y7", "tv-y7-fv", "tv-g", "tv-pg"]
        var animationGenres: Set<String> = ["animation", "animated", "anime"]
    }

    struct Group: Sendable {
        let key: String
        let recipe: LibraryChannelRecipe
        let items: [LibraryChannelItem]
        let isCatchall: Bool
    }

    private struct Bucket {
        var label: String
        let category: String
        var indices: [Int] = []
        var titles: Set<Int> = []
    }

    private static func persistedName(_ resource: LocalizedStringResource) -> String {
        String(localized: resource) // l10n:content — resolved only when writing a generated channel recipe snapshot
    }

    static func groups(
        catalog: LibraryChannelAutomaticCatalog, profileID: String, policy: Policy = Policy()
    ) throws -> [Group] {
        var buckets: [String: Bucket] = [:]
        var movies: [LibraryChannelItem] = []
        var episodes: [LibraryChannelItem] = []
        var titleIDs: [String: Int] = [:]
        var movieIndices = Set<Int>()
        var episodeIndices = Set<Int>()
        func add(_ key: String, label: String, category: String, index: Int, titleID: Int) {
            guard buckets[key] != nil || buckets.count < policy.maximumMetadataGroups
                    || !["genre", "studio", "director"].contains(category) else { return }
            if buckets[key] == nil { buckets[key] = Bucket(label: label, category: category) }
            // Stable spelling even when different servers capitalize the same tag differently.
            if label < buckets[key]!.label { buckets[key]!.label = label }
            buckets[key]!.indices.append(index)
            buckets[key]!.titles.insert(titleID)
        }
        let orderedIndices = catalog.entries.indices.sorted { catalog.entries[$0].item.id < catalog.entries[$1].item.id }
        for index in orderedIndices {
            try Task.checkCancellation()
            let entry = catalog.entries[index]
            let title = entry.item.kind == .movie
                ? "movie:\(normalized(entry.item.title)):\(entry.year.map(String.init) ?? "")"
                : "series:\(entry.item.seriesTitle.map(normalized) ?? "\(entry.item.library.id):\(entry.item.seriesID ?? entry.item.itemID)")"
            if titleIDs[title] == nil { titleIDs[title] = titleIDs.count }
            let titleID = titleIDs[title]!
            if entry.item.kind == .movie { movies.append(entry.item); movieIndices.insert(index) }
            else { episodes.append(entry.item); episodeIndices.insert(index) }
            for (category, values) in [("genre", entry.genres), ("studio", entry.studios), ("director", entry.directors)] {
                for label in labels(values, policy: policy) {
                    add("v1/\(category)/\(normalized(label))", label: label, category: category, index: index, titleID: titleID)
                }
            }
            if let year = entry.year, (1880...2100).contains(year) {
                let decade = year / 10 * 10
                add("v1/decade/\(decade)", label: persistedName("\(decade)s"), category: "decade", index: index, titleID: titleID)
            }
            if !policy.animationGenres.isDisjoint(with: entry.genres.map(normalized)) {
                add("v1/animation", label: persistedName("Animation"), category: "animation", index: index, titleID: titleID)
            }
            if let rating = entry.item.rating.map(normalized) {
                if policy.kidsRatings.contains(rating) {
                    add("v1/kids", label: persistedName("Kids"), category: "kids", index: index, titleID: titleID)
                }
                if policy.familyRatings.contains(rating) {
                    add("v1/family", label: persistedName("Family"), category: "family", index: index, titleID: titleID)
                }
            }
        }
        func group(key: String, name: String, items: [LibraryChannelItem], catchall: Bool, symbol: String) throws -> Group {
            let libraries = Set(items.map(\.library)).sorted { $0.id < $1.id }
            guard libraries.count <= 64 else { throw LibraryChannelError.catalogTooLarge }
            let hasMovies = items.contains { $0.kind == .movie }
            let hasEpisodes = items.contains { $0.kind == .episode }
            let recipe = LibraryChannelRecipe(
                name: name, symbol: symbol, libraries: libraries,
                includesMovies: hasMovies, includesEpisodes: hasEpisodes, timeZoneID: "UTC",
                ordering: hasEpisodes ? .roundRobin : .movies,
                seed: LibraryChannelAutomaticIdentity.seed(profileID: profileID, key: key)
            )
            try recipe.validate()
            guard items.count <= LibraryChannelSnapshot.maximumItems else { throw LibraryChannelError.catalogTooLarge }
            return Group(key: key, recipe: recipe, items: items, isCatchall: catchall)
        }
        var result: [Group] = []
        if !movies.isEmpty {
            result.append(try group(key: "v1/movies", name: persistedName("Movies"),
                                    items: movies, catchall: true, symbol: "film"))
        }
        if !episodes.isEmpty {
            result.append(try group(key: "v1/tv", name: persistedName("TV Shows"),
                                    items: episodes, catchall: true, symbol: "tv"))
        }
        // Rotate categories instead of letting a large genre list consume the entire lineup.
        let categories = ["genre", "decade", "animation", "family", "kids", "studio", "director"]
        var queues: [[String]] = categories.map { category in
            buckets.keys.filter { key in
                let bucket = buckets[key]!
                return bucket.category == category && bucket.indices.count >= policy.minimumThemeItems
                    && bucket.titles.count >= (category == "director" ? policy.minimumDirectorTitles : policy.minimumThemeTitles)
                    && bucket.indices.count <= LibraryChannelSnapshot.maximumItems
            }.sorted {
                let lhs = buckets[$0]!, rhs = buckets[$1]!
                if lhs.titles.count != rhs.titles.count { return lhs.titles.count > rhs.titles.count }
                if lhs.indices.count != rhs.indices.count { return lhs.indices.count > rhs.indices.count }
                return $0 < $1
            }
        }
        var selected = 0
        var membershipBudget = min(catalog.entries.count * 3, 100_000 - catalog.entries.count)
        var memberships = Set([movieIndices, episodeIndices])
        while queues.contains(where: { !$0.isEmpty }), selected < policy.maximumThemedChannels {
            for index in queues.indices where !queues[index].isEmpty && selected < policy.maximumThemedChannels {
                try Task.checkCancellation()
                let key = queues[index].removeFirst()
                let bucket = buckets[key]!
                guard bucket.indices.count <= membershipBudget else { continue }
                let items = bucket.indices.map { catalog.entries[$0].item }
                guard Set(items.map(\.library)).count <= 64 else { continue }
                guard memberships.insert(Set(bucket.indices)).inserted else { continue }
                result.append(try group(key: key, name: bucket.label, items: items, catchall: false, symbol: "tv"))
                membershipBudget -= items.count
                selected += 1
            }
        }
        return result
    }

    static func labels(_ values: [String], policy: Policy) -> [String] {
        var labels: [String: String] = [:]
        for raw in values {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(label)
            guard !key.isEmpty, label.utf8.count <= 192,
                  !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            labels[key] = min(labels[key] ?? label, label)
        }
        return labels.keys.sorted().prefix(policy.maximumLabelsPerField).compactMap { labels[$0] }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
#endif
