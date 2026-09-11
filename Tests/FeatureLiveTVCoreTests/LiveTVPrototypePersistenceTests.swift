import CoreModels
import Foundation
import Observation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPrototypePersistenceTests: XCTestCase {
    func testScanHidingIsTransientAndAppliesToEveryCatalogProjection() throws {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        model.toggleFavorite("0")
        XCTAssertTrue(model.hideChannel(channels[1]))
        let saved = store.value
        let saves = store.saves
        model.setScanHiddenChannelIDs(["0", "2"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["3"])
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["3"])
        XCTAssertEqual(model.programmeSearchChannelIDs, ["3"])
        XCTAssertEqual(model.hiddenChannelIDs, ["1"])
        XCTAssertEqual(model.favoriteIDs, ["0"])
        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(store.saves, saves)
        let revision = model.catalogRevision
        model.setScanHiddenChannelIDs(["0", "2"])
        XCTAssertEqual(model.catalogRevision, revision)
        model.query = "No channel matches"
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["3"])
        XCTAssertEqual(model.programmeSearchChannelIDs, ["3"])
        model.setScanHiddenChannelIDs([])
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["0", "2", "3"])
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertTrue(LiveTVPrototypeModel(channels: channels, preferencesStore: store).scanHiddenChannelIDs.isEmpty)
    }

    func testPreferenceAndGuideFacetsPreserveObservationThroughPublicProperties() async throws {
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: PreferencesFixtureStore())
        let favoriteChanged = expectation(description: "Favorite getter observes its facet")
        let guideChanged = expectation(description: "Guide getter observes its facet")
        withObservationTracking {
            _ = model.favoriteIDs
        } onChange: {
            favoriteChanged.fulfill()
        }
        withObservationTracking {
            _ = model.guideChannelCount
        } onChange: {
            guideChanged.fulfill()
        }
        model.toggleFavorite("0")
        try model.replacePrograms([.init(
            id: "programme", channelID: "0", title: "Programme", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(3_600)
        )])
        await fulfillment(of: [favoriteChanged, guideChanged], timeout: 1)
    }

    func testCatalogPickerAppliesSourceApprovalManualHidingAndScanHidingWithoutBrowseFilters() throws {
        let suite = "LiveTVCatalogPickerTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = LiveTVPlaylistSource(
            id: "allowed", name: "Allowed", playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u"))
        )
        let profile = Profile(id: "picker-profile", name: "Picker")
        let approval = LiveTVSourceApprovalStore(defaults: defaults, profileID: profile.id)
            .authorizationFailClosed(
                context: .init(profile: profile, parentalPIN: nil, activeAccountIDs: []),
                configuration: .init(playlists: [source])
            )
        let supplied = channels.enumerated().map {
            $0.element.replacingIdentity(id: $0.element.id, sourceID: $0.offset == 3 ? "unapproved" : "allowed")
        }
        let model = LiveTVPrototypeModel(channels: supplied, preferencesStore: PreferencesFixtureStore())
        XCTAssertTrue(model.hideChannel(supplied[1]))
        model.query = "No matching channel"
        model.favoritesOnly = true
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(model.catalogChannels(authorizedBy: approval, excluding: ["2"]).map(\.id), ["0"])
    }

    func testUnhiddenCatalogPickerIgnoresBrowseFiltersAndNeverReintroducesRemovedChannels() throws {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertTrue(model.hideChannel(channels[1]))
        model.toggleFavorite("0")
        model.query = "No channel matches this query"
        model.category = "Missing category"
        model.source = .plex
        model.playlistSourceID = "missing-source"
        model.language = "Missing language"
        model.country = "Missing country"
        model.guideOnly = true
        model.favoritesOnly = true
        model.sort = .name
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["0", "2", "3"])
        try model.replaceChannels([channels[3]])
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["3"])
        XCTAssertTrue(model.favoriteIDs.contains("0"))
    }

    func testIdentityMigrationKeepsFavoritesOrderRecentsHidingAndMetadata() throws {
        let store = PreferencesFixtureStore()
        store.value = LiveTVPreferences(
            favoriteIDs: ["old", "other"], recentChannelIDs: ["old"],
            hiddenChannels: [.init(id: "old", name: "Saved name")], favoriteOrder: ["other", "old"],
            favoriteChannels: [.init(id: "old", name: "Saved name")],
            channelOverrides: ["old": .init(name: "Custom", category: "News")]
        )
        let model = LiveTVPrototypeModel(channels: [], preferencesStore: store)
        XCTAssertTrue(model.migrateChannelIDs(["old": "durable"]))
        XCTAssertEqual(store.value.favoriteIDs, ["durable", "other"])
        XCTAssertEqual(store.value.favoriteOrder, ["other", "durable"])
        XCTAssertEqual(store.value.recentChannelIDs, ["durable"])
        XCTAssertEqual(store.value.hiddenChannelIDs, ["durable"])
        XCTAssertEqual(store.value.channelOverrides["durable"]?.name, "Custom")
        XCTAssertEqual(model.unavailableFavorites.last?.name, "Saved name")
    }

    func testBrowseAndCustomMetadataPersistWithoutPlaybackOrQuery() {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertTrue(model.setMetadataOverride(.init(name: "My news", language: "English", country: "US"), channelID: "0"))
        model.language = "English"
        model.country = "US"
        model.sort = .name
        model.query = "news"
        model.tune("0")
        let restored = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertEqual(restored.language, "English")
        XCTAssertEqual(restored.country, "US")
        XCTAssertEqual(restored.sort, .name)
        XCTAssertEqual(restored.visibleChannels.map(\.name), ["My news"])
        XCTAssertEqual(restored.query, "")
        XCTAssertNil(restored.playingChannelID)
    }

    func testSavedPreferencesSurviveAnInitiallyEmptyOrTemporarilyUnavailableCatalog() throws {
        let store = PreferencesFixtureStore()
        store.value = LiveTVPreferences(favoriteIDs: ["1"], recentChannelIDs: ["2", "1"])
        let model = LiveTVPrototypeModel(channels: [], preferencesStore: store)
        XCTAssertEqual(model.favoriteIDs, ["1"])
        XCTAssertEqual(model.recentChannelIDs, ["2", "1"])
        XCTAssertTrue(model.guideChannels.isEmpty)
        try model.replaceChannels(channels)
        XCTAssertEqual(model.guideChannels.filter { $0.section == .recent }.map(\.channel.id), ["2", "1"])
        XCTAssertEqual(model.guideChannels.filter { $0.section == .favorites }.map(\.channel.id), ["1"])
        try model.replaceChannels([])
        XCTAssertEqual(model.recentChannelIDs, ["2", "1"])
        XCTAssertEqual(model.favoriteIDs, ["1"])
        XCTAssertEqual(store.saves, 0)
    }

    func testMutationsAreRestoredByANewModel() {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        model.toggleFavorite("1")
        for id in ["0", "1", "2", "3", "1"] {
            model.tune(id)
            XCTAssertTrue(model.recordWatched(id))
        }
        let reopened = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertEqual(reopened.favoriteIDs, ["1"])
        XCTAssertEqual(reopened.recentChannelIDs, ["1", "3", "2"])
        XCTAssertEqual(reopened.guideChannels.filter { $0.channel.id == "1" }.map(\.section), [.recent, .favorites, .channels])
        reopened.toggleFavorite("1")
        XCTAssertTrue(LiveTVPrototypeModel(channels: channels, preferencesStore: store).favoriteIDs.isEmpty)
    }

    func testPreviewAndFailedOrStaleConfirmationDoNotPersistHistory() throws {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let preview = LiveTVPreviewController(model: model)
        preview.focus("0")
        XCTAssertTrue(preview.commitPreview(try XCTUnwrap(preview.pendingRequest)))
        XCTAssertEqual(store.saves, 0)
        model.simulateTunerBusy = true
        preview.watch("1")
        XCTAssertFalse(model.recordWatched("1"))
        model.stop()
        XCTAssertFalse(model.recordWatched("0"))
        XCTAssertEqual(store.saves, 0)
        XCTAssertTrue(store.value.recentChannelIDs.isEmpty)
    }

    func testUnreadablePreferencesAreNotOverwrittenWithEmptyState() {
        let store = PreferencesFixtureStore()
        store.value = LiveTVPreferences(favoriteIDs: ["1"], recentChannelIDs: ["2"])
        store.failLoad = true
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        model.dismissPreferencesIssue()
        model.toggleFavorite("0")
        model.tune("3")
        XCTAssertFalse(model.recordWatched("3"))
        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.value.favoriteIDs, ["1"])
        XCTAssertEqual(store.value.recentChannelIDs, ["2"])
        store.failLoad = false
        model.retryPreferences()
        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.favoriteIDs, ["1"])
        XCTAssertEqual(model.recentChannelIDs, ["2"])
        model.toggleFavorite("0")
        XCTAssertEqual(store.value.favoriteIDs, ["0", "1"])
    }

    func testFailedSaveIsVisibleAndRetryCommitsTheOriginalMutation() {
        let store = PreferencesFixtureStore()
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        store.failSave = true
        model.toggleFavorite("1")
        XCTAssertEqual(model.preferencesIssue, .saveFailed)
        XCTAssertTrue(model.favoriteIDs.isEmpty)
        XCTAssertTrue(store.value.favoriteIDs.isEmpty)
        model.dismissPreferencesIssue()
        store.failSave = false
        model.retryPreferences()
        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.favoriteIDs, ["1"])
        XCTAssertEqual(store.value.favoriteIDs, ["1"])
    }

    func testEachModelKeepsItsInjectedProfileStoreWhenAnotherProfileOpens() {
        let firstStore = PreferencesFixtureStore()
        let secondStore = PreferencesFixtureStore()
        let first = LiveTVPrototypeModel(channels: channels, preferencesStore: firstStore)
        let second = LiveTVPrototypeModel(channels: channels, preferencesStore: secondStore)
        first.toggleFavorite("0")
        first.tune("1")
        first.recordWatched("1")
        second.toggleFavorite("2")
        second.tune("3")
        second.recordWatched("3")
        XCTAssertEqual(firstStore.value.favoriteIDs, ["0"])
        XCTAssertEqual(firstStore.value.recentChannelIDs, ["1"])
        XCTAssertEqual(secondStore.value.favoriteIDs, ["2"])
        XCTAssertEqual(secondStore.value.recentChannelIDs, ["3"])
    }

    private var channels: [LiveTVPrototypeChannel] {
        (0..<4).map {
            LiveTVPrototypeChannel(
                id: "\($0)", number: $0, name: "Channel \($0)", category: "News",
                symbol: "tv", accent: 0, source: .iptv, tagline: ""
            )
        }
    }
}

private final class PreferencesFixtureStore: LiveTVPreferencesStoring, @unchecked Sendable {
    enum Failure: Error { case unavailable }
    var value = LiveTVPreferences(favoriteIDs: [], recentChannelIDs: [])
    var failLoad = false
    var failSave = false
    var saves = 0

    func load() throws -> LiveTVPreferences {
        if failLoad { throw Failure.unavailable }
        return value
    }

    func save(_ preferences: LiveTVPreferences) throws {
        if failSave { throw Failure.unavailable }
        value = preferences
        saves += 1
    }
}
