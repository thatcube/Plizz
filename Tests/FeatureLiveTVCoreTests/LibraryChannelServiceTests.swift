#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LibraryChannelServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")

    private func makeService(
        items: [MediaItem], store: LibraryDefinitionMemory = LibraryDefinitionMemory(),
        snapshotStore: (any LibraryChannelSnapshotStoring)? = nil,
        profileID: String = "profile",
        isSourceAllowed: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in true }
    ) async throws -> (LibraryChannelService, LibraryCatalogFixture, any LibraryChannelSnapshotStoring) {
        let provider = LibraryCatalogFixture(items: items)
        let cache = snapshotStore ?? LibraryChannelSnapshotStore(databaseURL: nil)
        let service = LibraryChannelService(
            profileID: profileID, store: store, snapshotStore: cache, isSourceAllowed: isSourceAllowed
        )
        service.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "first", provider: provider, allowedLibraryIDs: ["library"]
        )])
        try await service.load()
        return (service, provider, cache)
    }

    private func episode(_ id: String, runtime: Double? = 60) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .episode, runtime: runtime)
        item.libraryID = "library"
        item.seriesID = "show"
        item.parentTitle = "Show"
        return item
    }

    private func observeStoredChanges(
        service: LibraryChannelService, store: LibraryDefinitionMemory, records: LibraryStoredChangeRecords
    ) -> any NSObjectProtocol {
        let profileID = service.profileID
        return NotificationCenter.default.addObserver(
            forName: .plozzLiveTVPortableStateDidChange, object: nil, queue: .main
        ) { notification in
            guard notification.object as? String == profileID else { return }
            MainActor.assumeIsolated {
                do {
                    let persisted = try store.load()
                    XCTAssertEqual(service.definitions, persisted)
                    records.values.append(service.definitions)
                } catch {
                    XCTFail("Notified library definitions could not be read: \(error)")
                }
            }
        }
    }

    func testCatalogPagesConcreteEpisodesWithoutAnyItemDetailFetch() async throws {
        let items = (0..<501).map { episode("e\($0)") } + [episode("invalid", runtime: nil)]
        let (service, provider, _) = try await makeService(items: items)
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        XCTAssertEqual(preview.matchingCount, 501)
        XCTAssertEqual(preview.snapshot.ineligibleDurationCount, 1)
        let pages = await provider.pages
        let details = await provider.details
        XCTAssertEqual(pages.map(\.startIndex), [0, 250, 500])
        XCTAssertEqual(details, 0)
        XCTAssertTrue(preview.snapshot.items.allSatisfy { $0.kind == .episode })
    }

    func testPublishAndReloadPreserveGuideAndChannelIdentity() async throws {
        let store = LibraryDefinitionMemory()
        let (service, provider, cache) = try await makeService(items: [episode("e")], store: store)
        let preview = try await service.preview(
            recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
        )
        let created = try await service.publish(preview, at: now)
        let programmes = try service.programmes(channelIDs: [created.catalogID], from: now, to: now.addingTimeInterval(180))
        let fresh = LibraryChannelService(profileID: "profile", store: store, snapshotStore: cache)
        fresh.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "fresh", provider: provider, allowedLibraryIDs: ["library"]
        )])
        try await fresh.load()
        let reloaded = try fresh.programmes(channelIDs: [created.catalogID], from: now, to: now.addingTimeInterval(180))
        XCTAssertEqual(programmes, reloaded)
        XCTAssertEqual(fresh.channels.map(\.id), [created.catalogID])
        XCTAssertEqual(fresh.channels.first?.configuredSourceID, created.sourceID.uuidString)
    }

    func testPublishEditAndDeleteNotifyOnlyAfterDurableAndVisibleStateAgree() async throws {
        let store = LibraryDefinitionMemory()
        let (service, _, _) = try await makeService(
            items: [episode("e")], store: store, profileID: "signal-\(UUID().uuidString)"
        )
        let records = LibraryStoredChangeRecords()
        let observer = observeStoredChanges(service: service, store: store, records: records)
        defer { NotificationCenter.default.removeObserver(observer) }
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        XCTAssertTrue(records.values.isEmpty)
        let created = try await service.publish(preview, at: now)
        XCTAssertEqual(records.values, [[created]])
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let revised = try await service.publish(edited, editingChannelID: created.id, at: now)
        XCTAssertEqual(records.values, [[created], [revised]])
        try await service.delete(channelID: created.id)
        XCTAssertEqual(records.values, [[created], [revised], []])
        let generation = service.generation
        try await service.delete(channelID: created.id)
        XCTAssertEqual(records.values.count, 3)
        XCTAssertEqual(service.generation, generation)
    }

    func testGuideHorizonChangesNotifyButIdenticalProjectionAndReloadDoNotEcho() async throws {
        let store = LibraryDefinitionMemory()
        let (service, _, _) = try await makeService(
            items: [episode("e")], store: store, profileID: "signal-\(UUID().uuidString)"
        )
        let preview = try await service.preview(
            recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
        )
        let channel = try await service.publish(preview, at: now)
        let records = LibraryStoredChangeRecords()
        let observer = observeStoredChanges(service: service, store: store, records: records)
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try service.programmes(channelIDs: [channel.catalogID], from: now, to: now.addingTimeInterval(180))
        XCTAssertEqual(records.values.count, 1)
        _ = try service.programmes(channelIDs: [channel.catalogID], from: now, to: now.addingTimeInterval(180))
        _ = try service.programmes(channelIDs: [channel.catalogID], from: now, to: now.addingTimeInterval(120))
        try await service.load()
        XCTAssertEqual(records.values.count, 1)
        _ = try service.programmes(channelIDs: [channel.catalogID], from: now, to: now.addingTimeInterval(240))
        XCTAssertEqual(records.values.count, 2)
        XCTAssertEqual(records.values.last?.first?.publishedThrough, Int64(now.timeIntervalSince1970) + 240)
    }

    func testRetainedHistoryPruningNotifiesOnceWithoutReloadFeedback() async throws {
        let historical = Date().addingTimeInterval(-2 * LibraryChannelService.retainedHistory)
        let store = LibraryDefinitionMemory()
        let (service, _, _) = try await makeService(
            items: [episode("e")], store: store, profileID: "signal-\(UUID().uuidString)"
        )
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: historical)
        let created = try await service.publish(preview, at: historical)
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: historical)
        _ = try await service.publish(edited, editingChannelID: created.id, at: historical)
        let records = LibraryStoredChangeRecords()
        let observer = observeStoredChanges(service: service, store: store, records: records)
        defer { NotificationCenter.default.removeObserver(observer) }
        try await service.load()
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.first?.first?.revisions.count, 1)
        try await service.load()
        XCTAssertEqual(records.values.count, 1)
    }

    func testConflictingPublicationDoesNotNotifyLocalSync() async throws {
        let store = LibraryDefinitionMemory()
        let cache = LibrarySnapshotInterleavingStore()
        let (service, _, _) = try await makeService(
            items: [episode("e")], store: store, snapshotStore: cache,
            profileID: "signal-\(UUID().uuidString)"
        )
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let records = LibraryStoredChangeRecords()
        let observer = observeStoredChanges(service: service, store: store, records: records)
        defer { NotificationCenter.default.removeObserver(observer) }
        var remote = created
        remote.isEnabled = false
        let portable = [remote]
        await cache.afterNextStage { try store.save(portable) }
        do {
            _ = try await service.publish(edited, editingChannelID: created.id, at: now)
            XCTFail("The portable commit must win without a local success notification")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
        XCTAssertTrue(records.values.isEmpty)
    }

    func testGenreAndRatingRulesInheritPaginatedShowMetadataWithoutEpisodeDetails() async throws {
        var show = MediaItem(id: "show", title: "Show", kind: .series)
        show.libraryID = "library"
        show.genres = ["Comedy"]
        show.officialRating = "TV-PG"
        let (service, provider, _) = try await makeService(items: [show, episode("e")])
        let preview = try await service.preview(recipe: LibraryChannelRecipe(
            name: "Comedy", libraries: [library], genres: ["Comedy"], allowedRatings: ["TV-PG"],
            includeUnrated: false, includesMovies: false
        ), at: now)
        XCTAssertEqual(preview.matchingCount, 1)
        XCTAssertEqual(preview.snapshot.items.first?.rating, "TV-PG")
        let details = await provider.details
        let pages = await provider.pages
        XCTAssertEqual(details, 0)
        XCTAssertEqual(pages.count, 2)
    }

    func testEditingFreezesEntirePublishedGuideBeforeFutureRevision() async throws {
        let (service, _, _) = try await makeService(items: [episode("e")])
        var recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let before = try service.programmes(channelIDs: [created.catalogID], from: now, to: now.addingTimeInterval(180))
        recipe.seed = 200
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let revised = try await service.publish(edited, editingChannelID: created.id, at: now)
        XCTAssertGreaterThanOrEqual(revised.revisions.last!.epochSeconds, Int64(now.timeIntervalSince1970) + 180)
        let after = try service.programmes(channelIDs: [created.catalogID], from: now, to: now.addingTimeInterval(180))
        XCTAssertEqual(before, after)
    }

    func testAuthorizationChangeRejectsPreviewPublicationAndHidesCatalog() async throws {
        let (service, _, _) = try await makeService(items: [episode("e")])
        let preview = try await service.preview(
            recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
        )
        service.setContexts([])
        do {
            _ = try await service.publish(preview, at: now)
            XCTFail("A previous profile's preview must not publish")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
        XCTAssertTrue(service.channels.isEmpty)
    }

    func testSourceApprovalRevocationHidesGuideAndInvalidatesPreparedPlaybackWithoutDeletingDefinition() async throws {
        let approval = LibrarySourceApprovalFixture()
        let (service, _, _) = try await makeService(items: [episode("e")], isSourceAllowed: { _ in approval.allowed })
        let preview = try await service.preview(
            recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
        )
        let created = try await service.publish(preview, at: now)
        let context = try service.playbackContext(catalogID: created.catalogID)
        XCTAssertEqual(context.channelID, created.id)
        XCTAssertEqual(context.sourceID, created.sourceID)
        XCTAssertNotNil(context.authorizationID)
        approval.allowed = false
        XCTAssertTrue(service.channels.isEmpty)
        XCTAssertTrue(service.visibleDefinitions.isEmpty)
        XCTAssertNil(context.authorizationID)
        XCTAssertNil(context.schedule())
        XCTAssertTrue(try service.programmes(
            channelIDs: [created.catalogID], from: now, to: now.addingTimeInterval(120)
        ).isEmpty)
        XCTAssertEqual(service.definitions.count, 1)
    }

    func testPreparedContextSeesFutureRevisionsButRejectsChangedAccountGeneration() async throws {
        let (service, _, _) = try await makeService(items: [episode("e")])
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let context = try service.playbackContext(catalogID: created.catalogID)
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        _ = try await service.publish(edited, editingChannelID: created.id, at: now)
        XCTAssertEqual(context.schedule()?.definition.revisions.count, 2)
        service.setContexts([])
        XCTAssertNil(context.authorizationID)
        XCTAssertNil(context.schedule())
    }

    func testDurableAuthorityRevokesHeldContextWithoutReloadingItsSchedule() async throws {
        for change in LibraryStoredAuthorityChange.allCases {
            let store = LibraryDefinitionMemory()
            let (service, _, _) = try await makeService(items: [episode("e")], store: store)
            let preview = try await service.preview(
                recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
            )
            let created = try await service.publish(preview, at: now)
            let context = try service.playbackContext(catalogID: created.catalogID)
            XCTAssertNotNil(context.authorizationID)
            try store.save(change.applying(to: created))
            XCTAssertEqual(service.definitions, [created])
            XCTAssertNil(service.playbackAuthorizationID(channelID: created.id), "\(change)")
            XCTAssertNil(context.authorizationID, "\(change)")
            XCTAssertNil(context.schedule(), "\(change)")
            XCTAssertThrowsError(try service.playbackContext(catalogID: created.catalogID))
        }
    }

    func testDurableAuthorityReadFailureCannotReuseCachedGrant() async throws {
        let store = LibraryDefinitionMemory()
        let (service, _, _) = try await makeService(items: [episode("e")], store: store)
        let preview = try await service.preview(
            recipe: LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false), at: now
        )
        let created = try await service.publish(preview, at: now)
        let context = try service.playbackContext(catalogID: created.catalogID)
        XCTAssertNotNil(context.authorizationID)
        store.setReadFailure(.storageFailed)
        XCTAssertNil(service.playbackAuthorizationID(channelID: created.id))
        XCTAssertNil(context.authorizationID)
        XCTAssertNil(context.schedule())
        XCTAssertEqual(service.definitions, [created])
    }

    func testNewDurableRecipeAndRevisionDoNotRevokeTheHeldAuthorizedSchedule() async throws {
        let store = LibraryDefinitionMemory()
        let (service, _, _) = try await makeService(items: [episode("e")], store: store)
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let context = try service.playbackContext(catalogID: created.catalogID)
        let expected = try XCTUnwrap(context.authorizationID)
        var remote = created
        var futureRecipe = recipe
        futureRecipe.name = "Future"
        futureRecipe.seed += 1
        remote.revisions.append(LibraryChannelRevision(
            snapshotID: preview.snapshot.id, recipe: futureRecipe,
            epochSeconds: Int64(now.timeIntervalSince1970) + 60
        ))
        remote.publishedThrough = Int64(now.timeIntervalSince1970) + 240
        try store.save([remote])
        XCTAssertEqual(context.authorizationID, expected)
        XCTAssertEqual(context.schedule()?.definition, created)
        XCTAssertEqual(service.definitions, [created])
        XCTAssertEqual(try store.load(), [remote])
    }

    func testTwoEditorsCannotOverwriteNewRevision() async throws {
        let (service, _, _) = try await makeService(items: [episode("e")])
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let first = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let second = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        _ = try await service.publish(first, editingChannelID: created.id, at: now)
        do {
            _ = try await service.publish(second, editingChannelID: created.id, at: now)
            XCTFail("Stale editor")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
    }

    func testPublishRejectsAlreadyChangedDurableDefinitionsBeforeStaging() async throws {
        let store = LibraryDefinitionMemory()
        let (service, _, cache) = try await makeService(items: [episode("e")], store: store)
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let previous = service.definitions
        var remote = created
        remote.isEnabled = false
        try store.save([remote])

        do {
            _ = try await service.publish(edited, editingChannelID: created.id, at: now)
            XCTFail("A stale runtime must not overwrite portable state")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
        XCTAssertEqual(try store.load(), [remote])
        XCTAssertEqual(service.definitions, previous)
        let staged = try await cache.snapshot(id: edited.snapshot.id, profileID: "profile")
        XCTAssertNil(staged)
    }

    func testPublishDetectsPortableCommitDuringSnapshotStagingAndReleasesItsLease() async throws {
        let store = LibraryDefinitionMemory()
        let cache = LibrarySnapshotInterleavingStore()
        let (service, _, _) = try await makeService(
            items: [episode("e")], store: store, snapshotStore: cache
        )
        let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
        let preview = try await service.preview(recipe: recipe, at: now)
        let created = try await service.publish(preview, at: now)
        let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
        let previous = service.definitions
        var remote = created
        remote.isEnabled = false
        let portable = [remote]
        await cache.afterNextStage { try store.save(portable) }
        let releasesBefore = await cache.releasedLeaseCount

        do {
            _ = try await service.publish(edited, editingChannelID: created.id, at: now)
            XCTFail("Store changes during awaited SQLite work must conflict")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
        XCTAssertEqual(try store.load(), portable)
        XCTAssertEqual(service.definitions, previous)
        let releasesAfter = await cache.releasedLeaseCount
        XCTAssertEqual(releasesAfter, releasesBefore + 1)
        let localCandidate = try await cache.snapshot(id: edited.snapshot.id, profileID: "profile")
        XCTAssertEqual(localCandidate, edited.snapshot)
    }

    func testLoadDetectsPortableCommitDuringSnapshotReadsBeforePublishingOrPruning() async throws {
        for needsPruning in [false, true] {
            let store = LibraryDefinitionMemory()
            let cache = LibrarySnapshotInterleavingStore()
            let (service, _, _) = try await makeService(
                items: [episode("e")], store: store, snapshotStore: cache
            )
            let recipe = LibraryChannelRecipe(name: "Show", libraries: [library], includesMovies: false)
            let preview = try await service.preview(recipe: recipe, at: now)
            let created = try await service.publish(preview, at: now)
            if needsPruning {
                let edited = try await service.preview(recipe: recipe, editingChannelID: created.id, at: now)
                _ = try await service.publish(edited, editingChannelID: created.id, at: now)
            }
            let previous = service.definitions
            let portable = previous.map { definition in
                var remote = definition
                remote.isEnabled = false
                return remote
            }
            await cache.afterNextRead { try store.save(portable) }

            do {
                try await service.load()
                XCTFail("Reload must not replace a concurrent portable commit")
            } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
            XCTAssertEqual(try store.load(), portable)
            XCTAssertEqual(service.definitions, previous)
            XCTAssertEqual(service.definitions.first?.revisions.count, needsPruning ? 2 : 1)
        }
    }

    @MainActor
    private final class LibrarySourceApprovalFixture {
        var allowed = true
    }

    func testSnapshotCacheIsImmutableAndPartitionedByProfile() async throws {
        let cache = LibraryChannelSnapshotStore(databaseURL: nil)
        let item = try LibraryChannelItem(item: episode("e"), library: library, serverID: "server", userID: "user")
        let snapshot = try LibraryChannelSnapshot(items: [item], createdAt: now)
        try await cache.insert(snapshot, profileID: "one")
        let missing = try await cache.snapshot(id: snapshot.id, profileID: "two")
        XCTAssertNil(missing)
        let conflict = try LibraryChannelSnapshot(id: snapshot.id, items: [item], createdAt: now.addingTimeInterval(1))
        do {
            try await cache.insert(conflict, profileID: "one")
            XCTFail("Immutable")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .publicationConflict) }
        try await cache.retain(ids: [], profileID: "two")
        let retained = try await cache.snapshot(id: snapshot.id, profileID: "one")
        XCTAssertEqual(retained, snapshot)
        try await cache.retain(ids: [], profileID: "one")
        let removed = try await cache.snapshot(id: snapshot.id, profileID: "one")
        XCTAssertNil(removed)
    }

    func testStagedSnapshotSurvivesRetirementUntilItsDefinitionCommits() async throws {
        let cache = LibraryChannelSnapshotStore(databaseURL: nil)
        let store = LibraryDefinitionMemory()
        let item = try LibraryChannelItem(item: episode("e"), library: library, serverID: "server", userID: "user")
        let snapshot = try LibraryChannelSnapshot(items: [item], createdAt: now)
        let lease = try await cache.stage([snapshot], profileID: "profile")
        try await cache.retainReferenced(by: store, profileID: "profile")
        let staged = try await cache.snapshot(id: snapshot.id, profileID: "profile")
        XCTAssertEqual(staged, snapshot)
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            LibraryChannelRevision(
                snapshotID: snapshot.id,
                recipe: LibraryChannelRecipe(name: "Show", libraries: [library]),
                epochSeconds: Int64(now.timeIntervalSince1970)
            )
        ])
        try store.save([definition])
        await cache.release(lease)
        try await cache.retainReferenced(by: store, profileID: "profile")
        let committed = try await cache.snapshot(id: snapshot.id, profileID: "profile")
        XCTAssertEqual(committed, snapshot)
        try store.save([])
        try await cache.retainReferenced(by: store, profileID: "profile")
        let deleted = try await cache.snapshot(id: snapshot.id, profileID: "profile")
        XCTAssertNil(deleted)
    }
}

