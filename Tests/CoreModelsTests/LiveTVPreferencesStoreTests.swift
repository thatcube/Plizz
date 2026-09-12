import XCTest
@testable import CoreModels

final class LiveTVPreferencesStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LiveTVPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingPreferencesLoadAsEmpty() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults(), namespace: nil)

        XCTAssertEqual(try store.load(), .empty)
    }

    func testPreferencesRoundTripAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let preferences = LiveTVPreferences(
            favoriteIDs: ["channel-1", "channel-3"],
            recentChannelIDs: ["channel-3", "channel-2", "channel-1"],
            hiddenChannels: [
                LiveTVHiddenChannel(id: "channel-2", name: "Local News"),
            ]
        )

        try LiveTVPreferencesStore(defaults: defaults, namespace: nil).save(preferences)
        let reopened = LiveTVPreferencesStore(defaults: defaults, namespace: nil)

        XCTAssertEqual(try reopened.load(), preferences)
    }

    func testEmptyPreferencesRoundTrip() throws {
        let defaults = makeDefaults()
        let store = LiveTVPreferencesStore(defaults: defaults, namespace: nil)

        try store.save(.empty)

        XCTAssertEqual(try store.load(), .empty)
        XCTAssertNotNil(defaults.data(forKey: LiveTVPreferencesStore.baseKey))
    }

    func testNamespacesIsolateProfiles() throws {
        let defaults = makeDefaults()
        let primary = LiveTVPreferencesStore(defaults: defaults, namespace: nil)
        let secondary = LiveTVPreferencesStore(
            defaults: defaults,
            namespace: "profile-secondary"
        )

        try primary.save(LiveTVPreferences(
            favoriteIDs: ["primary-favorite"],
            recentChannelIDs: ["primary-recent"],
            hiddenChannels: [
                LiveTVHiddenChannel(id: "primary-hidden", name: "Primary Hidden"),
            ]
        ))
        try secondary.save(LiveTVPreferences(
            favoriteIDs: ["secondary-favorite"],
            recentChannelIDs: ["secondary-recent"],
            hiddenChannels: [
                LiveTVHiddenChannel(id: "secondary-hidden", name: "Secondary Hidden"),
            ]
        ))

        XCTAssertEqual(try primary.load().favoriteIDs, ["primary-favorite"])
        XCTAssertEqual(try secondary.load().favoriteIDs, ["secondary-favorite"])
        XCTAssertEqual(try primary.load().recentChannelIDs, ["primary-recent"])
        XCTAssertEqual(try secondary.load().recentChannelIDs, ["secondary-recent"])
        XCTAssertEqual(try primary.load().hiddenChannelIDs, ["primary-hidden"])
        XCTAssertEqual(try secondary.load().hiddenChannelIDs, ["secondary-hidden"])
    }

    func testRecentChannelsAreUniqueAndBoundedToThree() throws {
        let preferences = LiveTVPreferences(
            favoriteIDs: [],
            recentChannelIDs: ["one", "two", "one", "three", "four"]
        )

        XCTAssertEqual(preferences.recentChannelIDs, ["one", "two", "three"])

        let data = try JSONEncoder().encode([
            "favoriteIDs": [String](),
            "recentChannelIDs": ["one", "two", "one", "three", "four"],
        ])
        let decoded = try JSONDecoder().decode(LiveTVPreferences.self, from: data)
        XCTAssertEqual(decoded.recentChannelIDs, ["one", "two", "three"])
    }

    func testLegacyRecordWithoutHiddenChannelsMigratesToEmptyHiddenList() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "favoriteIDs": ["favorite"],
            "recentChannelIDs": ["recent"],
        ])

        let decoded = try JSONDecoder().decode(LiveTVPreferences.self, from: data)

        XCTAssertEqual(decoded.favoriteIDs, ["favorite"])
        XCTAssertEqual(decoded.recentChannelIDs, ["recent"])
        XCTAssertTrue(decoded.hiddenChannels.isEmpty)
    }

    func testHiddenChannelsDeduplicateStableIDsAndRetainFirstDisplayName() throws {
        let preferences = LiveTVPreferences(
            favoriteIDs: ["favorite"],
            recentChannelIDs: ["recent"],
            hiddenChannels: [
                LiveTVHiddenChannel(id: "hidden", name: "Original Name"),
                LiveTVHiddenChannel(id: "hidden", name: "Duplicate Name"),
                LiveTVHiddenChannel(id: "other", name: "Other Channel"),
            ]
        )

        XCTAssertEqual(preferences.hiddenChannels, [
            LiveTVHiddenChannel(id: "hidden", name: "Original Name"),
            LiveTVHiddenChannel(id: "other", name: "Other Channel"),
        ])

        let data = try JSONSerialization.data(withJSONObject: [
            "favoriteIDs": ["favorite"],
            "recentChannelIDs": ["recent"],
            "hiddenChannels": [
                ["id": "hidden", "name": "Original Name"],
                ["id": "hidden", "name": "Duplicate Name"],
                ["id": "other", "name": "Other Channel"],
            ],
        ])
        let decoded = try JSONDecoder().decode(LiveTVPreferences.self, from: data)
        XCTAssertEqual(decoded.hiddenChannels, preferences.hiddenChannels)
    }

    func testHiddenChannelMutationsPreserveFavoritesAndRecents() {
        let original = LiveTVPreferences(
            favoriteIDs: ["favorite"],
            recentChannelIDs: ["recent"]
        )

        let hidden = original.hidingChannel(id: "hidden", name: "Hidden Channel")
        XCTAssertEqual(hidden.favoriteIDs, original.favoriteIDs)
        XCTAssertEqual(hidden.recentChannelIDs, original.recentChannelIDs)
        XCTAssertEqual(hidden.hiddenChannelIDs, ["hidden"])

        let restored = hidden.restoringChannel(id: "hidden")
        XCTAssertEqual(restored.favoriteIDs, original.favoriteIDs)
        XCTAssertEqual(restored.recentChannelIDs, original.recentChannelIDs)
        XCTAssertTrue(restored.hiddenChannels.isEmpty)

        let restoredAll = hidden
            .hidingChannel(id: "other", name: "Other Channel")
            .restoringAllChannels()
        XCTAssertEqual(restoredAll.favoriteIDs, original.favoriteIDs)
        XCTAssertEqual(restoredAll.recentChannelIDs, original.recentChannelIDs)
        XCTAssertTrue(restoredAll.hiddenChannels.isEmpty)
    }

    func testEncodedHiddenMetadataContainsNoPlaybackOrAuthenticationFields() throws {
        let data = try JSONEncoder().encode(LiveTVPreferences(
            hiddenChannels: [
                LiveTVHiddenChannel(id: "stable-id", name: "Display Name"),
            ]
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hidden = try XCTUnwrap(
            (object["hiddenChannels"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(Set(hidden.keys), ["id", "name"])
        XCTAssertEqual(hidden["id"] as? String, "stable-id")
        XCTAssertEqual(hidden["name"] as? String, "Display Name")
    }

    func testMalformedHiddenChannelsFailExplicitly() throws {
        let defaults = makeDefaults()
        let malformed = try JSONSerialization.data(withJSONObject: [
            "favoriteIDs": [String](),
            "recentChannelIDs": [String](),
            "hiddenChannels": "not-an-array",
        ])
        defaults.set(malformed, forKey: LiveTVPreferencesStore.baseKey)
        let store = LiveTVPreferencesStore(defaults: defaults)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .decodingFailed)
        }
        XCTAssertThrowsError(try store.save(.empty)) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .decodingFailed)
        }
        XCTAssertEqual(defaults.data(forKey: LiveTVPreferencesStore.baseKey), malformed)
    }

    func testCorruptPreferencesSurfaceTypedErrorAndAreNotOverwritten() throws {
        let defaults = makeDefaults()
        let key = SettingsKey.scoped(
            LiveTVPreferencesStore.baseKey,
            namespace: "profile-corrupt"
        )
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: key)
        let store = LiveTVPreferencesStore(
            defaults: defaults,
            namespace: "profile-corrupt"
        )

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .decodingFailed)
        }
        XCTAssertThrowsError(try store.save(.empty)) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .decodingFailed)
        }
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testWrongStoredTypeSurfacesTypedErrorAndIsNotOverwritten() throws {
        let defaults = makeDefaults()
        let key = SettingsKey.scoped(
            LiveTVPreferencesStore.baseKey,
            namespace: "profile-wrong-type"
        )
        defaults.set("not-data", forKey: key)
        let store = LiveTVPreferencesStore(
            defaults: defaults,
            namespace: "profile-wrong-type"
        )

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .invalidStoredValue)
        }
        XCTAssertThrowsError(try store.save(.empty)) { error in
            XCTAssertEqual(error as? LiveTVPreferencesStoreError, .invalidStoredValue)
        }
        XCTAssertEqual(defaults.string(forKey: key), "not-data")
    }
}
