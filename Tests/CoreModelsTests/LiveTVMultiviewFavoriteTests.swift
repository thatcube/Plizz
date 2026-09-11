import XCTest
@testable import CoreModels

final class LiveTVMultiviewFavoriteTests: XCTestCase {
    private let favorite = LiveTVMultiviewFavorite(
        id: "sports", name: "Sports night", channelIDs: ["one", "two", "three", "four"],
        layout: .mainAndStack)

    func testFavoriteRoundTripPreservesLayoutWithoutPlaybackSessionData() throws {
        let data = try JSONEncoder().encode(favorite)
        XCTAssertEqual(try JSONDecoder().decode(LiveTVMultiviewFavorite.self, from: data), favorite)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "name", "channelIDs", "layout", "corner", "insetSize"])
    }

    func testExistingPreferencesDecodeWithNoSavedMultiviews() throws {
        let data = Data(#"{"favoriteIDs":["one"],"recentChannelIDs":["two"]}"#.utf8)
        let decoded = try JSONDecoder().decode(LiveTVPreferences.self, from: data)
        XCTAssertEqual(decoded.favoriteIDs, ["one"])
        XCTAssertTrue(decoded.favoriteMultiviews.isEmpty)
    }

    func testFavoritePersistsAcrossStoreRecreationAndRemainsProfileScoped() throws {
        let suite = "LiveTVMultiviewFavoriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LiveTVPreferencesStore(defaults: defaults, namespace: "first")
        try first.save(LiveTVPreferences(favoriteIDs: ["one"], favoriteMultiviews: [favorite]))
        let reloaded = try LiveTVPreferencesStore(defaults: defaults, namespace: "first").load()
        XCTAssertEqual(reloaded.favoriteMultiviews, [favorite])
        XCTAssertEqual(reloaded.favoriteIDs, ["one"])
        XCTAssertTrue(try LiveTVPreferencesStore(defaults: defaults, namespace: "second").load().favoriteMultiviews.isEmpty)
    }

    func testChannelVisibilityAndIdentityChangesKeepFavoriteCompositions() {
        let preferences = LiveTVPreferences(favoriteMultiviews: [favorite])
        XCTAssertEqual(preferences.hidingChannel(id: "one", name: "One").favoriteMultiviews, [favorite])
        XCTAssertEqual(preferences.restoringChannel(id: "one").favoriteMultiviews, [favorite])
        XCTAssertEqual(preferences.restoringAllChannels().favoriteMultiviews, [favorite])
        let migrated = preferences.migratingChannelIDs(["one": "new-one", "two": "new-one"])
        XCTAssertEqual(migrated.favoriteMultiviews[0].channelIDs, ["new-one", "three", "four"])
        XCTAssertEqual(migrated.favoriteMultiviews[0].id, favorite.id)
        XCTAssertTrue(migrated.favoriteMultiviews[0].isValid)
    }

    func testInvalidFavoriteCannotOverwriteStoredPreferences() throws {
        let suite = "LiveTVMultiviewFavoriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveTVPreferencesStore(defaults: defaults)
        let valid = LiveTVPreferences(favoriteMultiviews: [favorite])
        try store.save(valid)
        let invalid = LiveTVMultiviewFavorite(
            name: "Duplicate channels", channelIDs: ["one", "one"], layout: .sideBySide)
        XCTAssertThrowsError(try store.save(LiveTVPreferences(favoriteMultiviews: [invalid])))
        XCTAssertEqual(try store.load(), valid)
        let encoded = try JSONEncoder().encode(LiveTVPreferences(favoriteMultiviews: [invalid]))
        XCTAssertThrowsError(try JSONDecoder().decode(LiveTVPreferences.self, from: encoded))
    }
}
