#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVIndexedCacheTests: XCTestCase {
    func testPortableMappingNotificationsAreChangedOnlyAndFollowDurableWrites() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let changed = expectation(description: "Mapping added and removed")
        changed.expectedFulfillmentCount = 2
        changed.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: .plozzLiveTVPortableStateDidChange, object: nil, queue: nil
        ) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let mapping = LiveTVGuideMappingOverride(guideSourceID: "guide", guideChannelID: "station")
        try await fixture.cache.setMapping(mapping, channelID: "channel")
        try await fixture.cache.setMapping(mapping, channelID: "channel")
        let saved = try await fixture.cache.mappingOverrides()
        XCTAssertEqual(saved["channel"], mapping)
        try await fixture.cache.setMapping(nil, channelID: "channel")
        try await fixture.cache.setMapping(nil, channelID: "channel")
        do {
            try await fixture.cache.setMapping(mapping, channelID: "")
            XCTFail("Invalid mappings must not be published.")
        } catch {
            XCTAssertEqual(error as? LiveTVCacheError, .invalidRecord)
        }
        await fulfillment(of: [changed], timeout: 1)
    }

    @MainActor
    func testIndexedSearchAppliesAllowedAndCurrentCatalogIDsBeforeLimit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml"))
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/source.m3u")),
            guideURLs: [guideURL]
        )
        let guideID = try XCTUnwrap(source.guideSourceIDs.first)
        let resolved = try await fixture.cache.reconcile(playlist([channel(0), channel(1)]), sourceID: source.id)
        try await fixture.cache.storePlaylist(resolved.playlist, source: source, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        var xml = "<tv><channel id=\"g0\"><display-name>Denied</display-name></channel>"
            + "<channel id=\"g1\"><display-name>Allowed</display-name></channel>"
        for index in 0..<301 {
            let start = now.addingTimeInterval(Double(index) * 60)
            xml += """
            <programme channel="\(index == 300 ? "g1" : "g0")" start="\(formatter.string(from: start))" stop="\(formatter.string(from: start.addingTimeInterval(60)))"><title>Needle \(index)</title></programme>
            """
        }
        xml += "</tv>"
        _ = try await fixture.cache.importGuide(
            data: Data(xml.utf8), sourceID: guideID, channels: resolved.playlist.channels,
            provider: nil, now: now, sourceURL: guideURL
        )
        let allowedChannel = resolved.playlist.channels[1]
        let range = DateInterval(start: now, duration: 8 * 3_600)
        let filtered = try await fixture.cache.searchPrograms(
            query: "Needle", sourceIDs: [guideID], range: range, limit: 1,
            selectedSourceByChannel: Dictionary(uniqueKeysWithValues: resolved.playlist.channels.map { ($0.id, guideID) }),
            allowedChannelIDs: [allowedChannel.id], sourceURLs: [guideID: guideURL]
        )
        XCTAssertEqual(filtered.map(\.title), ["Needle 300"])
        let zero = try await fixture.cache.searchPrograms(
            query: "Needle", sourceIDs: [guideID], range: range, limit: 0, sourceURLs: [guideID: guideURL]
        )
        XCTAssertTrue(zero.isEmpty)

        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [source]), loader: IndexedImportFixtureLoader(now: now), cache: fixture.cache
        )
        let originalCatalog = LiveTVPrototypeModel(now: now, channels: [])
        await imports.restoreCachedCatalog(into: originalCatalog, now: now)
        let currentCatalog = LiveTVPrototypeModel(now: now, channels: [allowedChannel])
        let found = try await imports.searchPrograms(
            query: "Needle", range: range, limit: 1, catalog: currentCatalog
        )
        XCTAssertEqual(found.map(\.title), ["Needle 300"], "Unknown cached IDs must not consume the result budget.")
    }

    @MainActor
    func testStandaloneSourcesRestoresWithoutNetworkingAndCanSaveGuideCorrections() async throws {
        let fixture = try SourcesCatalogFixture()
        defer { fixture.removeOwnedFiles() }
        await fixture.seed()
        let count = await fixture.loader.playlistRequestCount
        let controller = fixture.controller()
        await controller.restore()
        XCTAssertTrue(controller.isCurrent)
        XCTAssertNil(controller.issue)
        let id = try XCTUnwrap(controller.catalog.channels.first?.id)
        let restoredRequestCount = await fixture.loader.playlistRequestCount
        XCTAssertEqual(restoredRequestCount, count)
        XCTAssertEqual(controller.catalog.currentProgram(for: id)?.title, "Current")
        let guideID = try XCTUnwrap(fixture.configuration.playlists.first?.guideSourceIDs.first)
        try await controller.imports.setGuideMapping(channelID: id, guideSourceID: guideID, guideChannelID: "g")
        let mappings = try await fixture.cache.cache.mappingOverrides()
        XCTAssertEqual(mappings[id]?.guideSourceID, guideID)
        XCTAssertEqual(controller.catalog.currentProgram(for: id)?.title, "Current")
    }

    @MainActor
    func testStandaloneSourcesNeverHydratesAnUnapprovedChildSource() async throws {
        let fixture = try SourcesCatalogFixture()
        defer { fixture.removeOwnedFiles() }
        await fixture.seed()
        fixture.profile.isKidsProfile = true
        let controller = fixture.controller()
        let count = await fixture.loader.playlistRequestCount
        await controller.restore()
        XCTAssertTrue(controller.isCurrent)
        XCTAssertTrue(controller.catalog.channels.isEmpty)
        XCTAssertTrue(controller.imports.configuration.playlists.isEmpty)
        let restoredRequestCount = await fixture.loader.playlistRequestCount
        XCTAssertEqual(restoredRequestCount, count)
    }

    @MainActor
    func testStandaloneSourcesFencesAnInflightRefreshWithoutRelyingOnViewCallbacks() async throws {
        let gate = SourcesCatalogLoadGate()
        let fixture = try SourcesCatalogFixture(gate: gate)
        defer { fixture.removeOwnedFiles() }
        let controller = fixture.controller()
        let refresh = Task { await controller.refresh() }
        await gate.waitUntilStarted()
        fixture.isActive = false
        await gate.release()
        await refresh.value
        XCTAssertEqual(controller.issue, .authorization)
        XCTAssertFalse(controller.isCurrent)
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.catalog.channels.isEmpty)
        let guideRequests = await fixture.loader.guideRequestCount
        XCTAssertEqual(guideRequests, 0)
    }

    @MainActor
    func testStandaloneSourcesReadFailureAndWrongProfileClearPreviousCatalog() async throws {
        let fixture = try SourcesCatalogFixture()
        defer { fixture.removeOwnedFiles() }
        await fixture.seed()
        let controller = fixture.controller()
        await controller.restore()
        XCTAssertFalse(controller.catalog.channels.isEmpty)
        fixture.readFails = true
        await controller.restore()
        XCTAssertEqual(controller.issue, .configuration)
        XCTAssertTrue(controller.catalog.channels.isEmpty)
        fixture.readFails = false
        await controller.restore()
        XCTAssertFalse(controller.catalog.channels.isEmpty)
        fixture.profile = Profile(id: "another-profile", name: "Other")
        await controller.restore()
        XCTAssertEqual(controller.issue, .authorization)
        XCTAssertTrue(controller.catalog.channels.isEmpty)
    }

    @MainActor
    func testStandaloneSourcesInvalidationRetiresPendingPublication() async throws {
        let gate = SourcesCatalogLoadGate()
        let fixture = try SourcesCatalogFixture(gate: gate)
        defer { fixture.removeOwnedFiles() }
        let controller = fixture.controller()
        let refresh = Task { await controller.refresh() }
        await gate.waitUntilStarted()
        controller.invalidate()
        XCTAssertTrue(controller.catalog.channels.isEmpty)
        await gate.release()
        await refresh.value
        XCTAssertTrue(controller.catalog.channels.isEmpty)
        XCTAssertFalse(controller.isCurrent)
        XCTAssertFalse(controller.isLoading)
    }

    @MainActor
    func testOfflineRestoreLoadsPersistedIdentityReviewsWithoutReconcilingIDs() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/source.m3u"))
        )
        let first = try await fixture.cache.reconcile(
            playlist([channel(0, token: "first", nativeID: "duplicate"), channel(1, token: "first", nativeID: "duplicate")]),
            sourceID: source.id
        )
        let refreshed = try await fixture.cache.reconcile(
            playlist([channel(0, token: "second", nativeID: "duplicate"), channel(1, token: "second", nativeID: "duplicate")]),
            sourceID: source.id
        )
        try await fixture.cache.storePlaylist(refreshed.playlist, source: source, now: now)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [source]), loader: IndexedImportFixtureLoader(now: now), cache: fixture.reopen()
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.restoreCachedCatalog(into: model, now: now)
        XCTAssertEqual(model.channels.map(\.id), refreshed.playlist.channels.map(\.id))
        let reviews = try XCTUnwrap(imports.identityReviews[source.id])
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.allSatisfy {
            Set($0.candidateIDs) == Set(first.playlist.channels.map(\.id))
        })
    }

    func testDisabledSourceCannotRestoreItsCatalogButRetainsIdentityHistory() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/source.m3u"))
        )
        let original = try await fixture.cache.reconcile(playlist([channel(0)]), sourceID: source.id)
        try await fixture.cache.storePlaylist(original.playlist, source: source, now: now)
        let generation = try await fixture.cache.freshness(kind: "playlist", sourceID: source.id)
        var disabled = source
        disabled.isEnabled = false
        let rejected = try await fixture.reopen().playlist(source: disabled)
        XCTAssertNil(rejected)
        let retainedGeneration = try await fixture.cache.freshness(kind: "playlist", sourceID: source.id)
        XCTAssertEqual(retainedGeneration, generation)
        let enabledAgain = try await fixture.reopen().playlist(source: source)
        XCTAssertEqual(enabledAgain?.channels, original.playlist.channels)
        let refreshed = try await fixture.reopen().reconcile(
            playlist([channel(0, token: "rotated", name: "Renamed")]), sourceID: source.id
        )
        XCTAssertEqual(refreshed.playlist.channels.map(\.id), original.playlist.channels.map(\.id))
    }

    func testGuideDocumentRequiresCurrentRetentionProviderAndMappingSettings() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let url = try XCTUnwrap(URL(string: "https://example.test/guide.xml"))
        let xml = Data("""
        <tv><channel id="g0"><display-name>Station</display-name></channel>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Current</title></programme></tv>
        """.utf8)
        _ = try await fixture.cache.importGuide(
            data: xml, sourceID: "guide", channels: [channel(0)], provider: nil, now: now,
            lookaheadDays: 14, sourceURL: url
        )
        let generation = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        let matching = try await fixture.reopen().guide(sourceID: "guide", sourceURL: url, lookaheadDays: 14)
        let wrongRetention = try await fixture.cache.guide(sourceID: "guide", sourceURL: url)
        let wrongProvider = try await fixture.cache.guide(
            sourceID: "guide", sourceURL: url, provider: .pluto, lookaheadDays: 14
        )
        XCTAssertNotNil(matching)
        XCTAssertNil(wrongRetention)
        XCTAssertNil(wrongProvider)
        try await fixture.cache.setMapping(
            .init(guideSourceID: "guide", guideChannelID: "g0"), channelID: "raw-0"
        )
        let changedMapping = try await fixture.reopen().guide(
            sourceID: "guide", sourceURL: url, lookaheadDays: 14
        )
        XCTAssertNil(changedMapping, "An automatic match must not masquerade as a user-confirmed mapping.")
        do {
            _ = try await fixture.cache.importGuide(
                data: Data("<tv><programme".utf8), sourceID: "guide", channels: [channel(0)],
                provider: nil, now: now, sourceURL: url
            )
            XCTFail("Malformed replacement must fail.")
        } catch {}
        let retainedGeneration = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        XCTAssertEqual(retainedGeneration, generation)
        try await fixture.cache.setMapping(nil, channelID: "raw-0")
        let originalSettings = try await fixture.reopen().guide(
            sourceID: "guide", sourceURL: url, lookaheadDays: 14
        )
        XCTAssertNotNil(originalSettings)
    }

    @MainActor
    func testDisabledAndUnapprovedSourcesNeverEnterRestoredCatalogOrGuideWindows() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let date = Date()
        let sources = try ["first", "second"].map { id in
            LiveTVPlaylistSource(
                id: id, name: id,
                playlistURL: try XCTUnwrap(URL(string: "https://example.test/\(id).m3u")),
                guideURLs: [try XCTUnwrap(URL(string: "https://example.test/\(id).xml"))]
            )
        }
        let loader = IndexedImportFixtureLoader(now: date)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: sources), loader: loader, cache: fixture.cache
        )
        let model = LiveTVPrototypeModel(now: date, channels: [])
        await imports.reload(into: model)
        let deniedID = try XCTUnwrap(model.channels.first(where: { $0.playlistSourceID == "first" })?.id)
        let allowedID = try XCTUnwrap(model.channels.first(where: { $0.playlistSourceID == "second" })?.id)
        model.toggleFavorite(deniedID)
        var disabled = sources[0]
        disabled.isEnabled = false
        try imports.applyConfiguration(.init(playlists: [disabled, sources[1]]), into: model)
        XCTAssertEqual(model.channels.map(\.id), [allowedID])
        XCTAssertNil(model.currentProgram(for: deniedID))
        await imports.restoreCachedCatalog(into: model, now: date)
        await imports.loadGuideWindow(
            channelIDs: [deniedID, allowedID], range: .init(start: date, duration: 3_600), into: model
        )
        let results = try await imports.searchPrograms(
            query: "Current", range: .init(start: date, duration: 3_600)
        )
        XCTAssertEqual(Set(results.map(\.channelID)), [allowedID])
        XCTAssertTrue(model.favoriteIDs.contains(deniedID))
        XCTAssertNil(model.currentProgram(for: deniedID))

        // This is the restricted profile's approval-filtered configuration, not a view filter.
        let approvedOnly = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [sources[1]]), loader: loader, cache: fixture.reopen()
        )
        let reopened = LiveTVPrototypeModel(now: date, channels: [])
        await approvedOnly.restoreCachedCatalog(into: reopened, now: date)
        XCTAssertEqual(reopened.channels.map(\.id), [allowedID])
        XCTAssertEqual(reopened.currentProgram(for: allowedID)?.title, "Current")

        try imports.applyConfiguration(.empty, into: model)
        await imports.restoreCachedCatalog(into: model, now: date)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.programCount, 0)
        try imports.applyConfiguration(.init(playlists: [sources[0]]), into: model)
        await imports.restoreCachedCatalog(into: model, now: date)
        XCTAssertEqual(model.channels.map(\.id), [deniedID])
        XCTAssertTrue(model.favoriteIDs.contains(deniedID))
    }

    @MainActor
    func testRetentionEditInvalidatesOnlyThatSourcesGuideBeforeOfflineRestore() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let date = Date()
        var sources = try ["first", "second"].map { id in
            LiveTVPlaylistSource(
                id: id, name: id,
                playlistURL: try XCTUnwrap(URL(string: "https://example.test/\(id).m3u")),
                guideURLs: [try XCTUnwrap(URL(string: "https://example.test/\(id).xml"))]
            )
        }
        let loader = IndexedImportFixtureLoader(now: date)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: sources), loader: loader, cache: fixture.cache
        )
        let model = LiveTVPrototypeModel(now: date, channels: [])
        await imports.reload(into: model)
        let editedID = try XCTUnwrap(model.channels.first(where: { $0.playlistSourceID == "first" })?.id)
        let untouchedID = try XCTUnwrap(model.channels.first(where: { $0.playlistSourceID == "second" })?.id)
        let originalIDs = model.channels.map(\.id)
        sources[0].guideLookaheadDays = 14
        try imports.applyConfiguration(.init(playlists: sources), into: model)
        XCTAssertEqual(model.channels.map(\.id), originalIDs)
        XCTAssertNil(model.currentProgram(for: editedID))
        XCTAssertEqual(model.currentProgram(for: untouchedID)?.title, "Current")
        await loader.failRequests()
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.map(\.id), originalIDs)
        XCTAssertNil(model.currentProgram(for: editedID))
        XCTAssertEqual(model.currentProgram(for: untouchedID)?.title, "Current")
        let reopened = LiveTVPrototypeImportModel(
            configuration: .init(playlists: sources), loader: loader, cache: fixture.reopen()
        )
        let restored = LiveTVPrototypeModel(now: date, channels: [])
        await reopened.restoreCachedCatalog(into: restored, now: date)
        XCTAssertEqual(restored.channels.map(\.id), originalIDs)
        XCTAssertNil(restored.currentProgram(for: editedID))
        XCTAssertEqual(restored.currentProgram(for: untouchedID)?.title, "Current")
    }

    @MainActor
    func testMappingChangeDropsInMemoryGuideBeforeOfflinePublication() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let date = Date()
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/source.m3u")),
            guideURLs: [try XCTUnwrap(URL(string: "https://example.test/guide.xml"))]
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [source]), loader: IndexedImportFixtureLoader(now: date), cache: fixture.cache
        )
        let model = LiveTVPrototypeModel(now: date, channels: [])
        await imports.reload(into: model)
        let id = try XCTUnwrap(model.channels.first?.id)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "Current")
        try await fixture.cache.setMapping(
            .init(guideSourceID: try XCTUnwrap(source.guideSourceIDs.first), guideChannelID: "missing"), channelID: id
        )
        await imports.restoreCachedCatalog(into: model, now: date)
        XCTAssertEqual(model.channels.map(\.id), [id])
        XCTAssertNil(model.currentProgram(for: id))
        XCTAssertEqual(imports.programCount, 0)
        try await fixture.cache.setMapping(nil, channelID: id)
        await imports.restoreCachedCatalog(into: model, now: date)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "Current")
    }

    func testTwoExistingDeviceIdentitiesConvergeWithoutSharingEncryptionKeys() async throws {
        let first = try CacheFixture()
        let second = try CacheFixture()
        defer { first.removeOwnedFiles(); second.removeOwnedFiles() }
        let firstImport = try await first.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let secondImport = try await second.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let firstID = try XCTUnwrap(firstImport.playlist.channels.first?.id)
        let secondID = try XCTUnwrap(secondImport.playlist.channels.first?.id)
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "g0")
        try await first.cache.applyPortableIdentityHints([secondID: hint])
        try await second.cache.applyPortableIdentityHints([firstID: hint])
        let firstReconciled = try await first.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let secondReconciled = try await second.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let canonical = min(firstID, secondID)
        XCTAssertEqual(firstReconciled.playlist.channels.first?.id, canonical)
        XCTAssertEqual(secondReconciled.playlist.channels.first?.id, canonical)
        if firstID != canonical { XCTAssertEqual(firstReconciled.migratedIDs[firstID], canonical) }
        if secondID != canonical { XCTAssertEqual(secondReconciled.migratedIDs[secondID], canonical) }
    }

    @MainActor
    func testExplicitGuideCredentialsOverrideOlderEquivalentPlaylistDeclarations() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let oldGuide = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=old"))
        let newGuide = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=new"))
        let loader = DeclaredGuideFixtureLoader(guideURL: oldGuide)
        let configuration = LiveTVSourcesConfiguration(playlists: [.init(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u")), guideURLs: [newGuide]
        )])
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: fixture.cache)
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let requested = await loader.guideRequests
        XCTAssertEqual(requested, [newGuide])
        XCTAssertEqual(imports.guideSources.count, 1)
        let programs = try await imports.searchPrograms(
            query: "Fixture programme", range: .init(start: model.now, duration: 3_600)
        )
        XCTAssertEqual(programs.map(\.title), ["Fixture programme"])
        let options = try await imports.guideChannelOptions(
            sourceID: try XCTUnwrap(imports.guideSources.first?.id), query: "Station"
        )
        XCTAssertEqual(options.map(\.id), ["g"])
    }

    @MainActor
    func testDiscoveredGuideTokenRotationUpdatesTransportWithoutChangingGuideIdentity() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let oldGuide = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=old"))
        let newGuide = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=new"))
        let loader = DeclaredGuideFixtureLoader(guideURL: oldGuide)
        let configuration = LiveTVSourcesConfiguration(playlists: [.init(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u"))
        )])
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: fixture.cache)
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let firstID = try XCTUnwrap(imports.guideSources.first?.id)
        await loader.setGuideURL(newGuide)
        await imports.reload(into: model)
        XCTAssertEqual(imports.guideSources.first?.id, firstID)
        XCTAssertEqual(imports.guideSources.first?.source.url, newGuide)
        let requested = await loader.guideRequests
        XCTAssertEqual(requested, [oldGuide, newGuide])
    }

    func testPlaylistRestoreRequiresTheCurrentCredentialBearingSourceURL() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let oldURL = try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=old-source-secret"))
        let newURL = try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=new-source-secret"))
        let original = LiveTVPlaylistSource(id: "source", name: "Source", playlistURL: oldURL)
        var changed = original
        changed.playlistURL = newURL
        let imported = playlist([channel(0, token: "old-stream-secret")])
        try await fixture.cache.storePlaylist(imported, source: original, now: now)
        let restored = try await fixture.reopen().playlist(source: original)
        XCTAssertEqual(restored?.channels, imported.channels)
        let wrongEndpoint = try await fixture.reopen().playlist(source: changed)
        XCTAssertNil(wrongEndpoint)
        let unboundRead = try await fixture.cache.playlist(sourceID: original.id)
        XCTAssertNil(unboundRead)
        try await fixture.cache.storePlaylist(imported, sourceID: "legacy", now: now)
        let legacy = LiveTVPlaylistSource(id: "legacy", name: "Legacy", playlistURL: oldURL)
        let unprovenLegacy = try await fixture.cache.playlist(source: legacy)
        XCTAssertNil(unprovenLegacy)
        XCTAssertFalse(fixture.secure.valuesJoined.contains("old-source-secret"))
    }

    func testGuideRestoreWindowSearchAndMappingOptionsRequireCurrentSourceURL() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let oldURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=old"))
        let newURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=new"))
        let xml = Data("""
        <tv><channel id="g0"><display-name>Station</display-name></channel>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Bound programme</title></programme></tv>
        """.utf8)
        _ = try await fixture.cache.importGuide(
            data: xml, sourceID: "guide", channels: [channel(0)], provider: nil, now: now, sourceURL: oldURL
        )
        let generation = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        let wrongGuide = try await fixture.cache.guide(sourceID: "guide", sourceURL: newURL)
        let wrongPrograms = try await fixture.cache.programs(
            sourceID: "guide", channelIDs: ["raw-0"], range: .init(start: now, duration: 3_600), sourceURL: newURL
        )
        let wrongOptions = try await fixture.cache.guideChannels(sourceID: "guide", sourceURL: newURL)
        let wrongSearch = try await fixture.cache.searchPrograms(
            query: "Bound", sourceIDs: ["guide"], range: .init(start: now, duration: 3_600),
            sourceURLs: ["guide": newURL]
        )
        XCTAssertNil(wrongGuide)
        XCTAssertTrue(wrongPrograms.isEmpty)
        XCTAssertTrue(wrongOptions.isEmpty)
        XCTAssertTrue(wrongSearch.isEmpty)
        do {
            _ = try await fixture.cache.importGuide(
                data: Data("<tv><programme".utf8), sourceID: "guide",
                channels: [channel(0)], provider: nil, now: now, sourceURL: newURL
            )
            XCTFail("An invalid replacement must not change the previous source binding.")
        } catch {}
        let preservedGeneration = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        XCTAssertEqual(preservedGeneration, generation)
        let validSearch = try await fixture.cache.searchPrograms(
            query: "Bound", sourceIDs: ["guide"], range: .init(start: now, duration: 3_600),
            sourceURLs: ["guide": oldURL]
        )
        XCTAssertEqual(validSearch.map(\.title), ["Bound programme"])
        try await fixture.cache.removeDownloadedGuide(sourceID: "guide", sourceURL: newURL)
        let stillBound = try await fixture.cache.guide(sourceID: "guide", sourceURL: oldURL)
        XCTAssertNotNil(stillBound)
    }

    @MainActor
    func testImporterNeverRestoresOldStreamsAfterEditingSourceCredentialsOffline() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let original = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=old"))
        )
        let resolved = try await fixture.cache.reconcile(playlist([channel(0, token: "old-stream")]), sourceID: original.id)
        try await fixture.cache.storePlaylist(resolved.playlist, source: original, now: now)
        var changed = original
        changed.playlistURL = try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=new"))
        let loader = IndexedImportFixtureLoader(now: now)
        await loader.failRequests()
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [changed]), loader: loader, cache: fixture.reopen()
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.playlistSources.first?.phase, .failed)
        let retainedForOriginal = try await fixture.cache.playlist(source: original)
        XCTAssertEqual(retainedForOriginal?.channels, resolved.playlist.channels)
    }

    @MainActor
    func testImportedFileCatalogReloadDoesNotRequestAnHTTPPlaylist() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let id = UUID()
        _ = try await fixture.cache.storeImportedPlaylist(data: Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="g",Offline import
        https://example.test/live.m3u8
        """.utf8), id: id)
        let locator = try XCTUnwrap(URL(string: "plozz-playlist://" + id.uuidString.lowercased()))
        let configuration = LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(id: id.uuidString, name: "Imported", playlistURL: locator)
        ])
        let loader = IndexedImportFixtureLoader(now: Date())
        await loader.failRequests()
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: fixture.reopen())
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.map(\.name), ["Offline import"])
        XCTAssertEqual(imports.playlistSources.first?.phase, .loaded)
        XCTAssertNil(imports.playlistFailure)
    }

    func testReusedLocatorDoesNotSilentlyMergeConflictingNativeIdentities() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let first = try await fixture.cache.reconcile(playlist([channel(0, nativeID: "old")]), sourceID: "source")
        let next = try await fixture.cache.reconcile(playlist([channel(0, nativeID: "new")]), sourceID: "source")
        XCTAssertNotEqual(next.playlist.channels.first?.id, first.playlist.channels.first?.id)
        XCTAssertEqual(next.reviews.first?.candidateIDs, first.playlist.channels.map(\.id))
    }

    func testImportedPlaylistIsEncryptedDurableAndPreservesRelativeOrigin() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let id = UUID()
        let base = try XCTUnwrap(URL(string: "https://example.test/provider/list.m3u"))
        let data = Data("""
        #EXTM3U url-tvg="guide.xml"
        #EXTINF:-1 tvg-id="local",Imported channel
        live.m3u8?token=import-file-secret
        """.utf8)
        let first = try await fixture.cache.storeImportedPlaylist(data: data, id: id, baseURL: base)
        let source = LiveTVPlaylistSource(
            id: id.uuidString, name: "Imported",
            playlistURL: try XCTUnwrap(URL(string: "plozz-playlist://" + id.uuidString.lowercased()))
        )
        try await fixture.cache.storePlaylist(first, source: source, now: now)
        let reopened = try await fixture.reopen(authorization: "new-authorization-epoch").importedPlaylist(id: id)
        XCTAssertEqual(reopened.channels, first.channels)
        XCTAssertEqual(reopened.originURL, base)
        XCTAssertEqual(reopened.declaredGuideURLs.first?.absoluteString, "https://example.test/provider/guide.xml")
        XCTAssertFalse(fixture.secure.valuesJoined.contains("import-file-secret"))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixture.directory, includingPropertiesForKeys: nil))
        var encryptedFiles = 0
        for case let file as URL in enumerator where file.pathExtension == "sealed" {
            encryptedFiles += 1
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("import-file-secret".utf8)))
        }
        XCTAssertEqual(encryptedFiles, 1)
        do {
            _ = try await fixture.cache.storeImportedPlaylist(data: Data("not M3U".utf8), id: id)
            XCTFail("An invalid replacement must leave the imported original intact.")
        } catch {}
        let preserved = try await fixture.cache.importedPlaylist(id: id)
        XCTAssertEqual(preserved.channels, first.channels)
        let updated = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "import-file-secret", with: "updated-file-secret").utf8)
        _ = try await fixture.cache.storeImportedPlaylist(data: updated, id: id, baseURL: base)
        let staleCatalog = try await fixture.cache.playlist(source: source)
        XCTAssertNil(staleCatalog)
        try await fixture.cache.removeImportedPlaylist(id: id)
        do {
            _ = try await fixture.cache.importedPlaylist(id: id)
            XCTFail("Explicit removal must remove the owned encrypted file.")
        } catch {}
    }

    func testPortableHintCannotClaimAnotherNativeChannelsIdentity() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let original = try await fixture.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let id = try XCTUnwrap(original.playlist.channels.first?.id)
        try await fixture.cache.applyPortableIdentityHints([
            id: LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "g1")
        ])
        do {
            _ = try await fixture.cache.reconcile(playlist([channel(0), channel(1)]), sourceID: "source")
            XCTFail("A conflicting portable ID must not merge unrelated native channels.")
        } catch {
            XCTAssertEqual(error as? LiveTVCacheError, .invalidRecord)
        }
        let unchanged = try await fixture.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        XCTAssertEqual(unchanged.playlist.channels.first?.id, id)
    }

    func testDiscoveredGuideIdentitySurvivesTokenRotationAndDeclarationOrder() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let firstURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?region=uk&token=first"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?region=us&token=second"))
        let firstID = try await fixture.cache.discoveredGuideSourceID(sourceID: "source", url: firstURL)
        let secondID = try await fixture.cache.discoveredGuideSourceID(sourceID: "source", url: secondURL)
        let rotatedSecond = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=rotated&region=us"))
        let rotatedFirst = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=rotated&region=uk"))
        let reloadedSecond = try await fixture.reopen().discoveredGuideSourceID(sourceID: "source", url: rotatedSecond)
        let reloadedFirst = try await fixture.reopen().discoveredGuideSourceID(sourceID: "source", url: rotatedFirst)
        XCTAssertEqual(reloadedSecond, secondID)
        XCTAssertEqual(reloadedFirst, firstID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testUniqueNativeIdentityHintsReconnectFavoritesOnAnotherDevice() async throws {
        let first = try CacheFixture()
        let second = try CacheFixture()
        defer { first.removeOwnedFiles(); second.removeOwnedFiles() }
        let original = try await first.cache.reconcile(playlist([channel(0)]), sourceID: "source")
        let id = try XCTUnwrap(original.playlist.channels.first?.id)
        try await second.cache.applyPortableIdentityHints([
            id: LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "g0")
        ])
        let resolved = try await second.cache.reconcile(
            playlist([channel(0, token: "another-device-token", name: "Renamed")]), sourceID: "source"
        )
        XCTAssertEqual(resolved.playlist.channels.first?.id, id)
    }

    @MainActor
    func testImporterPublishesInitialIndexedWindowAndRestoresItOffline() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let date = Date()
        let playlistURL = try XCTUnwrap(URL(string: "https://example.test/source.m3u"))
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml"))
        let configuration = LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(id: "source", name: "Source", playlistURL: playlistURL, guideURLs: [guideURL])
        ])
        let loader = IndexedImportFixtureLoader(now: date)
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: fixture.cache)
        let model = LiveTVPrototypeModel(now: date, channels: [])
        await imports.reload(into: model)
        let channel = try XCTUnwrap(model.channels.first)
        XCTAssertEqual(model.currentProgram(for: channel.id)?.title, "Current")
        await loader.failRequests()
        let reopened = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: fixture.reopen())
        let restored = LiveTVPrototypeModel(now: date, channels: [])
        await reopened.reload(into: restored)
        XCTAssertEqual(restored.channels.map(\.id), [channel.id])
        XCTAssertEqual(restored.currentProgram(for: channel.id)?.title, "Current")
        XCTAssertEqual(reopened.playlistSources.first?.phase, .failed)
    }

    func testStableIdentitySurvivesReorderRenameAndSignedURLRotationWithoutLeakingLocators() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let first = try await fixture.cache.reconcile(
            playlist([channel(0, token: "old-secret"), channel(1, token: "old-secret")]), sourceID: "source"
        )
        let second = try await fixture.cache.reconcile(
            playlist([channel(1, token: "rotated-secret", name: "Renamed"), channel(0, token: "rotated-secret")]),
            sourceID: "source"
        )
        XCTAssertEqual(second.playlist.channels.map(\.id), first.playlist.channels.reversed().map(\.id))
        XCTAssertTrue(second.playlist.channels.allSatisfy { $0.id.hasPrefix("channel-") })
        XCTAssertFalse(fixture.secure.valuesJoined.contains("old-secret"))
        XCTAssertFalse(fixture.secure.valuesJoined.contains("/username/password/"))
        let reopened = fixture.reopen()
        let third = try await reopened.reconcile(playlist([channel(0, token: "third")]), sourceID: "source")
        XCTAssertEqual(third.playlist.channels[0].id, first.playlist.channels[0].id)
    }

    func testDuplicateNativeIDsNeverMergeAndAmbiguousRotationsRequireReview() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let first = try await fixture.cache.reconcile(
            playlist([channel(0, token: "a", nativeID: "duplicate"), channel(1, token: "b", nativeID: "duplicate")]),
            sourceID: "source"
        )
        XCTAssertEqual(Set(first.playlist.channels.map(\.id)).count, 2)
        XCTAssertEqual(first.reviews.count, 2)
        let rotated = try await fixture.cache.reconcile(
            playlist([channel(0, token: "rotated-a", nativeID: "duplicate"), channel(1, token: "rotated-b", nativeID: "duplicate")]),
            sourceID: "source"
        )
        XCTAssertTrue(Set(first.playlist.channels.map(\.id)).isDisjoint(with: rotated.playlist.channels.map(\.id)))
        XCTAssertEqual(rotated.reviews.count, 2)
        XCTAssertTrue(rotated.reviews.allSatisfy { $0.candidateIDs.count == 2 })
        let stillPending = try await fixture.reopen().reconcile(
            playlist([channel(0, token: "rotated-a", nativeID: "duplicate"), channel(1, token: "rotated-b", nativeID: "duplicate")]),
            sourceID: "source"
        )
        XCTAssertEqual(stillPending.playlist.channels.map(\.id), rotated.playlist.channels.map(\.id))
        XCTAssertEqual(stillPending.reviews, rotated.reviews)
    }

    func testNamesAloneNeverRecoverAnUnrelatedChannel() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let original = try await fixture.cache.reconcile(playlist([channel(0, name: "News", nativeID: "")]), sourceID: "source")
        let replacement = try await fixture.cache.reconcile(playlist([channel(9, name: "News", nativeID: "")]), sourceID: "source")
        XCTAssertNotEqual(original.playlist.channels[0].id, replacement.playlist.channels[0].id)
    }

    func testEncryptedCatalogReopensOfflineAndRejectsAnotherAuthorizationScope() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let original = playlist([channel(0, token: "credential-in-query")])
        try await fixture.cache.storePlaylist(original, sourceID: "source", now: now)
        let reopened = fixture.reopen()
        let restored = try await reopened.playlist(sourceID: "source")
        XCTAssertEqual(restored?.channels, original.channels)
        for file in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("credential-in-query".utf8)))
            XCTAssertNil(bytes.range(of: Data("/username/password/".utf8)))
        }
        let wrongScope = fixture.reopen(authorization: "child-restricted")
        do {
            _ = try await wrongScope.playlist(sourceID: "source")
            XCTFail("A cache must not cross authorization scopes.")
        } catch {
            XCTAssertEqual(error as? LiveTVCacheError, .authorizationScopeMismatch)
        }
    }

    func testFailedGuideRefreshKeepsGenerationAndLastGoodWindow() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel(0)]
        let valid = Data("""
        <tv><channel id="g0"><display-name>Station</display-name></channel>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Last good</title></programme></tv>
        """.utf8)
        _ = try await fixture.cache.importGuide(data: valid, sourceID: "guide", channels: channels, provider: nil, now: now)
        let first = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        do {
            _ = try await fixture.cache.importGuide(data: Data("<tv><programme".utf8), sourceID: "guide", channels: channels, provider: nil, now: now)
            XCTFail("Malformed refresh must fail.")
        } catch {}
        let next = try await fixture.cache.freshness(kind: "guide", sourceID: "guide")
        let programs = try await fixture.cache.programs(
            sourceID: "guide", channelIDs: ["raw-0"], range: DateInterval(start: now, duration: 3_600)
        )
        XCTAssertEqual(next, first)
        XCTAssertEqual(programs.map(\.title), ["Last good"])
    }

    func testManualMappingSurvivesRefreshAndOverridesExactID() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.cache.setMapping(.init(guideSourceID: "guide", guideChannelID: "chosen"), channelID: "raw-0")
        let xml = Data("""
        <tv>
        <channel id="g0"><display-name>Wrong feed</display-name></channel>
        <channel id="chosen"><display-name>Correct regional feed</display-name></channel>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Wrong</title></programme>
        <programme channel="chosen" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Correct</title><desc>Programme details</desc><episode-num>1.2.</episode-num></programme>
        </tv>
        """.utf8)
        let result = try await fixture.reopen().importGuide(
            data: xml, sourceID: "guide", channels: [channel(0)], provider: nil, now: now
        )
        XCTAssertEqual(result.matches["raw-0"]?.method, .userConfirmed)
        let programs = try await fixture.cache.programs(
            sourceID: "guide", channelIDs: ["raw-0"], range: DateInterval(start: now, duration: 3_600)
        )
        XCTAssertEqual(programs.map(\.title), ["Correct"])
        XCTAssertEqual(programs.first?.details?.description, "Programme details")
        XCTAssertEqual(programs.first?.details?.episode, "1.2.")
    }

    func testProgrammeSearchIsIndexedBoundedAndIndependentOfChannelName() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let xml = Data("""
        <tv><channel id="g0"><display-name>News</display-name></channel>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Space exploration</title></programme>
        <programme channel="g0" start="20260101010000 +0000" stop="20260101020000 +0000"><title>Space travel</title></programme></tv>
        """.utf8)
        _ = try await fixture.cache.importGuide(data: xml, sourceID: "guide", channels: [channel(0)], provider: nil, now: now)
        let results = try await fixture.cache.searchPrograms(
            query: "space", sourceIDs: ["guide"], range: DateInterval(start: now, duration: 7_200), limit: 1
        )
        XCTAssertEqual(results.map(\.title), ["Space exploration"])
        let forbidden = try await fixture.cache.searchPrograms(
            query: "space", sourceIDs: ["another-profile"], range: DateInterval(start: now, duration: 7_200)
        )
        XCTAssertTrue(forbidden.isEmpty)
    }

    func testIndexedMillionProgrammeFixtureKeepsOnlyRequestedRowsInMemory() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/million.xml"))
        let source = LiveTVPlaylistSource(
            id: "source", name: "Scale fixture",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/large.m3u")), guideURLs: [guideURL]
        )
        let resolved = try await fixture.cache.reconcile(
            playlist((0..<10_000).map { channel($0) }), sourceID: source.id
        )
        let channels = resolved.playlist.channels
        try await fixture.cache.storePlaylist(resolved.playlist, source: source, now: now)
        var xml = Data("<tv>".utf8)
        xml.reserveCapacity(170_000_000)
        for index in channels.indices {
            xml.append(Data("<channel id=\"g\(index)\"><display-name>Station \(index)</display-name></channel>".utf8))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss '+0000'"
        let intervals = (0..<100).map { slot in
            (formatter.string(from: now.addingTimeInterval(Double(slot) * 1_800)),
             formatter.string(from: now.addingTimeInterval(Double(slot + 1) * 1_800)))
        }
        for index in channels.indices {
            for (slot, interval) in intervals.enumerated() {
                xml.append(Data("<programme channel=\"g\(index)\" start=\"\(interval.0)\" stop=\"\(interval.1)\"><title>Schedule \(slot)</title></programme>".utf8))
            }
        }
        xml.append(Data("</tv>".utf8))
        let result = try await fixture.cache.importGuide(
            data: xml, sourceID: "guide", channels: channels, provider: nil, now: now, sourceURL: guideURL
        )
        XCTAssertEqual(result.programCount, 1_000_000)
        XCTAssertTrue(result.programs.isEmpty, "The indexed import must not return a million programmes to the UI.")
        let window = try await fixture.cache.programs(
            sourceID: "guide", channelIDs: [channels[0].id, channels[9_999].id],
            range: DateInterval(start: now, duration: 3_600), sourceURL: guideURL
        )
        XCTAssertEqual(window.count, 4)
        let found = try await fixture.cache.searchPrograms(
            query: "Schedule 73", sourceIDs: ["guide"], range: DateInterval(start: now, duration: 3 * 86_400),
            limit: 25, sourceURLs: ["guide": guideURL]
        )
        XCTAssertEqual(found.count, 25)
        let restored = try await fixture.reopen().playlist(source: source)
        XCTAssertEqual(restored?.channels.count, 10_000)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_767_225_600) }

    private func playlist(_ channels: [LiveTVPrototypeChannel]) -> LiveTVPlaylistImport {
        .init(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    private func channel(
        _ index: Int, token: String = "token", name: String? = nil, nativeID: String? = nil
    ) -> LiveTVPrototypeChannel {
        .init(
            id: "raw-\(index)", number: index + 1, name: name ?? "Channel \(index)", category: "Test",
            symbol: "tv", accent: 0, source: .iptv, tagline: "Test",
            streamURL: URL(string: "https://example.test/username/password/\(index).m3u8?token=\(token)"),
            guideID: nativeID ?? "g\(index)", playlistSourceID: "source"
        )
    }
}

private actor IndexedImportFixtureLoader: LiveTVIndexedSourceLoading {
    private let now: Date
    private var failed = false
    private let gate: SourcesCatalogLoadGate?
    private(set) var playlistRequestCount = 0
    private(set) var guideRequestCount = 0
    init(now: Date, gate: SourcesCatalogLoadGate? = nil) { self.now = now; self.gate = gate }
    func failRequests() { failed = true }
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        playlistRequestCount += 1
        await gate?.suspend()
        if failed { throw LiveTVSourceImportError.downloadFailed }
        return try LiveTVPlaylistParser(baseURL: url).parse(
            "#EXTM3U\n#EXTINF:-1 tvg-id=\"g\",Channel\nhttps://example.test/live.m3u8"
        )
    }
    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        guideRequestCount += 1
        if failed { throw LiveTVSourceImportError.downloadFailed }
        return try LiveTVXMLTVParser().parseXML(data: guideData(), channels: channels, now: now)
    }
    func loadIndexedGuide(
        from url: URL, sourceID: String, channels: [LiveTVPrototypeChannel], now: Date,
        cache: LiveTVIndexedCache, lookbackDays: Int, lookaheadDays: Int
    ) async throws -> LiveTVGuideImport {
        guideRequestCount += 1
        if failed { throw LiveTVSourceImportError.downloadFailed }
        return try await cache.importGuide(
            data: guideData(), sourceID: sourceID, channels: channels, provider: nil, now: now,
            lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sourceURL: url
        )
    }
    private func guideData() -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return Data("""
        <tv><channel id="g"><display-name>Channel</display-name></channel>
        <programme channel="g" start="\(formatter.string(from: now.addingTimeInterval(-60)))" stop="\(formatter.string(from: now.addingTimeInterval(3_600)))"><title>Current</title></programme></tv>
        """.utf8)
    }
}

private actor DeclaredGuideFixtureLoader: LiveTVSourceLoading {
    private var guideURL: URL
    private(set) var guideRequests: [URL] = []

    init(guideURL: URL) { self.guideURL = guideURL }
    func setGuideURL(_ url: URL) { guideURL = url }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U url-tvg="\(guideURL.absoluteString)"
        #EXTINF:-1 tvg-id="g",Station
        https://example.test/live.m3u8
        """)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        guideRequests.append(url)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let start = formatter.string(from: now.addingTimeInterval(-60))
        let end = formatter.string(from: now.addingTimeInterval(3_600))
        return try LiveTVXMLTVParser().parseXML(data: Data("""
        <tv><channel id="g"><display-name>Station</display-name></channel>
        <programme channel="g" start="\(start)" stop="\(end)"><title>Fixture programme</title></programme></tv>
        """.utf8), channels: channels, now: now)
    }
}