@MainActor
private final class LibraryStoredChangeRecords {
    var values: [[LibraryChannelDefinition]] = []
}

private final class LibraryDefinitionMemory: LibraryChannelDefinitionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LibraryChannelDefinition] = []
    private var readFailure: LibraryChannelError?
    func load() throws -> [LibraryChannelDefinition] {
        try lock.withLock {
            if let readFailure { throw readFailure }
            return values
        }
    }
    func save(_ definitions: [LibraryChannelDefinition]) throws { lock.withLock { values = definitions } }
    func setReadFailure(_ error: LibraryChannelError?) { lock.withLock { readFailure = error } }
}

private enum LibraryStoredAuthorityChange: CaseIterable {
    case removed, disabled, replacedSource, replacedProfile

    func applying(to definition: LibraryChannelDefinition) -> [LibraryChannelDefinition] {
        switch self {
        case .removed:
            return []
        case .disabled:
            var changed = definition
            changed.isEnabled = false
            return [changed]
        case .replacedSource:
            return [LibraryChannelDefinition(
                id: definition.id, profileID: definition.profileID, revisions: definition.revisions
            )]
        case .replacedProfile:
            return [LibraryChannelDefinition(
                id: definition.id, sourceID: definition.sourceID,
                profileID: "other-profile", revisions: definition.revisions
            )]
        }
    }
}

