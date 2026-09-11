#if DEBUG
import CoreModels
import Foundation
import Observation

public struct LibraryChannelProviderContext: Sendable {
    public let accountID: String
    public let authorizationID: String
    public let provider: any LibraryChannelCatalogProviding
    public let allowedLibraryIDs: Set<String>

    public init(
        accountID: String, authorizationID: String,
        provider: any LibraryChannelCatalogProviding, allowedLibraryIDs: Set<String>
    ) {
        self.accountID = accountID
        self.authorizationID = authorizationID
        self.provider = provider
        self.allowedLibraryIDs = allowedLibraryIDs
    }
}

public struct LibraryChannelLibraryChoice: Identifiable, Equatable, Sendable {
    public let reference: LibraryChannelLibrary
    public let name: String
    public let serverName: String
    public var id: String { reference.id }
}

public struct LibraryChannelPreview: Equatable, Sendable {
    public let recipe: LibraryChannelRecipe
    public let snapshot: LibraryChannelSnapshot
    public let slots: [LibraryChannelSlot]
    public let authorizationGeneration: UUID
    public let editingRevisionID: UUID?
    public let effectiveAt: Date
    public var matchingCount: Int { snapshot.items.count }
}

/// Preparation retains identity, not a resolved URL or a stale schedule copy.
/// The player re-reads future revisions and revalidates access before each item.
@MainActor
public struct LibraryChannelPlaybackContext: Sendable {
    public let channelID: UUID
    public let sourceID: UUID
    public let profileID: String
    public let generation: UUID
    private let service: LibraryChannelService

    fileprivate init(definition: LibraryChannelDefinition, service: LibraryChannelService) {
        channelID = definition.id
        sourceID = definition.sourceID
        profileID = definition.profileID
        generation = service.generation
        self.service = service
    }

    public var authorizationID: String? {
        guard generation == service.generation else { return nil }
        return service.playbackAuthorizationID(channelID: channelID)
    }

    public func schedule() -> LibraryChannelSchedule? {
        guard generation == service.generation else { return nil }
        return service.schedule(channelID: channelID)
    }

    public func provider(for item: LibraryChannelItem) -> (any LibraryChannelPlaybackProviding)? {
        guard authorizationID != nil else { return nil }
        return service.playbackProvider(for: item)
    }
}

/// Profile-scoped owner. Shells replace contexts when the active user, account
/// set, restrictions or credentials change; in-flight pages cannot cross that fence.
@MainActor
@Observable
public final class LibraryChannelService {
    private struct ContextIdentity: Equatable {
        let authorizationID: String
        let allowedLibraryIDs: Set<String>
        let provider: ProviderKind
        let serverProvider: ProviderKind
        let serverID: String
        let baseURL: URL
        let userID: String
        let deviceID: String
        let accessToken: String

        init(_ context: LibraryChannelProviderContext) {
            let session = context.provider.session
            authorizationID = context.authorizationID
            allowedLibraryIDs = context.allowedLibraryIDs
            provider = context.provider.kind
            serverProvider = session.server.provider
            serverID = session.server.id
            baseURL = session.server.baseURL
            userID = session.userID
            deviceID = session.deviceID
            accessToken = session.accessToken
        }
    }

    public let profileID: String
    public private(set) var definitions: [LibraryChannelDefinition] = []
    public private(set) var libraryChoices: [LibraryChannelLibraryChoice] = []
    public private(set) var generation = UUID()
    public private(set) var issue: LibraryChannelError?
    public private(set) var isLoaded = false
    @ObservationIgnored private let store: any LibraryChannelDefinitionStoring
    @ObservationIgnored private let snapshotStore: any LibraryChannelSnapshotStoring
    @ObservationIgnored private var contexts: [String: LibraryChannelProviderContext] = [:]
    @ObservationIgnored private var contextIdentities: [String: ContextIdentity] = [:]
    @ObservationIgnored private var snapshots: [UUID: LibraryChannelSnapshot] = [:]
    @ObservationIgnored private var schedules: [UUID: LibraryChannelSchedule] = [:]
    @ObservationIgnored private var automaticGeneration = UUID()
    @ObservationIgnored private var discoveredLibraries: Set<LibraryChannelLibrary>?
    @ObservationIgnored private let isActive: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let isSourceAllowed: @MainActor @Sendable (UUID) -> Bool
    public static let retainedHistory: TimeInterval = 24 * 60 * 60