@MainActor
private final class SourcesCatalogFixture {
    let cache: CacheFixture
    let defaults: UserDefaults
    let domain = "LiveTVSourcesCatalogTests-" + UUID().uuidString
    let now = Date()
    let loader: IndexedImportFixtureLoader
    var profile = Profile(id: "profile-a", name: "Owner")
    var isActive = true
    var readFails = false
    var configuration: LiveTVSourcesConfiguration

    init(gate: SourcesCatalogLoadGate? = nil) throws {
        cache = try CacheFixture()
        let suite = domain
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        loader = IndexedImportFixtureLoader(now: now, gate: gate)
        configuration = .init(playlists: [.init(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/source.m3u")),
            guideURLs: [try XCTUnwrap(URL(string: "https://example.test/guide.xml"))]
        )])
    }

    func controller() -> LiveTVSourcesCatalog {
        LiveTVSourcesCatalog(
            profileID: "profile-a", cache: cache.cache, loader: loader,
            preferencesStore: LiveTVPreferencesStore(defaults: defaults, namespace: "profile-a"),
            authority: { [self] in
                if readFails { throw LiveTVCacheError.unavailable }
                guard isActive else { return nil }
                let authorization = try LiveTVSourceApprovalStore(defaults: defaults, profileID: profile.id)
                    .authorization(
                        context: .init(profile: profile, parentalPIN: nil, activeAccountIDs: []),
                        configuration: configuration
                    )
                return .init(configuration: configuration, authorization: authorization)
            },
            clock: { [now] in now }
        )
    }