private actor LibrarySnapshotInterleavingStore: LibraryChannelSnapshotStaging {
    private let cache = LibraryChannelSnapshotStore(databaseURL: nil)
    private var readHook: (@Sendable () throws -> Void)?
    private var stageHook: (@Sendable () throws -> Void)?
    private(set) var releasedLeaseCount = 0

    func afterNextRead(_ action: @escaping @Sendable () throws -> Void) { readHook = action }
    func afterNextStage(_ action: @escaping @Sendable () throws -> Void) { stageHook = action }

    func snapshot(id: UUID, profileID: String) async throws -> LibraryChannelSnapshot? {
        let value = try await cache.snapshot(id: id, profileID: profileID)
        let action = readHook
        readHook = nil
        try action?()
        return value
    }

    func insert(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws {
        try await cache.insert(snapshot, profileID: profileID)
    }

    func stage(_ snapshots: [LibraryChannelSnapshot], profileID: String) async throws -> LibraryChannelSnapshotLease {
        let lease = try await cache.stage(snapshots, profileID: profileID)
        let action = stageHook
        stageHook = nil
        do {
            try action?()
            return lease
        } catch {
            await cache.release(lease)
            throw error
        }
    }

    func release(_ lease: LibraryChannelSnapshotLease) async {
        releasedLeaseCount += 1
        await cache.release(lease)
    }

    func retain(ids: Set<UUID>, profileID: String) async throws {
        try await cache.retain(ids: ids, profileID: profileID)
    }

    func retainReferenced(by store: any LibraryChannelDefinitionStoring, profileID: String) async throws {
        try await cache.retainReferenced(by: store, profileID: profileID)
    }
}

private actor LibraryCatalogFixture: LibraryChannelCatalogProviding {
    let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    let items: [MediaItem]
    private(set) var pages: [PageRequest] = []
    private(set) var details = 0
    init(items: [MediaItem]) { self.items = items }
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        pages.append(page)
        let selected = items.filter { $0.kind == kind }
        return MediaPage(items: Array(selected.dropFirst(page.startIndex).prefix(page.limit)),
                         startIndex: page.startIndex, totalCount: selected.count)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { details += 1; throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
