import XCTest
@testable import CoreModels

/// The rail's arrangement rules. These are the ones a user notices immediately if
/// they're wrong — a library that vanishes when a server is added, an order that
/// resets, or a hidden library that comes back on relaunch.
final class NavigationRailPlanTests: XCTestCase {
    func testEditorDefaultsMatchEachTVNavigationStyle() {
        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .rail),
            NavigationDestinationDefaults.rail(visibleLibraries: [], hasMusic: true)
        )
        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .tabBar),
            NavigationDestinationDefaults.compact(hasMusic: true)
        )
        XCTAssertFalse(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .tabBar)
                .contains(NavigationLibraryLayout.allLibrariesKey)
        )
    }

    func testIOSCanHideEveryContentDestinationIncludingDownloads() {
        let available = NavigationDestinationDefaults.iOS
        XCTAssertTrue(available.contains(NavigationLibraryLayout.downloadsKey))
        let layout = NavigationLibraryLayout(hiddenKeys: Set(available))
        XCTAssertEqual(layout.visibleKeys(available: available), [NavigationLibraryLayout.settingsKey])
    }

    func testIOSDownloadsAndSearchCanMoveAheadOfHome() {
        let available = NavigationDestinationDefaults.iOS
        let first = [NavigationLibraryLayout.downloadsKey, NavigationLibraryLayout.searchKey]
        let layout = NavigationLibraryLayout(order: first)
        XCTAssertEqual(Array(layout.visibleKeys(available: available).prefix(2)), first)
    }


    private func library(
        _ id: String,
        title: String,
        account: String,
        kind: MediaItemKind = .movie,
        isMusic: Bool = false
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: account,
            serverName: "Server \(account)",
            providerKind: .jellyfin,
            library: MediaLibrary(
                id: id,
                title: title,
                kind: kind,
                isMusic: isMusic,
                sourceAccountID: account
            )
        )
    }

    // MARK: Available keys

    func testAvailableKeysLeadWithAllLibrariesAndExcludeMusic() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Songs", account: "a", isMusic: true),
            library("3", title: "Shows", account: "a", kind: .series)
        ]
        XCTAssertEqual(
            NavigationRailPlan.availableKeys(visibleLibraries: libraries),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )
    }

    func testCustomizableKeysIncludeEveryBuiltInAndExcludeMusicLibraries() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Songs", account: "a", isMusic: true),
        ]
        var expected = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
        ]
        #if DEBUG
        expected.append(NavigationLibraryLayout.liveTVKey)
        #endif
        expected += [
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: libraries),
            expected
        )
    }

    // MARK: Default arrangement

    func testDefaultLayoutShowsEverythingInDiscoveryOrder() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series)
        ]
        let entries = NavigationRailPlan.entries(visibleLibraries: libraries, layout: .default)
        XCTAssertEqual(
            entries.map(\.key),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:2"]
        )
        XCTAssertTrue(entries[0].isAllLibraries)
        XCTAssertEqual(entries[1].library?.library.title, "Movies")
    }

    func testCombinedEntryIsOmittedWhenThereIsNothingToCombine() {
        // One library means "All Libraries" would just be a duplicate of it, and
        // zero means it would open an empty grid.
        let single = [library("1", title: "Movies", account: "a")]
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: single, layout: .default).map(\.key),
            ["a:1"]
        )
        XCTAssertTrue(NavigationRailPlan.entries(visibleLibraries: [], layout: .default).isEmpty)
    }

    // MARK: Reordering + hiding

    func testExplicitOrderIsHonouredAndNewLibrariesAppendRatherThanVanish() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
            library("3", title: "Anime", account: "a", kind: .series)
        ]
        var layout = NavigationLibraryLayout(
            order: ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1"]
        )
        // "a:3" was discovered after the arrangement was saved.
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )

        layout.setVisible(false, for: "a:1")
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:3"]
        )
    }

    func testLegacyLibraryOnlyOrderKeepsEachStylesBuiltInDefaults() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
        ]
        let layout = NavigationLibraryLayout(
            order: ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1"]
        )
        let available = [
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            "a:2",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: available
            ),
            [.search, .home, .watchlist, .library("a:2"), .allLibraries, .library("a:1"), .settings]
        )
    }

    func testExplicitBuiltInOrderWinsAcrossSupportedDestinations() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
        ]
        let layout = NavigationLibraryLayout(order: [
            NavigationLibraryLayout.settingsKey,
            "a:2",
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            NavigationLibraryLayout.watchlistKey,
        ])
        let available = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            "a:2",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: available
            ),
            [.settings, .library("a:2"), .search, .home, .allLibraries, .library("a:1"), .watchlist]
        )
    }

    func testApplyingAnEditPreservesTheArrangementOfAnOfflineLibrary() {
        // A server that is briefly unreachable must not cost the viewer the
        // arrangement they set for its libraries.
        var layout = NavigationLibraryLayout(
            order: ["a:1", "b:1", "a:2"],
            hiddenKeys: ["b:1"]
        )
        let available = ["a:1", "a:2"]
        let edited = OrderedVisibilityList.Sections(enabled: ["a:2"], disabled: ["a:1"])
        layout.apply(edited, available: available)

        XCTAssertEqual(layout.order, ["a:2", "b:1", "a:1"])
        XCTAssertEqual(layout.hiddenKeys, ["b:1", "a:1"])
    }

    func testApplyingAnEditUnhidesALibraryMovedBackAboveTheDivider() {
        var layout = NavigationLibraryLayout(order: ["a:1", "a:2"], hiddenKeys: ["a:2"])
        let available = ["a:1", "a:2"]
        layout.apply(
            OrderedVisibilityList.Sections(enabled: ["a:1", "a:2"], disabled: []),
            available: available
        )
        XCTAssertTrue(layout.hiddenKeys.isEmpty)
        XCTAssertEqual(layout.visibleKeys(available: available), ["a:1", "a:2"])
    }

    func testEditingLibrariesPreservesOptionalDestinationVisibility() {
        var layout = NavigationLibraryLayout(
            hiddenKeys: [NavigationLibraryLayout.watchlistKey]
        )
        layout.apply(
            OrderedVisibilityList.Sections(enabled: ["a:1"], disabled: []),
            available: ["a:1"]
        )

        XCTAssertFalse(layout.isVisible(NavigationLibraryLayout.watchlistKey))
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.musicKey))
    }

    // MARK: Selection pruning

    func testSelectionFallsBackToFirstVisibleDestinationInsteadOfHiddenHome() {
        let destinations: [NavigationRailDestination] = [
            .search,
            .library("a:1"),
            .settings,
        ]
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(
                .library("a:1"),
                destinations: destinations
            ),
            .library("a:1")
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(
                .library("gone:9"),
                destinations: destinations
            ),
            .search
        )
    }

    func testAllHiddenDestinationsStillRenderAndFallBackToSettings() {
        var hidden: Set<String> = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
        ]
        #if DEBUG
        hidden.insert(NavigationLibraryLayout.liveTVKey)
        #endif
        let layout = NavigationLibraryLayout(hiddenKeys: hidden)
        let libraries = [library("1", title: "Movies", account: "a")]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: NavigationRailPlan.customizableKeys(
                    visibleLibraries: libraries
                )
            ),
            [.settings]
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.home, destinations: [.settings]),
            .settings
        )

        // Even a style bug that supplies no destinations cannot fall back Home.
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.home, destinations: []),
            .settings
        )
    }

    // MARK: Scene-storage round trip

    func testDestinationStorageValueRoundTrips() {
        var cases: [NavigationRailDestination] = [
            .home, .search, .watchlist, .music, .settings, .allLibraries,
            .library("acct:lib:with:colons")
        ]
        #if DEBUG
        cases.append(.liveTV)
        #endif
        for destination in cases {
            XCTAssertEqual(
                NavigationRailDestination(storageValue: destination.storageValue),
                destination
            )
        }
        XCTAssertNil(NavigationRailDestination(storageValue: "nonsense"))
    }
}