    func seed() async {
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader, cache: cache.cache)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
    }

    func removeOwnedFiles() {
        defaults.removePersistentDomain(forName: domain)
        cache.removeOwnedFiles()
    }
}

private actor SourcesCatalogLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func suspend() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct CacheFixture {
    let directory: URL
    let secure = IndexedCacheSecureStore()
    let cache: LiveTVIndexedCache

    init() throws {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = root.appendingPathComponent("LiveTVIndexedCacheTests-" + UUID().uuidString, isDirectory: true)
        cache = LiveTVIndexedCache(
            url: directory.appendingPathComponent("catalog.sqlite"), namespace: "profile-a",
            authorizationScope: "iptv-catalog-v1", secureStore: secure,
            importedFilesURL: directory.appendingPathComponent("imported", isDirectory: true)
        )
    }

    func reopen(authorization: String = "iptv-catalog-v1") -> LiveTVIndexedCache {
        LiveTVIndexedCache(
            url: directory.appendingPathComponent("catalog.sqlite"), namespace: "profile-a",
            authorizationScope: authorization, secureStore: secure,
            importedFilesURL: directory.appendingPathComponent("imported", isDirectory: true)
        )
    }

    func removeOwnedFiles() {
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove this test's owned cache.") }
        }
    }
}

private final class IndexedCacheSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var valuesJoined: String {
        lock.lock()
        defer { lock.unlock() }
        return values.values.joined()
    }
    func readString(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func string(for key: String) -> String? { try? readString(for: key) }
    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}
#endif
