#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LibraryChannelAutomaticTests: XCTestCase {
    private let now = Date()
    private let reference = LibraryChannelLibrary(accountID: "account", libraryID: "library")

    private func movie(_ id: String, runtime: Double? = 100) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .movie, runtime: runtime)
        item.libraryID = "library"
        return item
    }

    private func service(
        items: [MediaItem], store: LibraryDefinitionMemory = LibraryDefinitionMemory(),
        cache: (any LibraryChannelSnapshotStoring)? = nil,
        allowed: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in true }
    ) async throws -> (LibraryChannelService, LibraryCatalogFixture, any LibraryChannelSnapshotStoring) {
        let provider = LibraryCatalogFixture(items: items)
        let cache = cache ?? LibraryChannelSnapshotStore(databaseURL: nil)
        let service = LibraryChannelService(
            profileID: "profile", store: store, snapshotStore: cache, isSourceAllowed: allowed
        )
        service.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "authorized", provider: provider, allowedLibraryIDs: ["library"]
        )])
        try await service.load()
        return (service, provider, cache)
    }

    private func currentItems(_ key: String, service: LibraryChannelService) throws -> [LibraryChannelItem] {
        let state = try service.portableState()
        let definition = try XCTUnwrap(state.definitions.first { $0.automaticKey == key })
        let snapshotID = try XCTUnwrap(definition.revisions.last?.snapshotID)
        return try XCTUnwrap(state.snapshots.first { $0.id == snapshotID }).items
    }

    func testCatchallsCoverAllEligibleConcreteContentWithOnePaginationPass() async throws {
        var items = (0..<501).map { movie("m\($0)") }
        for index in 0..<251 {
            var item = movie("e\(index)")
            item.kind = .episode
            item.seriesID = "series"
            items.append(item)
        }
        var series = movie("series", runtime: nil)
        series.kind = .series
        items += [series, movie("invalid", runtime: nil), movie("zero", runtime: 0), movie("nan", runtime: .nan)]
        let (service, provider, _) = try await service(items: items)
        let summary = try await service.refreshAutomaticChannels(at: now)
        XCTAssertEqual(summary.channelCount, 2)
        XCTAssertEqual(summary.eligibleItemCount, 752)
        XCTAssertEqual(summary.skippedItemCount, 3)
        XCTAssertEqual(Set(try currentItems("v1/movies", service: service).map(\.itemID)),
                       Set((0..<501).map { "m\($0)" }))
        XCTAssertEqual(Set(try currentItems("v1/tv", service: service).map(\.itemID)),
                       Set((0..<251).map { "e\($0)" }))
        let queries = await provider.queries
        XCTAssertEqual(queries.filter { $0.kind == .movie }.map(\.page.startIndex), [0, 250, 500])
        XCTAssertEqual(queries.filter { $0.kind == .episode }.map(\.page.startIndex), [0, 250])
        XCTAssertEqual(queries.filter { $0.kind == .series }.count, 1)
        let details = await provider.details
        XCTAssertEqual(details, 0)
        XCTAssertTrue(try service.portableState().snapshots.flatMap(\.items).allSatisfy { $0.kind != .series })
    }

    func testActualMetadataProducesDiverseThemesWithoutInventingKidsOrDirectors() throws {
        var entries: [LibraryChannelAutomaticCatalog.Entry] = []
        for index in 0..<80 {
            var media = movie("m\(index)")
            media.officialRating = index < 8 ? "G" : (index < 16 ? "PG" : "R")
            let item = try LibraryChannelItem(item: media, library: reference, serverID: "server", userID: "user")
            entries.append(.init(
                item: item,
                genres: index < 12 ? ["Comedy"] : (index < 24 ? ["Animation"] : []),
                studios: (24..<36).contains(index) ? ["Actual Studio"] : [],
                directors: (36..<44).contains(index) ? ["Actual Director"] : [],
                year: (44..<56).contains(index) ? 1994 : nil
            ))
        }
        let groups = try LibraryChannelAutomaticPlanner.groups(
            catalog: LibraryChannelAutomaticCatalog(entries: entries), profileID: "profile"
        )
        let keys = Set(groups.map(\.key))
        XCTAssertTrue(keys.contains("v1/genre/comedy"))
        XCTAssertTrue(keys.contains("v1/decade/1990"))
        XCTAssertTrue(keys.contains("v1/studio/actual studio"))
        XCTAssertTrue(keys.contains("v1/director/actual director"))
        XCTAssertTrue(keys.contains("v1/kids"))
        XCTAssertTrue(keys.contains("v1/family"))
        let animation = try XCTUnwrap(groups.first { $0.key == "v1/animation" || $0.key == "v1/genre/animation" })
        XCTAssertTrue(animation.items.contains { $0.rating == "R" })
        XCTAssertTrue(try XCTUnwrap(groups.first { $0.key == "v1/kids" }).items.allSatisfy { $0.rating == "G" })
        XCTAssertTrue(try XCTUnwrap(groups.first { $0.key == "v1/family" }).items.allSatisfy { ["G", "PG"].contains($0.rating) })
        XCTAssertFalse(keys.contains(where: { $0.contains("spielberg") }))
        XCTAssertLessThanOrEqual(groups.count, 26)
    }

    func testSeriesGenresStudiosRatingsAndYearAreInheritedButNotDirectorCredits() async throws {
        var show = movie("show", runtime: nil)
        show.kind = .series
        show.title = "Show"
        show.genres = ["Comedy"]
        show.studios = ["Actual Network"]
        show.productionYear = 1994
        show.officialRating = "TV-G"
        show.people = [MediaPerson(id: "director", name: "Series Director", kind: "Director")]
        var episode = movie("episode")
        episode.kind = .episode
        episode.seriesID = show.id
        let provider = LibraryCatalogFixture(items: [show, episode])
        let catalog = try await LibraryChannelAutomaticCatalog.fetch(contexts: [
            LibraryChannelProviderContext(
                accountID: "account", authorizationID: "auth", provider: provider, allowedLibraryIDs: ["library"]
            )
        ], checkAuthorization: {})
        let entry = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(entry.item.itemID, "episode")
        XCTAssertEqual(entry.item.seriesTitle, "Show")
        XCTAssertEqual(entry.genres, ["Comedy"])
        XCTAssertEqual(entry.studios, ["Actual Network"])
        XCTAssertEqual(entry.item.rating, "TV-G")
        XCTAssertEqual(entry.year, 1994)
        XCTAssertTrue(entry.directors.isEmpty)
    }

    func testUnratedAnimationAndOneTitleNichesDoNotBecomeKidsOrNicheChannels() throws {
        let entries = try (0..<12).map { index -> LibraryChannelAutomaticCatalog.Entry in
            var item = movie("e\(index)")
            item.kind = .episode
            item.seriesID = "one-show"
            return .init(
                item: try LibraryChannelItem(item: item, library: reference, serverID: "server", userID: "user"),
                genres: ["Animation"], studios: ["Studio"], directors: ["Director"], year: nil
            )
        }
        let groups = try LibraryChannelAutomaticPlanner.groups(
            catalog: LibraryChannelAutomaticCatalog(entries: entries), profileID: "profile"
        )
        XCTAssertEqual(groups.map(\.key), ["v1/tv"])
    }

    func testReorderedRefreshAndRestartPreserveIdentitiesRevisionsAndEpoch() async throws {
        let store = LibraryDefinitionMemory()
        let items = (0..<10).map { movie("m\($0)") }
        let (service, provider, cache) = try await service(items: items, store: store)
        _ = try await service.refreshAutomaticChannels(at: now)
        let before = try service.portableState()
        await provider.replaceItems(items.reversed())
        _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
        XCTAssertEqual(try service.portableState(), before)
        let reloaded = LibraryChannelService(profileID: "profile", store: store, snapshotStore: cache)
        reloaded.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "new", provider: provider, allowedLibraryIDs: ["library"]
        )])
        try await reloaded.load()
        _ = try await reloaded.refreshAutomaticChannels(at: now.addingTimeInterval(20))
        XCTAssertEqual(try reloaded.portableState(), before)
    }

    func testCachedLoadPreservesHeldAuthorityAndFrozenSchedulesWithoutCatalogQueries() async throws {
        let (service, provider, _) = try await service(items: (0..<12).map { movie("m\($0)") })
        _ = try await service.refreshAutomaticChannels(at: now)
        let definition = try XCTUnwrap(service.definitions.first)
        let programmes = try service.programmes(
            channelIDs: [definition.catalogID], from: now, to: now.addingTimeInterval(350)
        )
        let state = try service.portableState()
        let held = try service.playbackContext(catalogID: definition.catalogID)
        let authorization = held.authorizationID
        let generation = service.generation
        let queriesBefore = await provider.queries.count
        for _ in 0..<2 {
            try await service.load()
            XCTAssertEqual(service.generation, generation)
            XCTAssertEqual(held.authorizationID, authorization)
            XCTAssertEqual(try service.portableState(), state)
            XCTAssertEqual(try service.programmes(
                channelIDs: [definition.catalogID], from: now, to: now.addingTimeInterval(350)
            ), programmes)
        }
        let queriesAfter = await provider.queries.count
        XCTAssertEqual(queriesBefore, queriesAfter)
    }

    func testChangedCatalogAppendsBeyondPublishedGuideAndRemovesItemsOnlyInFuture() async throws {
        let (service, provider, _) = try await service(items: [movie("old"), movie("kept")])
        _ = try await service.refreshAutomaticChannels(at: now)
        let initial = try XCTUnwrap(service.definitions.first)
        let before = try service.programmes(
            channelIDs: [initial.catalogID], from: now, to: now.addingTimeInterval(350)
        )
        let frozenThrough = try XCTUnwrap(service.definitions.first?.publishedThrough)
        await provider.replaceItems([movie("kept"), movie("new")])
        _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
        let changed = try XCTUnwrap(service.definitions.first)
        XCTAssertEqual(changed.id, initial.id)
        XCTAssertEqual(changed.sourceID, initial.sourceID)
        XCTAssertEqual(changed.revisions.count, 2)
        XCTAssertGreaterThan(changed.revisions[1].epochSeconds, frozenThrough)
        XCTAssertEqual(try service.programmes(channelIDs: [initial.catalogID], from: now, to: now.addingTimeInterval(350)), before)
        XCTAssertEqual(Set(try currentItems("v1/movies", service: service).map(\.itemID)), ["kept", "new"])
        let future = Date(timeIntervalSince1970: Double(changed.revisions[1].epochSeconds))
        XCTAssertEqual(try service.slot(channelID: changed.id, at: future, now: now).revisionID, changed.revisions[1].id)
    }

    func testGlobalToggleRevokesHeldAutomaticPlaybackWithoutQueryingOrChangingCustoms() async throws {
        let (service, provider, _) = try await service(items: [movie("movie")])
        let preview = try await service.preview(recipe: LibraryChannelRecipe(
            name: "Custom", libraries: [reference], includesEpisodes: false
        ), at: now)
        let custom = try await service.publish(preview, at: now)
        _ = try await service.refreshAutomaticChannels(at: now)
        let automatic = try XCTUnwrap(service.definitions.first(where: \.isAutomatic))
        let held = try service.playbackContext(catalogID: automatic.catalogID)
        let customHeld = try service.playbackContext(catalogID: custom.catalogID)
        let before = await provider.queries.count
        try service.setAutomaticChannelsEnabled(false)
        XCTAssertNil(held.authorizationID)
        XCTAssertNil(held.schedule())
        XCTAssertNotNil(customHeld.authorizationID)
        XCTAssertEqual(service.definitions.first { !$0.isAutomatic }, custom)
        try service.setAutomaticChannelsEnabled(true)
        XCTAssertNotNil(held.authorizationID)
        XCTAssertEqual(service.definitions.first(where: \.isAutomatic), automatic)
        let after = await provider.queries.count
        XCTAssertEqual(before, after)
    }

    func testAutomaticDefinitionsRejectManualPreviewPublishAndDelete() async throws {
        let store = LibraryDefinitionMemory()
        let cache = LibrarySnapshotInterleavingStore()
        let (service, provider, _) = try await service(items: [movie("movie")], store: store, cache: cache)
        _ = try await service.refreshAutomaticChannels(at: now)
        let automatic = try XCTUnwrap(service.definitions.first)
        let recipe = try XCTUnwrap(automatic.revisions.last?.recipe)
        let customPreview = try await service.preview(recipe: recipe, at: now)
        let before = try service.portableState()
        let held = try service.playbackContext(catalogID: automatic.catalogID)
        let authorization = held.authorizationID
        let queriesBefore = await provider.queries.count
        do {
            _ = try await service.preview(recipe: recipe, editingChannelID: automatic.id, at: now)
            XCTFail("Automatic definitions have no manual editor")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidRecipe) }
        do {
            _ = try await service.publish(customPreview, editingChannelID: automatic.id, at: now)
            XCTFail("Manual publication cannot replace an automatic definition")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidRecipe) }
        do {
            try await service.delete(channelID: automatic.id)
            XCTFail("Only automatic refresh can retire a generated definition")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidRecipe) }
        let queriesAfter = await provider.queries.count
        let releases = await cache.releasedLeaseCount
        XCTAssertEqual(queriesAfter, queriesBefore)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(try service.portableState(), before)
        XCTAssertEqual(try store.load(), before.definitions)
        XCTAssertEqual(held.authorizationID, authorization)
        let custom = try await service.publish(customPreview, at: now)
        XCTAssertFalse(custom.isAutomatic)
        XCTAssertNotEqual(custom.id, automatic.id)
        XCTAssertEqual(service.definitions.first { $0.id == automatic.id }, automatic)
    }

    func testEmptyCatalogRetiresAutomaticDefinitionsWithoutDeletingCustoms() async throws {
        let (service, provider, _) = try await service(items: [movie("movie")])
        let preview = try await service.preview(recipe: LibraryChannelRecipe(name: "Custom", libraries: [reference]), at: now)
        let custom = try await service.publish(preview, at: now)
        _ = try await service.refreshAutomaticChannels(at: now)
        let automatic = try XCTUnwrap(service.definitions.first(where: \.isAutomatic))
        let held = try service.playbackContext(catalogID: automatic.catalogID)
        await provider.replaceItems([])
        let summary = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
        XCTAssertEqual(summary, LibraryChannelAutomaticGenerationSummary())
        XCTAssertNil(held.authorizationID)
        XCTAssertEqual(service.definitions.first { $0.id == custom.id }, custom)
        XCTAssertNil(service.definitions.first { $0.id == automatic.id })
        try service.setAutomaticChannelsEnabled(true)
        XCTAssertNil(held.authorizationID)
    }

    func testMissingSnapshotsRecoverSameIDsOnlyAfterFrozenHorizon() async throws {
        let store = LibraryDefinitionMemory()
        let (service, provider, _) = try await service(items: [movie("movie")], store: store)
        _ = try await service.refreshAutomaticChannels(at: now)
        let original = try XCTUnwrap(service.definitions.first)
        _ = try service.programmes(channelIDs: [original.catalogID], from: now, to: now.addingTimeInterval(400))
        let horizon = try XCTUnwrap(service.definitions.first?.publishedThrough)
        let fresh = LibraryChannelService(
            profileID: "profile", store: store, snapshotStore: LibraryChannelSnapshotStore(databaseURL: nil)
        )
        fresh.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "auth", provider: provider, allowedLibraryIDs: ["library"]
        )])
        try await fresh.load()
        XCTAssertEqual(fresh.issue, .snapshotUnavailable)
        _ = try await fresh.refreshAutomaticChannels(at: now.addingTimeInterval(10))
        let rebuilt = try XCTUnwrap(fresh.definitions.first)
        XCTAssertEqual(rebuilt.id, original.id)
        XCTAssertEqual(rebuilt.sourceID, original.sourceID)
        XCTAssertGreaterThan(rebuilt.revisions[0].epochSeconds, horizon)
        XCTAssertThrowsError(try fresh.slot(channelID: rebuilt.id, at: now, now: now))
        XCTAssertEqual(try fresh.slot(
            channelID: rebuilt.id, at: Date(timeIntervalSince1970: Double(rebuilt.revisions[0].epochSeconds)), now: now
        ).item.itemID, "movie")
    }

    func testInvalidItemMetadataFailsWithoutReplacingDurableLineup() async throws {
        let store = LibraryDefinitionMemory()
        let (service, provider, _) = try await service(items: [movie("good")], store: store)
        _ = try await service.refreshAutomaticChannels(at: now)
        let previous = try store.load()
        await provider.replaceItems([movie("https://unsafe.invalid")])
        do {
            _ = try await service.refreshAutomaticChannels(at: now)
            XCTFail("Malformed addressing must not publish")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidSnapshot) }
        XCTAssertEqual(try store.load(), previous)
        XCTAssertEqual(service.definitions, previous)
    }

    func testCancellationContextLossAndGlobalDisableFenceInFlightRefresh() async throws {
        for action in ["cancel", "context", "update", "disable"] {
            let store = LibraryDefinitionMemory()
            let (service, provider, _) = try await service(items: [movie("old")], store: store)
            _ = try await service.refreshAutomaticChannels(at: now)
            let gate = LibraryAutomaticGate()
            await provider.replaceItems([movie("new")])
            await provider.beforeNextPage { await gate.pause() }
            let refresh = Task { try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10)) }
            await gate.entered()
            switch action {
            case "cancel": refresh.cancel()
            case "context": service.setContexts([])
            case "update": service.updateContexts([])
            default: try service.setAutomaticChannelsEnabled(false)
            }
            let expected = try store.load()
            await gate.resume()
            do {
                _ = try await refresh.value
                XCTFail("Superseded refresh must not publish")
            } catch {
                if action == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
            }
            XCTAssertEqual(try store.load(), expected)
            XCTAssertEqual(service.definitions, expected)
        }
    }

    func testDisableFencesFirstGenerationWithNoAutomaticDefinitionsEvenWhenDisableThrows() async throws {
        for hasCustom in [false, true] {
            for failure in ["none", "storage", "cancelledCaller"] {
                let store = LibraryDefinitionMemory()
                let (service, provider, _) = try await service(items: [movie("movie")], store: store)
                var heldCustom: LibraryChannelPlaybackContext?
                if hasCustom {
                    let preview = try await service.preview(recipe: LibraryChannelRecipe(
                        name: "Custom", libraries: [reference], includesEpisodes: false
                    ), at: now)
                    let custom = try await service.publish(preview, at: now)
                    heldCustom = try service.playbackContext(catalogID: custom.catalogID)
                }
                let customAuthorization = heldCustom?.authorizationID
                let previous = try store.load()
                XCTAssertFalse(previous.contains(where: \.isAutomatic))
                let gate = LibraryAutomaticGate()
                await provider.beforeNextPage { await gate.pause() }
                let refresh = Task { try await service.refreshAutomaticChannels(at: now) }
                await gate.entered()
                let queriesBeforeDisable = await provider.queries.count
                if failure == "storage" { store.setWriteFailure(.storageFailed) }
                do {
                    if failure == "cancelledCaller" {
                        try await Task {
                            withUnsafeCurrentTask { $0?.cancel() }
                            try service.setAutomaticChannelsEnabled(false)
                        }.value
                    } else {
                        try service.setAutomaticChannelsEnabled(false)
                    }
                    XCTAssertEqual(failure, "none")
                } catch {
                    if failure == "cancelledCaller" { XCTAssertTrue(error is CancellationError) }
                    else {
                        XCTAssertEqual(failure, "storage")
                        XCTAssertEqual(error as? LibraryChannelError, .storageFailed)
                    }
                }
                await gate.resume()
                do {
                    _ = try await refresh.value
                    XCTFail("The first generation must not publish after disable")
                } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
                let queriesAfterDisable = await provider.queries.count
                XCTAssertEqual(queriesAfterDisable, queriesBeforeDisable)
                XCTAssertEqual(service.definitions, previous)
                XCTAssertEqual(try store.load(), previous)
                XCTAssertEqual(heldCustom?.authorizationID, customAuthorization)
            }
        }
    }

    func testStorageFailureAndConcurrentPortableCommitDoNotPublishPartialBatch() async throws {
        for failure in ["storage", "conflict"] {
            let store = LibraryDefinitionMemory()
            let cache = LibrarySnapshotInterleavingStore()
            let (service, provider, _) = try await service(items: [movie("old")], store: store, cache: cache)
            _ = try await service.refreshAutomaticChannels(at: now)
            let previous = try store.load()
            await provider.replaceItems([movie("new")])
            var remote = previous
            remote[0].isEnabled = false
            let incoming = remote
            if failure == "storage" { store.setWriteFailure(.storageFailed) }
            else { await cache.afterNextStage { try store.save(incoming) } }
            do {
                _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
                XCTFail("Failed commit must leave prior state")
            } catch {
                XCTAssertEqual(error as? LibraryChannelError, failure == "storage" ? .storageFailed : .publicationConflict)
            }
            XCTAssertEqual(service.definitions, previous)
            XCTAssertEqual(try store.load(), failure == "storage" ? previous : incoming)
            let releases = await cache.releasedLeaseCount
            XCTAssertEqual(releases, 2)
        }
    }

    func testSourceApprovalRevocationDuringStagingRejectsEntireBatch() async throws {
        let approval = LibraryAutomaticApproval()
        let store = LibraryDefinitionMemory()
        let cache = LibrarySnapshotInterleavingStore()
        let (service, provider, _) = try await service(
            items: [movie("old")], store: store, cache: cache, allowed: { _ in approval.isAllowed }
        )
        _ = try await service.refreshAutomaticChannels(at: now)
        let original = try store.load()
        await provider.replaceItems([movie("new")])
        await cache.afterNextStage { approval.revoke() }
        do {
            _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
            XCTFail("Revocation must win over staged snapshots")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(service.definitions, original)
        XCTAssertTrue(service.channels.isEmpty)
    }

    func testDuplicateProviderItemsAbortWithoutChangingDurableLineup() async throws {
        let store = LibraryDefinitionMemory()
        let (service, provider, _) = try await service(items: [movie("old")], store: store)
        _ = try await service.refreshAutomaticChannels(at: now)
        let original = try store.load()
        await provider.replaceItems([movie("duplicate"), movie("duplicate")])
        do {
            _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
            XCTFail("Unstable pagination must not publish")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .catalogChanged) }
        XCTAssertEqual(service.definitions, original)
        XCTAssertEqual(try store.load(), original)
    }

    func testDiscoveredLibraryLossRevokesHeldPlaybackEvenWhenPublicationFails() async throws {
        let store = LibraryDefinitionMemory()
        let (service, provider, _) = try await service(items: [movie("old")], store: store)
        var kept = movie("kept")
        kept.libraryID = "second"
        await provider.replaceItems([movie("old"), kept])
        await provider.replaceLibraries([
            MediaLibrary(id: "library", title: "Original", kind: .movie),
            MediaLibrary(id: "second", title: "Kept", kind: .movie)
        ])
        service.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "auth", provider: provider, allowedLibraryIDs: ["library", "second"]
        )])
        _ = try await service.refreshAutomaticChannels(at: now)
        let original = try store.load()
        let held = try service.playbackContext(catalogID: original[0].catalogID)
        let removed = try XCTUnwrap(currentItems("v1/movies", service: service).first { $0.library == reference })
        await provider.replaceLibraries([MediaLibrary(id: "second", title: "Kept", kind: .movie)])
        await provider.replaceItems([kept])
        store.setWriteFailure(.storageFailed)
        do {
            _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
            XCTFail("Publication should fail but permission loss must still take effect")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .storageFailed) }
        XCTAssertNil(held.authorizationID)
        XCTAssertFalse(service.isAuthorized(removed))
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(service.definitions, original)
    }

    func testAllowedLibrariesAndSourceApprovalsCannotBeBypassedByAutomaticPlanner() async throws {
        let movieSource = LibraryChannelAutomaticIdentity.sourceID(profileID: "profile", key: "v1/movies")
        let (service, provider, _) = try await service(items: [movie("allowed")], allowed: { $0 != movieSource })
        var hidden = movie("hidden")
        hidden.libraryID = "forbidden"
        await provider.replaceItems([movie("allowed"), hidden])
        await provider.replaceLibraries([
            MediaLibrary(id: "library", title: "Allowed", kind: .movie),
            MediaLibrary(id: "forbidden", title: "Forbidden", kind: .movie)
        ])
        let summary = try await service.refreshAutomaticChannels(at: now)
        XCTAssertEqual(summary.eligibleItemCount, 1)
        XCTAssertEqual(summary.channelCount, 0)
        XCTAssertTrue(service.channels.isEmpty)
        let queries = await provider.queries
        XCTAssertEqual(queries.map(\.libraryID), ["library"])
    }

    func testCatchallCapacityIsExplicitRatherThanTruncatingAuthorizedContent() throws {
        var catalog = LibraryChannelAutomaticCatalog(entries: try (0..<LibraryChannelSnapshot.maximumItems).map { index in
            LibraryChannelAutomaticCatalog.Entry(
                item: try LibraryChannelItem(item: movie("m\(index)"), library: reference, serverID: "server", userID: "user"),
                genres: [], studios: [], directors: [], year: nil
            )
        })
        let exact = try LibraryChannelAutomaticPlanner.groups(catalog: catalog, profileID: "profile")
        XCTAssertEqual(exact.first?.items.count, 50_000)
        XCTAssertEqual(Set(try XCTUnwrap(exact.first).items.map(\.itemID)).count, 50_000)
        catalog.entries.append(.init(
            item: try LibraryChannelItem(item: movie("extra"), library: reference, serverID: "server", userID: "user"),
            genres: [], studios: [], directors: [], year: nil
        ))
        XCTAssertThrowsError(try LibraryChannelAutomaticPlanner.groups(catalog: catalog, profileID: "profile")) {
            XCTAssertEqual($0 as? LibraryChannelError, .catalogTooLarge)
        }
    }

    func testAggregateSnapshotLimitIsEnforcedAtExactlyTwoHundredThousand() throws {
        let items = try (0..<50_000).map {
            try LibraryChannelItem(item: movie("m\($0)"), library: reference, serverID: "server", userID: "user")
        }
        let recipe = LibraryChannelRecipe(name: "Custom", libraries: [reference])
        var snapshots = try (0..<3).map { _ in try LibraryChannelSnapshot(items: items, createdAt: now) }
        snapshots.append(try LibraryChannelSnapshot(items: Array(items.dropLast()), createdAt: now))
        let customs = snapshots.map { snapshot in
            LibraryChannelDefinition(profileID: "profile", revisions: [
                LibraryChannelRevision(snapshotID: snapshot.id, recipe: recipe, epochSeconds: Int64(now.timeIntervalSince1970))
            ])
        }
        let one = LibraryChannelAutomaticPlanner.Group(key: "v1/movies", recipe: recipe, items: [items[0]], isCatchall: true)
        let exact = try LibraryChannelAutomaticPublication.prepare(
            groups: [one], profileID: "profile", previous: customs,
            snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) }),
            schedules: [:], blockedSourceIDs: [], now: now
        )
        XCTAssertEqual(exact.snapshots.values.reduce(0) { $0 + $1.items.count }, 200_000)
        let two = LibraryChannelAutomaticPlanner.Group(key: "v1/movies", recipe: recipe, items: Array(items.prefix(2)), isCatchall: true)
        XCTAssertThrowsError(try LibraryChannelAutomaticPublication.prepare(
            groups: [two], profileID: "profile", previous: customs,
            snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) }),
            schedules: [:], blockedSourceIDs: [], now: now
        )) { XCTAssertEqual($0 as? LibraryChannelError, .catalogTooLarge) }
    }

    func testCustomDefinitionsReserveTheirSlotsBeforeOptionalThemes() throws {
        let item = try LibraryChannelItem(item: movie("movie"), library: reference, serverID: "server", userID: "user")
        let snapshot = try LibraryChannelSnapshot(items: [item], createdAt: now)
        let recipe = LibraryChannelRecipe(name: "Custom", libraries: [reference])
        let customs = (0..<99).map { _ in
            LibraryChannelDefinition(profileID: "profile", revisions: [
                LibraryChannelRevision(snapshotID: snapshot.id, recipe: recipe, epochSeconds: Int64(now.timeIntervalSince1970))
            ])
        }
        let catchall = LibraryChannelAutomaticPlanner.Group(key: "v1/movies", recipe: recipe, items: [item], isCatchall: true)
        let theme = LibraryChannelAutomaticPlanner.Group(key: "v1/genre/comedy", recipe: recipe, items: [item], isCatchall: false)
        let publication = try LibraryChannelAutomaticPublication.prepare(
            groups: [catchall, theme], profileID: "profile", previous: customs,
            snapshots: [snapshot.id: snapshot], schedules: [:], blockedSourceIDs: [], now: now
        )
        XCTAssertEqual(publication.definitions.count, 100)
        XCTAssertEqual(publication.definitions.filter { !$0.isAutomatic }, customs)
        let required = LibraryChannelAutomaticPlanner.Group(key: "v1/tv", recipe: recipe, items: [item], isCatchall: true)
        XCTAssertThrowsError(try LibraryChannelAutomaticPublication.prepare(
            groups: [catchall, required], profileID: "profile", previous: customs,
            snapshots: [snapshot.id: snapshot], schedules: [:], blockedSourceIDs: [], now: now
        )) { XCTAssertEqual($0 as? LibraryChannelError, .catalogTooLarge) }
    }

    func testInvalidRefreshDateDoesNotQueryOrPublish() async throws {
        let (service, provider, _) = try await service(items: [movie("movie")])
        do {
            _ = try await service.refreshAutomaticChannels(at: Date(timeIntervalSince1970: .infinity))
            XCTFail("Invalid schedule epoch")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidSnapshot) }
        let queries = await provider.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(service.definitions.isEmpty)
    }

    func testMetadataGroupCapIsDeterministicAcrossProviderReordering() throws {
        var policy = LibraryChannelAutomaticPlanner.Policy()
        policy.maximumMetadataGroups = 3
        policy.minimumThemeItems = 2
        let entries = try (0..<40).map { index in
            LibraryChannelAutomaticCatalog.Entry(
                item: try LibraryChannelItem(item: movie("m\(index)"), library: reference, serverID: "server", userID: "user"),
                genres: ["Genre \(index % 8)"], studios: [], directors: [], year: nil
            )
        }
        let forward = try LibraryChannelAutomaticPlanner.groups(
            catalog: LibraryChannelAutomaticCatalog(entries: entries), profileID: "profile", policy: policy
        )
        let reverse = try LibraryChannelAutomaticPlanner.groups(
            catalog: LibraryChannelAutomaticCatalog(entries: entries.reversed()), profileID: "profile", policy: policy
        )
        XCTAssertEqual(forward.map(\.key), reverse.map(\.key))
        XCTAssertEqual(forward.map { Set($0.items.map(\.id)) }, reverse.map { Set($0.items.map(\.id)) })
    }

    func testEquivalentContextUpdatesPreserveHeldPlaybackChoicesAndSchedules() async throws {
        let items = [movie("one"), movie("two")]
        let (service, provider, _) = try await service(items: items)
        let original = LibraryChannelProviderContext(
            accountID: "account", authorizationID: "authorized", provider: provider, allowedLibraryIDs: ["library"]
        )
        let unused = LibraryChannelProviderContext(
            accountID: "unused", authorizationID: "unused", provider: provider, allowedLibraryIDs: []
        )
        service.setContexts([original, unused])
        _ = try await service.refreshAutomaticChannels(at: now)
        let definition = try XCTUnwrap(service.definitions.first)
        let held = try service.playbackContext(catalogID: definition.catalogID)
        let authorization = held.authorizationID
        let generation = service.generation
        let choices = service.libraryChoices
        let state = try service.portableState()
        var renamed = provider.session
        renamed.server.name = "New display name"
        renamed.server.version = "New version"
        renamed.userName = "New display name"
        renamed.avatarURL = URL(string: "https://server.invalid/new-avatar")
        let recreated = LibraryCatalogFixture(items: items, session: renamed)
        service.updateContexts([
            unused,
            LibraryChannelProviderContext(
                accountID: "account", authorizationID: "authorized", provider: recreated, allowedLibraryIDs: ["library"]
            )
        ])
        XCTAssertEqual(service.generation, generation)
        XCTAssertEqual(service.libraryChoices, choices)
        XCTAssertEqual(held.authorizationID, authorization)
        let requests = await recreated.queries
        XCTAssertTrue(requests.isEmpty)
        _ = try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10))
        XCTAssertEqual(try service.portableState(), state)
        XCTAssertEqual(held.authorizationID, authorization)
        XCTAssertNotNil(held.schedule())
    }

    func testContextAuthorityChangesInvalidateHeldPlaybackWithoutChangingDefinitions() async throws {
        for field in ["account", "authorization", "libraries", "provider", "serverProvider", "server", "url", "user", "device", "token"] {
            let (service, provider, _) = try await service(items: [movie("movie")])
            _ = try await service.refreshAutomaticChannels(at: now)
            let definitions = service.definitions
            let held = try service.playbackContext(catalogID: definitions[0].catalogID)
            let generation = service.generation
            var session = provider.session
            switch field {
            case "serverProvider": session.server.provider = .plex
            case "server": session.server.id = "another-server"
            case "url": session.server.baseURL = URL(string: "https://another.invalid")!
            case "user": session.userID = "another-user"
            case "device": session.deviceID = "another-device"
            case "token": session.accessToken = "another-fixture"
            default: break
            }
            let replacement = LibraryCatalogFixture(items: [], session: session, kind: field == "provider" ? .plex : .jellyfin)
            service.updateContexts([LibraryChannelProviderContext(
                accountID: field == "account" ? "another-account" : "account",
                authorizationID: field == "authorization" ? "another-authorization" : "authorized",
                provider: replacement, allowedLibraryIDs: field == "libraries" ? [] : ["library"]
            )])
            XCTAssertNotEqual(service.generation, generation, field)
            XCTAssertNil(held.authorizationID, field)
            XCTAssertNil(held.schedule(), field)
            XCTAssertTrue(service.libraryChoices.isEmpty, field)
            XCTAssertEqual(service.definitions, definitions, field)
        }
    }

    func testEquivalentContextUpdateDoesNotCancelInFlightAutomaticRefresh() async throws {
        let (service, provider, _) = try await service(items: [movie("movie")])
        _ = try await service.refreshAutomaticChannels(at: now)
        let state = try service.portableState()
        let held = try service.playbackContext(catalogID: service.definitions[0].catalogID)
        let gate = LibraryAutomaticGate()
        await provider.beforeNextPage { await gate.pause() }
        let refresh = Task { try await service.refreshAutomaticChannels(at: now.addingTimeInterval(10)) }
        await gate.entered()
        let generation = service.generation
        service.updateContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "authorized", provider: provider, allowedLibraryIDs: ["library"]
        )])
        XCTAssertEqual(service.generation, generation)
        await gate.resume()
        _ = try await refresh.value
        XCTAssertEqual(try service.portableState(), state)
        XCTAssertNotNil(held.authorizationID)
    }

    func testExplicitSetContextsStillInvalidatesEquivalentAuthorization() async throws {
        let (service, provider, _) = try await service(items: [movie("movie")])
        _ = try await service.refreshAutomaticChannels(at: now)
        let held = try service.playbackContext(catalogID: service.definitions[0].catalogID)
        let generation = service.generation
        service.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "authorized", provider: provider, allowedLibraryIDs: ["library"]
        )])
        XCTAssertNotEqual(service.generation, generation)
        XCTAssertNil(held.authorizationID)
        XCTAssertTrue(service.libraryChoices.isEmpty)
    }
}

private actor LibraryAutomaticGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var didEnter = false

    func pause() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            didEnter = true
            observer?.resume()
            observer = nil
        }
    }

    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        waiting?.resume()
        waiting = nil
    }
}

private final class LibraryAutomaticApproval: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var isAllowed: Bool { lock.withLock { allowed } }
    func revoke() { lock.withLock { allowed = false } }
}
#endif
