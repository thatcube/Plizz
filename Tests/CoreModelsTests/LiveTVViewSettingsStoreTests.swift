import XCTest
@testable import CoreModels

final class LiveTVViewSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LiveTVViewSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingValuesLoadDocumentedDefaults() {
        let settings = LiveTVViewSettingsStore(defaults: makeDefaults()).load()

        XCTAssertFalse(settings.sortByName)
        XCTAssertTrue(settings.autoPreview)
        XCTAssertFalse(settings.keepWatchingWhileBrowsing)
        XCTAssertFalse(settings.favoritesOnly)
        XCTAssertFalse(settings.guideOnly)
        XCTAssertFalse(settings.wifiOnly)
    }

    func testAllValuesRoundTripAcrossStoreInstances() {
        let defaults = makeDefaults()
        let settings = LiveTVViewSettings(
            sortByName: true,
            autoPreview: false,
            keepWatchingWhileBrowsing: true,
            favoritesOnly: true,
            guideOnly: true,
            wifiOnly: true
        )

        LiveTVViewSettingsStore(defaults: defaults).save(settings)
        let reopened = LiveTVViewSettingsStore(defaults: defaults)

        XCTAssertEqual(reopened.load(), settings)
    }

    func testNamespacesIsolateProfilesAndKeepDefaultProfileUnscoped() {
        let defaults = makeDefaults()
        let primaryProfile = Profile(id: ProfileStore.defaultProfileID, name: "Primary")
        let secondaryProfile = Profile(id: "profile-secondary", name: "Secondary")
        let primaryNamespace = primaryProfile.settingsNamespace(
            isDefault: primaryProfile.id == ProfileStore.defaultProfileID
        )
        let secondaryNamespace = secondaryProfile.settingsNamespace(
            isDefault: secondaryProfile.id == ProfileStore.defaultProfileID
        )
        let primary = LiveTVViewSettingsStore(
            defaults: defaults,
            namespace: primaryNamespace
        )
        let secondary = LiveTVViewSettingsStore(
            defaults: defaults,
            namespace: secondaryNamespace
        )

        primary.save(LiveTVViewSettings(sortByName: true, autoPreview: false))
        secondary.save(LiveTVViewSettings(keepWatchingWhileBrowsing: true, favoritesOnly: true, guideOnly: true))

        XCTAssertEqual(
            primary.load(),
            LiveTVViewSettings(sortByName: true, autoPreview: false)
        )
        XCTAssertEqual(
            secondary.load(),
            LiveTVViewSettings(keepWatchingWhileBrowsing: true, favoritesOnly: true, guideOnly: true)
        )
        XCTAssertEqual(
            defaults.object(forKey: LiveTVViewSettingsStore.sortByNameKey) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(
                forKey: SettingsKey.scoped(
                    LiveTVViewSettingsStore.favoritesOnlyKey,
                    namespace: secondaryNamespace
                )
            ) as? Bool,
            true
        )
        XCTAssertEqual(
            defaults.object(forKey: LiveTVViewSettingsStore.keepWatchingWhileBrowsingKey) as? Bool,
            false
        )
        XCTAssertEqual(
            defaults.object(forKey: SettingsKey.scoped(
                LiveTVViewSettingsStore.keepWatchingWhileBrowsingKey, namespace: secondaryNamespace
            )) as? Bool,
            true
        )
    }

    func testSettingsAreStoredAsTypedBooleans() {
        let defaults = makeDefaults()
        LiveTVViewSettingsStore(defaults: defaults).save(
            LiveTVViewSettings(
                sortByName: true,
                autoPreview: false,
                keepWatchingWhileBrowsing: true,
                favoritesOnly: true,
                guideOnly: false
            )
        )

        XCTAssertEqual(defaults.object(forKey: LiveTVViewSettingsStore.sortByNameKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: LiveTVViewSettingsStore.autoPreviewKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: LiveTVViewSettingsStore.keepWatchingWhileBrowsingKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: LiveTVViewSettingsStore.favoritesOnlyKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: LiveTVViewSettingsStore.guideOnlyKey) as? Bool, false)
    }

    func testLegacySettingsKeepTheirValuesAndFollowFocusAfterWatching() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: LiveTVViewSettingsStore.sortByNameKey)
        defaults.set(false, forKey: LiveTVViewSettingsStore.autoPreviewKey)
        defaults.set(true, forKey: LiveTVViewSettingsStore.favoritesOnlyKey)
        defaults.set(true, forKey: LiveTVViewSettingsStore.guideOnlyKey)

        XCTAssertEqual(
            LiveTVViewSettingsStore(defaults: defaults).load(),
            LiveTVViewSettings(sortByName: true, autoPreview: false, favoritesOnly: true, guideOnly: true)
        )
        XCTAssertNil(defaults.object(forKey: LiveTVViewSettingsStore.keepWatchingWhileBrowsingKey))
    }

    func testLegacySecondaryProfileDoesNotInheritPrimaryPostWatchPreference() {
        let defaults = makeDefaults()
        LiveTVViewSettingsStore(defaults: defaults).save(
            LiveTVViewSettings(keepWatchingWhileBrowsing: true)
        )
        let namespace = "legacy-secondary"
        defaults.set(true, forKey: SettingsKey.scoped(
            LiveTVViewSettingsStore.sortByNameKey, namespace: namespace
        ))

        XCTAssertEqual(
            LiveTVViewSettingsStore(defaults: defaults, namespace: namespace).load(),
            LiveTVViewSettings(sortByName: true)
        )
    }

    func testCellularIsAllowedByDefaultForEveryProfileAndWifiOnlyIsScoped() {
        let defaults = makeDefaults()
        let primary = LiveTVViewSettingsStore(defaults: defaults)
        let child = LiveTVViewSettingsStore(defaults: defaults, namespace: "child")
        XCTAssertFalse(primary.load().wifiOnly)
        XCTAssertFalse(child.load().wifiOnly)
        child.save(LiveTVViewSettings(wifiOnly: true))
        XCTAssertTrue(LiveTVViewSettingsStore(defaults: defaults, namespace: "child").load().wifiOnly)
        XCTAssertFalse(primary.load().wifiOnly)
        child.save(LiveTVViewSettings(wifiOnly: false))
        XCTAssertFalse(child.load().wifiOnly)
    }

    func testMalformedWifiOnlyDoesNotChangeCellularDefault() {
        let defaults = makeDefaults()
        defaults.set("wifi", forKey: LiveTVViewSettingsStore.wifiOnlyKey)
        XCTAssertFalse(LiveTVViewSettingsStore(defaults: defaults).load().wifiOnly)
    }

    func testInvalidPostWatchValueFallsBackWithoutDiscardingExistingSettings() {
        let defaults = makeDefaults()
        defaults.set("keep-watching", forKey: LiveTVViewSettingsStore.keepWatchingWhileBrowsingKey)
        defaults.set(false, forKey: LiveTVViewSettingsStore.autoPreviewKey)
        defaults.set(true, forKey: LiveTVViewSettingsStore.guideOnlyKey)

        XCTAssertEqual(
            LiveTVViewSettingsStore(defaults: defaults).load(),
            LiveTVViewSettings(autoPreview: false, guideOnly: true)
        )
    }

    func testPostWatchPreferenceCanBeTurnedOffWithoutChangingAutoPreview() {
        let defaults = makeDefaults()
        let store = LiveTVViewSettingsStore(defaults: defaults)
        store.save(LiveTVViewSettings(autoPreview: false, keepWatchingWhileBrowsing: true))
        var settings = store.load()
        settings.keepWatchingWhileBrowsing = false
        store.save(settings)

        XCTAssertEqual(
            LiveTVViewSettingsStore(defaults: defaults).load(),
            LiveTVViewSettings(autoPreview: false)
        )
    }

    @MainActor
    func testRecordedLegacyOwnerUsesTheSameNamespaceAsTheLiveDestination() {
        let defaults = makeDefaults()
        let profileStore = ProfileStore(defaults: defaults)
        let owner = Profile(id: "imported-owner", name: "Owner", createdAt: Date(timeIntervalSince1970: 0))
        profileStore.saveProfiles([owner])
        let profiles = ProfilesModel(store: profileStore)
        XCTAssertEqual(profiles.activeProfileID, owner.id)
        XCTAssertNil(profiles.activeNamespace)
        let settings = LiveTVViewSettings(sortByName: true, autoPreview: false)
        LiveTVViewSettingsStore(defaults: defaults, namespace: profiles.activeNamespace).save(settings)
        XCTAssertEqual(LiveTVViewSettingsStore(defaults: defaults).load(), settings)
        XCTAssertEqual(LiveTVViewSettingsStore(defaults: defaults, namespace: owner.id).load(), LiveTVViewSettings())
    }
}