    public init(
        profileID: String, store: any LibraryChannelDefinitionStoring,
        snapshotStore: any LibraryChannelSnapshotStoring,
        isActive: @escaping @MainActor @Sendable () -> Bool = { true },
        isSourceAllowed: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in true }
    ) {
        self.profileID = profileID
        self.store = store
        self.snapshotStore = snapshotStore
        self.isActive = isActive
        self.isSourceAllowed = isSourceAllowed
    }

    public func setContexts(_ values: [LibraryChannelProviderContext]) {
        generation = UUID()
        contexts = Dictionary(values.map { ($0.accountID, $0) }, uniquingKeysWith: { _, new in new })
        contextIdentities = contexts.mapValues(ContextIdentity.init)
        discoveredLibraries = nil
        libraryChoices = []
    }

    /// Routine discovery must not revoke a held tune when only provider instances or display metadata changed.
    /// Explicit setContexts always invalidates, even for equal values.
    public func updateContexts(_ values: [LibraryChannelProviderContext]) {
        let identities = Dictionary(
            values.map { ($0.accountID, ContextIdentity($0)) }, uniquingKeysWith: { _, new in new }
        )
        guard identities != contextIdentities else { return }
        setContexts(values)
    }

    public func load() async throws {
        let stamp = generation
        try check(stamp)
        let previous = definitions
        let stored = try store.load()
        var loaded = stored
        guard loaded.allSatisfy({ $0.profileID == profileID }) else { throw LibraryChannelError.authorizationChanged }
        for index in loaded.indices { prune(&loaded[index], at: Date()) }
        var cached: [UUID: LibraryChannelSnapshot] = [:]
        var unavailable = false
        var retainedItemCount = 0
        for id in Set(loaded.flatMap(\.revisions).map(\.snapshotID)) {
            if let value = try await snapshotStore.snapshot(id: id, profileID: profileID) {
                retainedItemCount += value.items.count
                guard retainedItemCount <= 200_000 else { throw LibraryChannelError.catalogTooLarge }
                cached[id] = value
            }
            else { unavailable = true }
            try check(stamp)
        }
        let loadedDefinitions = loaded
        let cachedSnapshots = cached
        let scheduleTask = Task.detached(priority: .utility) {
            var result: [UUID: LibraryChannelSchedule] = [:]
            for definition in loadedDefinitions {
                try Task.checkCancellation()
                if definition.revisions.allSatisfy({ cachedSnapshots[$0.snapshotID] != nil }) {
                    result[definition.id] = try LibraryChannelSchedule(definition: definition, snapshots: cachedSnapshots)
                }
            }
            try Task.checkCancellation()
            return result
        }
        let schedules = try await withTaskCancellationHandler {
            try await scheduleTask.value
        } onCancel: {
            scheduleTask.cancel()
        }
        try check(stamp)
        guard definitions == previous, try store.load() == stored else {
            throw LibraryChannelError.publicationConflict
        }
        try persist(loaded, replacing: stored)
        definitions = loaded
        snapshots = cached
        self.schedules = schedules
        isLoaded = true
        issue = unavailable ? .snapshotUnavailable : nil
        notifyStoredChange(replacing: stored)
        try await retainReferencedSnapshots()
    }

    public func loadLibraries() async throws {
        let stamp = generation
        try check(stamp)
        var choices: [LibraryChannelLibraryChoice] = []
        for context in contexts.values.sorted(by: { $0.accountID < $1.accountID }) {
            let libraries = try await context.provider.libraries()
            try check(stamp)
            choices += libraries.filter { context.allowedLibraryIDs.contains($0.id) }.map {
                LibraryChannelLibraryChoice(
                    reference: LibraryChannelLibrary(accountID: context.accountID, libraryID: $0.id),
                    name: $0.title, serverName: context.provider.session.server.name
                )
            }
        }
        libraryChoices = choices
    }

    /// Only the profile-level switch changes automatic enablement. Custom definitions are untouched.
    public func setAutomaticChannelsEnabled(_ enabled: Bool) throws {
        // Fence first-enable preparation even if cancellation or persistence prevents saving the switch.
        automaticGeneration = UUID()
        try check(generation)
        guard isLoaded else { throw LibraryChannelError.storageFailed }
        let previous = definitions
        var updated = previous
        for index in updated.indices where updated[index].isAutomatic {
            updated[index].isEnabled = enabled
        }
        try persist(updated, replacing: previous)
        definitions = updated
        notifyStoredChange(replacing: previous)
    }

    public func refreshAutomaticChannels(at now: Date = Date()) async throws -> LibraryChannelAutomaticGenerationSummary {
        let stamp = generation
        let automaticStamp = automaticGeneration
        try check(stamp)
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 < 253_402_300_798 else { throw LibraryChannelError.invalidSnapshot }
        guard isLoaded else { throw LibraryChannelError.storageFailed }
        let previous = definitions
        guard try store.load() == previous else { throw LibraryChannelError.publicationConflict }
        let providerContexts = Array(contexts.values)
        let profileID = profileID
        let cachedSnapshots = snapshots
        let cachedSchedules = schedules
        let catalogTask = Task.detached(priority: .utility) {
            try await LibraryChannelAutomaticCatalog.fetch(contexts: providerContexts) {
                try await self.checkAutomatic(stamp: stamp, automaticStamp: automaticStamp)
            }
        }
        let catalog = try await withTaskCancellationHandler {
            try await catalogTask.value
        } onCancel: {
            catalogTask.cancel()
        }
        try checkAutomatic(stamp: stamp, automaticStamp: automaticStamp)
        let formerlyAccessible = discoveredLibraries ?? Set(providerContexts.flatMap { context in
            context.allowedLibraryIDs.map { LibraryChannelLibrary(accountID: context.accountID, libraryID: $0) }
        })
        if !formerlyAccessible.subtracting(catalog.accessibleLibraries).isEmpty { generation = UUID() }
        discoveredLibraries = catalog.accessibleLibraries
        let publicationStamp = generation
        let groupTask = Task.detached(priority: .utility) {
            try LibraryChannelAutomaticPlanner.groups(catalog: catalog, profileID: profileID)
        }
        let groups = try await withTaskCancellationHandler {
            try await groupTask.value
        } onCancel: {
            groupTask.cancel()
        }
        try checkAutomatic(stamp: publicationStamp, automaticStamp: automaticStamp)
        let blockedSources = Set(groups.map {
            LibraryChannelAutomaticIdentity.sourceID(profileID: profileID, key: $0.key)
        }.filter { !isSourceAllowed($0) })
        let publicationTask = Task.detached(priority: .utility) {
            try LibraryChannelAutomaticPublication.prepare(
                groups: groups, profileID: profileID, previous: previous, snapshots: cachedSnapshots,
                schedules: cachedSchedules, blockedSourceIDs: blockedSources, now: now
            )
        }
        let publication = try await withTaskCancellationHandler {
            try await publicationTask.value
        } onCancel: {
            publicationTask.cancel()
        }
        try checkAutomatic(stamp: publicationStamp, automaticStamp: automaticStamp)
        let requiredSources = Set(groups.map {
            LibraryChannelAutomaticIdentity.sourceID(profileID: profileID, key: $0.key)
        }).subtracting(blockedSources)
        try await commit(
            publication, replacing: previous, stamp: publicationStamp, automaticStamp: automaticStamp,
            requiredSources: requiredSources
        )
        libraryChoices = catalog.libraries
        issue = definitions.flatMap(\.revisions).contains { snapshots[$0.snapshotID] == nil } ? .snapshotUnavailable : nil
        return LibraryChannelAutomaticGenerationSummary(
            channelCount: definitions.filter { $0.isAutomatic && $0.isEnabled && isSourceAllowed($0.sourceID) }.count,
            eligibleItemCount: catalog.entries.count, skippedItemCount: catalog.skippedItemCount
        )
    }

    public func preview(
        recipe: LibraryChannelRecipe, editingChannelID: UUID? = nil, at now: Date = Date()
    ) async throws -> LibraryChannelPreview {
        try recipe.validate()
        let stamp = generation
        try check(stamp)
        try checkManualChannel(editingChannelID)
        var items: [LibraryChannelItem] = []
        var invalidDurations = 0
        var seen: Set<String> = []
        var queriedCount = 0
        for library in recipe.libraries {
            guard let context = contexts[library.accountID],
                  context.allowedLibraryIDs.contains(library.libraryID) else { throw LibraryChannelError.sourceUnavailable }
            let needsParents = recipe.includesEpisodes && recipe.ordering != .movies
                && (!recipe.genres.isEmpty || !recipe.allowedRatings.isEmpty || !recipe.includeUnrated
                    || !recipe.includeTitles.isEmpty || !recipe.excludeTitles.isEmpty)
            let parents = needsParents ? try await seriesMetadata(
                library: library, context: context, stamp: stamp, limit: 200_000 - queriedCount
            ) : [:]
            queriedCount += parents.count
            var kinds: [MediaItemKind] = []
            if recipe.includesMovies { kinds.append(.movie) }
            if recipe.includesEpisodes && recipe.ordering != .movies { kinds.append(.episode) }
            for kind in kinds {
                var page = PageRequest(limit: 250)
                var total: Int?
                repeat {
                    try check(stamp)
                    let result = try await context.provider.libraryChannelItems(
                        in: library.libraryID, kind: kind, page: page
                    )
                    try check(stamp)
                    guard result.startIndex == page.startIndex, result.totalCount >= 0,
                          result.items.count <= page.limit,
                          result.items.count <= result.totalCount - result.startIndex,
                          total.map({ $0 == result.totalCount }) ?? true else {
                        throw LibraryChannelError.catalogChanged
                    }
                    total = result.totalCount
                    guard result.items.count > 0 || page.startIndex >= result.totalCount else {
                        throw LibraryChannelError.catalogChanged
                    }
                    queriedCount += result.items.count
                    guard queriedCount <= 200_000 else { throw LibraryChannelError.catalogTooLarge }
                    for var item in result.items {
                        guard item.kind == kind, item.libraryID == library.libraryID else {
                            throw LibraryChannelError.invalidSnapshot
                        }
                        let key = "\(library.id):\(item.id)"
                        guard seen.insert(key).inserted else { throw LibraryChannelError.catalogChanged }
                        if let seriesID = item.seriesID, let parent = parents[seriesID] {
                            if item.genres.isEmpty { item.genres = parent.genres }
                            if item.officialRating == nil { item.officialRating = parent.officialRating }
                            if item.parentTitle == nil { item.parentTitle = parent.title }
                        }
                        guard recipe.includes(item) else { continue }
                        guard let runtime = item.runtime, runtime.isFinite, runtime >= 1, runtime <= 604_800 else {
                            invalidDurations += 1
                            continue
                        }
                        items.append(try LibraryChannelItem(
                            item: item, library: library, serverID: context.provider.session.server.id,
                            userID: context.provider.session.userID
                        ))
                        guard items.count <= LibraryChannelSnapshot.maximumItems else {
                            throw LibraryChannelError.catalogTooLarge
                        }
                    }
                    page.startIndex += result.items.count
                } while page.startIndex < (total ?? 0)
            }
        }
        let snapshot = try LibraryChannelSnapshot(
            items: items, createdAt: now, ineligibleDurationCount: invalidDurations
        )
        var epoch = Int64(now.timeIntervalSince1970.rounded(.down))
        if let id = editingChannelID {
            guard let definition = definitions.first(where: { $0.id == id }),
                  let schedule = schedules[id], let revision = definition.revisions.last else {
                throw LibraryChannelError.snapshotUnavailable
            }
            let after = max(max(epoch, definition.publishedThrough), revision.epochSeconds)
            epoch = try schedule.slot(at: Date(timeIntervalSince1970: Double(after))).endSeconds
        }
        let effectiveAt = Date(timeIntervalSince1970: Double(epoch))
        let revision = LibraryChannelRevision(snapshotID: snapshot.id, recipe: recipe, epochSeconds: epoch)
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [revision])
        let schedule = try LibraryChannelSchedule(definition: definition, snapshots: [snapshot.id: snapshot])
        return LibraryChannelPreview(
            recipe: recipe, snapshot: snapshot,
            slots: try schedule.slots(from: effectiveAt, to: effectiveAt.addingTimeInterval(6 * 3600), limit: 12),
            authorizationGeneration: stamp,
            editingRevisionID: definitions.first { $0.id == editingChannelID }?.revisions.last?.id,
            effectiveAt: effectiveAt
        )
    }

    @discardableResult
    public func publish(
        _ preview: LibraryChannelPreview, editingChannelID: UUID? = nil, at now: Date = Date()
    ) async throws -> LibraryChannelDefinition {
        try check(preview.authorizationGeneration)
        guard isLoaded else { throw LibraryChannelError.storageFailed }
        try checkManualChannel(editingChannelID)
        let previous = definitions
        let stored = try store.load()
        guard stored == previous else { throw LibraryChannelError.publicationConflict }
        guard snapshots.values.reduce(0, { $0 + $1.items.count }) + preview.snapshot.items.count <= 200_000 else {
            throw LibraryChannelError.catalogTooLarge
        }
        var updated = previous
        var definition: LibraryChannelDefinition
        if let id = editingChannelID {
            guard let existing = updated.first(where: { $0.id == id }),
                  existing.revisions.last?.id == preview.editingRevisionID,
                  let schedule = schedules[id] else { throw LibraryChannelError.publicationConflict }
            definition = existing
            prune(&definition, at: now)
            guard definition.revisions.count < 32 else { throw LibraryChannelError.tooManyRevisions }
            let lastEpoch = definition.revisions.last?.epochSeconds ?? 0
            let after = max(max(Int64(now.timeIntervalSince1970.rounded(.down)), existing.publishedThrough), lastEpoch)
            let boundary = try schedule.slot(at: Date(timeIntervalSince1970: Double(after))).endSeconds
            guard boundary == Int64(preview.effectiveAt.timeIntervalSince1970) else {
                throw LibraryChannelError.publicationConflict
            }
            definition.revisions.append(LibraryChannelRevision(
                snapshotID: preview.snapshot.id, recipe: preview.recipe, epochSeconds: boundary
            ))
        } else {
            guard updated.count < 100 else { throw LibraryChannelError.catalogTooLarge }
            let epoch = Int64(preview.effectiveAt.timeIntervalSince1970)
            definition = LibraryChannelDefinition(profileID: profileID, revisions: [
                LibraryChannelRevision(snapshotID: preview.snapshot.id, recipe: preview.recipe, epochSeconds: epoch)
            ])
        }
        if let index = updated.firstIndex(where: { $0.id == definition.id }) { updated[index] = definition }
        else { updated.append(definition) }
        var nextSnapshots = snapshots
        nextSnapshots[preview.snapshot.id] = preview.snapshot
        var nextSchedules = schedules
        nextSchedules[definition.id] = try LibraryChannelSchedule(definition: definition, snapshots: nextSnapshots)
        try await commit(
            LibraryChannelPublication(
                definitions: updated, snapshots: nextSnapshots, schedules: nextSchedules, staged: [preview.snapshot]
            ),
            replacing: stored, stamp: preview.authorizationGeneration
        )
        return definition
    }

    public func delete(channelID: UUID) async throws {
        try check(generation)
        try checkManualChannel(channelID)
        let previous = definitions
        let updated = previous.filter { $0.id != channelID }
        try persist(updated, replacing: previous)
        guard updated != previous else { return }
        generation = UUID()
        definitions = updated
        schedules[channelID] = nil
        notifyStoredChange(replacing: previous)
        try await retainReferencedSnapshots()
    }

    public func isAuthorized(_ item: LibraryChannelItem) -> Bool {
        guard isActive(), let context = contexts[item.library.accountID],
              context.allowedLibraryIDs.contains(item.library.libraryID),
              discoveredLibraries?.contains(item.library) ?? true else { return false }
        return context.provider.session.server.id == item.serverID && context.provider.session.userID == item.userID
    }

    public func playbackProvider(for item: LibraryChannelItem) -> (any LibraryChannelPlaybackProviding)? {
        guard isAuthorized(item) else { return nil }
        return contexts[item.library.accountID]?.provider as? any LibraryChannelPlaybackProviding
    }

    public var visibleDefinitions: [LibraryChannelDefinition] {
        guard isActive() else { return [] }
        return definitions.filter { isSourceAllowed($0.sourceID) }
    }

    public func portableState() throws -> LibraryChannelPortableState {
        try check(generation)
        guard isLoaded, try store.load() == definitions else { throw LibraryChannelError.publicationConflict }
        let required = Set(definitions.flatMap(\.revisions).map(\.snapshotID))
        let values = try required.sorted { $0.uuidString < $1.uuidString }.map { id -> LibraryChannelSnapshot in
            guard let value = snapshots[id] else { throw LibraryChannelError.snapshotUnavailable }
            return value
        }
        return try LibraryChannelPortableState(definitions: definitions, snapshots: values)
    }

    public func playbackContext(catalogID: String) throws -> LibraryChannelPlaybackContext {
        guard let definition = definitions.first(where: { $0.catalogID == catalogID }),
              playbackAuthorizationID(channelID: definition.id) != nil else {
            throw LibraryChannelError.sourceUnavailable
        }
        guard schedules[definition.id] != nil else { throw LibraryChannelError.snapshotUnavailable }
        return LibraryChannelPlaybackContext(definition: definition, service: self)
    }

    public func playbackAuthorizationID(channelID: UUID) -> String? {
        guard isActive(), let definition = definitions.first(where: { $0.id == channelID }),
              definition.profileID == profileID, definition.isEnabled, isSourceAllowed(definition.sourceID),
              let recipe = definition.revisions.last?.recipe,
              recipe.libraries.allSatisfy({
                  contexts[$0.accountID]?.allowedLibraryIDs.contains($0.libraryID) == true
                      && (discoveredLibraries?.contains($0) ?? true)
              }) else { return nil }
        do {
            // A held schedule can outlive its durable authority, but a newer revision is not revocation.
            let matches = try store.load().filter { $0.id == channelID }
            guard matches.count == 1, let current = matches.first,
                  current.isEnabled, current.sourceID == definition.sourceID,
                  current.profileID == profileID else { return nil }
        } catch {
            return nil
        }
        return "\(profileID):\(generation.uuidString):\(definition.sourceID.uuidString)"
    }

    public func schedule(channelID: UUID) -> LibraryChannelSchedule? {
        guard playbackAuthorizationID(channelID: channelID) != nil else { return nil }
        return schedules[channelID]
    }

    public func slot(channelID: UUID, at date: Date, now: Date = Date()) throws -> LibraryChannelSlot {
        guard date >= now.addingTimeInterval(-Self.retainedHistory) else { throw LibraryChannelError.historyExpired }
        guard playbackAuthorizationID(channelID: channelID) != nil,
              let schedule = schedules[channelID] else { throw LibraryChannelError.snapshotUnavailable }
        let slot = try schedule.slot(at: date)
        guard isAuthorized(slot.item) else { throw LibraryChannelError.sourceUnavailable }
        return slot
    }

    public var channels: [LiveTVPrototypeChannel] {
        visibleDefinitions.filter(\.isEnabled).enumerated().compactMap { index, definition in
            guard let recipe = definition.revisions.last?.recipe,
                  recipe.libraries.allSatisfy({
                      contexts[$0.accountID]?.allowedLibraryIDs.contains($0.libraryID) == true
                          && (discoveredLibraries?.contains($0) ?? true)
                  }),
                  isActive() else { return nil }
            return LiveTVPrototypeChannel(
                id: definition.catalogID, number: index + 1, name: recipe.name,
                category: "Plozz", symbol: recipe.symbol, accent: index % 6, source: .plozz,
                tagline: "", configuredSourceID: definition.sourceID.uuidString
            )
        }
    }

    /// Persist the publication horizon before returning any guide cells.
    public func programmes(channelIDs: Set<String>, from start: Date, to end: Date) throws -> [LiveTVPrototypeProgram] {
        try check(generation)
        var result: [LiveTVPrototypeProgram] = []
        var updated = definitions
        for index in updated.indices where channelIDs.contains(updated[index].catalogID) {
            let definition = updated[index]
            guard let schedule = schedules[definition.id], definition.isEnabled,
                  isSourceAllowed(definition.sourceID) else { continue }
            let first = max(start, Date(timeIntervalSince1970: Double(definition.revisions[0].epochSeconds)))
            guard first < end else { continue }
            let slots = try schedule.slots(from: first, to: end)
            guard (slots.last?.end ?? first) >= end else { throw LibraryChannelError.catalogTooLarge }
            updated[index].publishedThrough = max(definition.publishedThrough, slots.last?.endSeconds ?? 0)
            result += slots.filter { isAuthorized($0.item) }.map {
                LiveTVPrototypeProgram(
                    id: $0.id, channelID: definition.catalogID, title: $0.item.seriesTitle ?? $0.item.title,
                    subtitle: $0.item.seriesTitle == nil ? "" : $0.item.title, start: $0.start, end: $0.end
                )
            }
        }
        if updated != definitions {
            let previous = definitions
            try persist(updated, replacing: previous)
            definitions = updated
            notifyStoredChange(replacing: previous)
        }
        return result
    }

    private func notifyStoredChange(replacing previous: [LibraryChannelDefinition]) {
        guard definitions != previous else { return }
        // Observers must see the committed service state, not mistake our own write for an external edit.
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: profileID)
    }

    private func check(_ stamp: UUID) throws {
        try Task.checkCancellation()
        guard isActive(), stamp == generation else { throw LibraryChannelError.authorizationChanged }
    }

    private func checkManualChannel(_ channelID: UUID?) throws {
        if let channelID, definitions.contains(where: { $0.id == channelID && $0.isAutomatic }) {
            throw LibraryChannelError.invalidRecipe
        }
    }

    private func checkAutomatic(stamp: UUID, automaticStamp: UUID) throws {
        try check(stamp)
        guard automaticStamp == automaticGeneration else { throw LibraryChannelError.authorizationChanged }
    }

    private func commit(
        _ publication: LibraryChannelPublication, replacing previous: [LibraryChannelDefinition],
        stamp: UUID, automaticStamp: UUID? = nil, requiredSources: Set<UUID> = []
    ) async throws {
        try check(stamp)
        if let automaticStamp { try checkAutomatic(stamp: stamp, automaticStamp: automaticStamp) }
        guard requiredSources.allSatisfy(isSourceAllowed) else { throw LibraryChannelError.authorizationChanged }
        guard definitions == previous, try store.load() == previous else {
            throw LibraryChannelError.publicationConflict
        }
        guard publication.definitions != previous || !publication.staged.isEmpty else { return }
        guard let staging = snapshotStore as? any LibraryChannelSnapshotStaging else {
            throw LibraryChannelError.storageFailed
        }
        let lease = try await staging.stage(publication.staged, profileID: profileID)
        do {
            try check(stamp)
            if let automaticStamp { try checkAutomatic(stamp: stamp, automaticStamp: automaticStamp) }
            guard requiredSources.allSatisfy(isSourceAllowed) else { throw LibraryChannelError.authorizationChanged }
            // Portable sync can commit without updating this service's cached definitions.
            guard definitions == previous, try store.load() == previous else {
                throw LibraryChannelError.publicationConflict
            }
            try persist(publication.definitions, replacing: previous)
            snapshots = publication.snapshots
            schedules = publication.schedules
            definitions = publication.definitions
            notifyStoredChange(replacing: previous)
        } catch {
            await staging.release(lease)
            throw error
        }
        await staging.release(lease)
        try await retainReferencedSnapshots()
    }

    private func seriesMetadata(
        library: LibraryChannelLibrary, context: LibraryChannelProviderContext, stamp: UUID, limit: Int
    ) async throws -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]
        var page = PageRequest(limit: 250)
        var total: Int?
        repeat {
            try check(stamp)
            let response = try await context.provider.libraryChannelItems(
                in: library.libraryID, kind: .series, page: page
            )
            try check(stamp)
            guard response.startIndex == page.startIndex, response.totalCount >= 0,
                  response.items.count <= page.limit,
                  response.items.count <= response.totalCount - response.startIndex,
                  total.map({ $0 == response.totalCount }) ?? true,
                  !response.items.isEmpty || page.startIndex >= response.totalCount else {
                throw LibraryChannelError.catalogChanged
            }
            guard response.totalCount <= limit else { throw LibraryChannelError.catalogTooLarge }
            total = response.totalCount
            for item in response.items {
                guard item.kind == .series, item.libraryID == library.libraryID,
                      result.updateValue(item, forKey: item.id) == nil else {
                    throw LibraryChannelError.catalogChanged
                }
            }
            page.startIndex += response.items.count
        } while page.startIndex < (total ?? 0)
        return result
    }

    private func prune(_ definition: inout LibraryChannelDefinition, at now: Date) {
        let cutoff = Int64(now.addingTimeInterval(-Self.retainedHistory).timeIntervalSince1970)
        while definition.revisions.count > 1, definition.revisions[1].epochSeconds <= cutoff {
            definition.revisions.removeFirst()
        }
    }

    private func retainReferencedSnapshots() async throws {
        let ids = Set(definitions.flatMap(\.revisions).map(\.snapshotID))
        snapshots = snapshots.filter { ids.contains($0.key) }
        guard let staging = snapshotStore as? any LibraryChannelSnapshotStaging else {
            throw LibraryChannelError.storageFailed
        }
        try await staging.retainReferenced(by: store, profileID: profileID)
    }

    private func persist(
        _ values: [LibraryChannelDefinition], replacing expected: [LibraryChannelDefinition]
    ) throws {
        if let atomic = store as? any LibraryChannelDefinitionCompareAndSwapping {
            try atomic.save(values, ifUnchangedFrom: expected)
        } else {
            guard try store.load() == expected else { throw LibraryChannelError.publicationConflict }
            try store.save(values)
        }
    }
}
#endif
