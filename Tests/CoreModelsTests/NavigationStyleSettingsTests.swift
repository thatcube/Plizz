import XCTest
@testable import CoreModels

final class NavigationStyleSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NavigationStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testUnsetProfileUsesNativeSidebar() {
        let store = NavigationStyleSettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.load(), .sidebar)
    }

    func testExplicitSelectionSurvivesDefaultChange() {
        let defaults = makeDefaults()
        let store = NavigationStyleSettingsStore(defaults: defaults)
        store.save(.rail)

        XCTAssertEqual(NavigationStyleSettingsStore(defaults: defaults).load(), .rail)
    }

    func testProfileNamespacesRemainIndependent() {
        let defaults = makeDefaults()
        let primary = NavigationStyleSettingsStore(defaults: defaults)
        let child = NavigationStyleSettingsStore(defaults: defaults, namespace: "child")

        primary.save(.tabBar)

        XCTAssertEqual(primary.load(), .tabBar)
        XCTAssertEqual(child.load(), .sidebar)
    }

    func testAccidentalExitDefaultsOffAndPersistsFalseAcrossRestarts() {
        let defaults = makeDefaults()
        let store = NavigationStyleSettingsStore(defaults: defaults)

        XCTAssertFalse(store.loadPreventsAccidentalExit())

        store.savePreventsAccidentalExit(true)
        XCTAssertTrue(
            NavigationStyleSettingsStore(defaults: defaults).loadPreventsAccidentalExit()
        )

        store.savePreventsAccidentalExit(false)
        XCTAssertFalse(
            NavigationStyleSettingsStore(defaults: defaults).loadPreventsAccidentalExit()
        )
    }

    func testAccidentalExitPreferenceIsIsolatedPerProfile() {
        let defaults = makeDefaults()
        let primary = NavigationStyleSettingsStore(defaults: defaults)
        let child = NavigationStyleSettingsStore(defaults: defaults, namespace: "child")

        child.savePreventsAccidentalExit(true)

        XCTAssertFalse(primary.loadPreventsAccidentalExit())
        XCTAssertTrue(child.loadPreventsAccidentalExit())
    }

    @MainActor
    func testModelUsesInjectedPersistenceForAccidentalExitPreference() {
        let store = NavigationStyleSettingsStore(defaults: makeDefaults())
        store.savePreventsAccidentalExit(true)
        let model = NavigationStyleSettingsModel(
            store: store,
            layoutStore: NavigationLibraryLayoutStore(defaults: makeDefaults())
        )
        XCTAssertTrue(model.preventsAccidentalExit)

        model.preventsAccidentalExit = false

        XCTAssertFalse(store.loadPreventsAccidentalExit())
    }

    func testLayoutStoreUsesInjectedPlatformDefaultWhenUnset() {
        let defaults = makeDefaults()
        let fallback = NavigationLibraryLayout(
            hiddenKeys: [NavigationLibraryLayout.watchlistKey]
        )
        let store = NavigationLibraryLayoutStore(
            defaults: defaults,
            defaultLayout: fallback
        )

        XCTAssertEqual(store.load(), fallback)

        var optedIn = fallback
        optedIn.setVisible(true, for: NavigationLibraryLayout.watchlistKey)
        store.save(optedIn)

        XCTAssertTrue(
            NavigationLibraryLayoutStore(
                defaults: defaults,
                defaultLayout: fallback
            ).load().isVisible(NavigationLibraryLayout.watchlistKey)
        )
    }

    func testSettingsCannotBeHiddenByMutationOrPersistedLegacyData() {
        let defaults = makeDefaults()
        let key = "com.plozz.navigationLibraryLayout"
        defaults.set(
            Data(
                """
                {"order":[],"hiddenKeys":["\(NavigationLibraryLayout.settingsKey)"]}
                """.utf8
            ),
            forKey: key
        )

        let store = NavigationLibraryLayoutStore(defaults: defaults)
        var layout = store.load()
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.settingsKey))
        XCTAssertFalse(layout.hiddenKeys.contains(NavigationLibraryLayout.settingsKey))

        layout.hiddenKeys.insert(NavigationLibraryLayout.settingsKey)
        store.save(layout)
        XCTAssertFalse(store.load().hiddenKeys.contains(NavigationLibraryLayout.settingsKey))

        layout.setVisible(false, for: NavigationLibraryLayout.settingsKey)
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.settingsKey))
    }

    @MainActor
    func testWatchlistVisibilityPersistsPerProfile() {
        let defaults = makeDefaults()
        func model(namespace: String?) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(
                    defaults: defaults,
                    namespace: namespace
                ),
                layoutStore: NavigationLibraryLayoutStore(
                    defaults: defaults,
                    namespace: namespace
                )
            )
        }

        let primary = model(namespace: nil)
        let child = model(namespace: "child")
        XCTAssertTrue(primary.showsWatchlist)
        XCTAssertTrue(child.showsWatchlist)

        primary.showsWatchlist = false

        XCTAssertFalse(model(namespace: nil).showsWatchlist)
        XCTAssertTrue(model(namespace: "child").showsWatchlist)
    }

    @MainActor
    func testResetNavigationRestoresEveryShortcutIncludingFormerSeparateToggles() {
        let defaults = makeDefaults()
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults)
        )
        let available = NavigationRailPlan.customizableKeys(visibleLibraries: [])
        model.applyLibrarySections(
            .init(
                enabled: [NavigationLibraryLayout.settingsKey],
                disabled: available.filter { $0 != NavigationLibraryLayout.settingsKey }
            ),
            available: available
        )
        XCTAssertFalse(model.showsWatchlist)
        XCTAssertFalse(model.showsMusic)
        model.resetLibraryLayout()
        XCTAssertEqual(model.librarySections(available: available).enabled, available)
        XCTAssertTrue(model.showsWatchlist)
        XCTAssertTrue(model.showsMusic)
        XCTAssertEqual(NavigationLibraryLayoutStore(defaults: defaults).load(), .default)
    }

    @MainActor
    func testFullNavigationLayoutRemainsIndependentAcrossProfiles() {
        let defaults = makeDefaults()
        func model(namespace: String?) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(defaults: defaults, namespace: namespace),
                layoutStore: NavigationLibraryLayoutStore(defaults: defaults, namespace: namespace)
            )
        }
        let available = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.settingsKey,
        ]
        let primary = model(namespace: nil)
        primary.applyLibrarySections(
            .init(
                enabled: [
                    NavigationLibraryLayout.settingsKey,
                    NavigationLibraryLayout.searchKey,
                ],
                disabled: [NavigationLibraryLayout.homeKey]
            ),
            available: available
        )

        XCTAssertEqual(
            model(namespace: nil).librarySections(available: available).enabled,
            [NavigationLibraryLayout.settingsKey, NavigationLibraryLayout.searchKey]
        )
        XCTAssertEqual(
            model(namespace: "child").librarySections(available: available).enabled,
            available
        )
    }
}
