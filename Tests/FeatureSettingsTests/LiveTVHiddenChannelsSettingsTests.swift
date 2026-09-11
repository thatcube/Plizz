#if DEBUG && canImport(SwiftUI)
import CoreModels
import XCTest
@testable import FeatureSettings

@MainActor
final class LiveTVHiddenChannelsSettingsTests: XCTestCase {
    func testUnreadablePreferencesAreNotAnEmptySuccessfulList() {
        let store = HiddenSettingsStore()
        store.failsLoading = true
        let model = LiveTVHiddenChannelsSettingsModel(store: store)
        model.reload()
        XCTAssertFalse(model.hasLoadedPreferences)
        XCTAssertEqual(model.issue, .loadFailed)
        store.failsLoading = false
        model.retry()
        XCTAssertTrue(model.hasLoadedPreferences)
        XCTAssertEqual(model.hiddenChannels.map(\.id), ["one", "two"])
        XCTAssertNil(model.issue)
    }

    func testRestoreReloadsLatestPreferencesInsteadOfReplacingNewFavorites() {
        let store = HiddenSettingsStore()
        let model = LiveTVHiddenChannelsSettingsModel(store: store)
        model.reload()
        store.value = LiveTVPreferences(
            favoriteIDs: ["new"], recentChannelIDs: ["two"], hiddenChannels: store.value.hiddenChannels
        )
        model.restoreChannel(id: "one")
        XCTAssertEqual(model.hiddenChannels.map(\.id), ["two"])
        XCTAssertEqual(store.value.favoriteIDs, ["new"])
        XCTAssertEqual(store.value.recentChannelIDs, ["two"])
    }

    func testRestoreSurvivesAReadFailureAndRetriesTheRequestedAction() {
        let store = HiddenSettingsStore()
        let model = LiveTVHiddenChannelsSettingsModel(store: store)
        model.reload()
        store.failsLoading = true
        model.restoreChannel(id: "one")
        XCTAssertEqual(model.issue, .loadFailed)
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertEqual(model.hiddenChannels.count, 2)
        store.failsLoading = false
        model.retry()
        XCTAssertEqual(model.hiddenChannels.map(\.id), ["two"])
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertNil(model.issue)
    }

    func testRestoreAllSurvivesSaveFailureAndReentryWithoutClearingStoredState() {
        let store = HiddenSettingsStore()
        let model = LiveTVHiddenChannelsSettingsModel(store: store)
        model.reload()
        store.failsSaving = true
        model.restoreAllChannels()
        XCTAssertEqual(model.issue, .saveFailed)
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertEqual(store.value.hiddenChannels.count, 2)
        store.failsSaving = false
        model.reload()
        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertTrue(store.value.hiddenChannels.isEmpty)
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertNil(model.issue)
    }
}

private final class HiddenSettingsStore: LiveTVPreferencesStoring, @unchecked Sendable {
    enum Failure: Error { case unavailable }
    var value = LiveTVPreferences(hiddenChannels: [
        LiveTVHiddenChannel(id: "one", name: "Channel One"),
        LiveTVHiddenChannel(id: "two", name: "Channel Two")
    ])
    var failsLoading = false
    var failsSaving = false

    func load() throws -> LiveTVPreferences {
        if failsLoading { throw Failure.unavailable }
        return value
    }

    func save(_ preferences: LiveTVPreferences) throws {
        if failsSaving { throw Failure.unavailable }
        value = preferences
    }
}
#endif
