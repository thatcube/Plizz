#if os(tvOS)
import XCTest
import CoreModels
@testable import AppShell

final class NavigationRailMetricsTests: XCTestCase {
    func testExpandedPanelUsesUniformOuterMargins() {
        XCTAssertEqual(NavigationRailMetrics.expandedPanelOuterMargin, 32)
        XCTAssertEqual(NavigationRailMetrics.expandedPanelLayoutInset, 36)
        XCTAssertEqual(NavigationRailMetrics.expandedWidth, 426)
        XCTAssertEqual(NavigationRailMetrics.itemIconSize, 24)
        XCTAssertEqual(NavigationRailMetrics.expandedRowHeight, 64)
    }

    func testExpandedRowsRemainInsetFromPanelEdges() {
        let horizontalInset = NavigationRailMetrics.expandedContentHorizontalPadding
            - NavigationRailMetrics.expandedRowBackgroundOutset
            - NavigationRailMetrics.expandedPanelLayoutInset
        let safeAreaInset: CGFloat = 49
        let verticalInset = NavigationRailMetrics.expandedContentVerticalPadding(
            safeAreaInset: safeAreaInset
        )
            + NavigationRailMetrics.bumperHeight
            + NavigationRailMetrics.itemVerticalPadding
            - NavigationRailMetrics.expandedPanelVerticalPadding(
                safeAreaInset: safeAreaInset
            )

        XCTAssertEqual(horizontalInset, NavigationRailMetrics.expandedPanelContentInset)
        XCTAssertEqual(verticalInset, NavigationRailMetrics.expandedPanelContentInset)
    }

    func testCollapsedIconPositionOnlyChangesHorizontallyDuringExpansion() {
        XCTAssertEqual(NavigationRailMetrics.leadingInset, 28)
        XCTAssertGreaterThan(
            NavigationRailMetrics.expandedContentHorizontalPadding,
            NavigationRailMetrics.leadingInset
        )
        XCTAssertEqual(
            NavigationRailMetrics.expandedTrailingPadding
                - NavigationRailMetrics.expandedContentHorizontalOffset,
            NavigationRailMetrics.expandedContentHorizontalPadding
        )
        XCTAssertEqual(NavigationRailMetrics.expandedRowContentWidth, 296)
        XCTAssertEqual(
            NavigationRailMetrics.expandedLabelWidth
                + NavigationRailMetrics.expandedLabelOffset,
            NavigationRailMetrics.expandedRowContentWidth
        )
        XCTAssertEqual(NavigationRailMetrics.verticalPadding, 14)
    }
}

final class NavigationDestinationLayoutTests: XCTestCase {
    private func library(
        _ id: String,
        kind: MediaItemKind = .movie,
        isMusic: Bool = false
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: "account",
            accountName: "Account",
            serverName: "Server",
            providerKind: .jellyfin,
            library: MediaLibrary(
                id: id,
                title: id,
                kind: kind,
                isMusic: isMusic,
                sourceAccountID: "account"
            )
        )
    }

    func testCompactNavigationPreservesLegacyOrderAndOmitsLibraries() {
        let keys = NavigationDestinationDefaults.compact(hasMusic: true)
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
            NavigationLibraryLayout.settingsKey,
        ]
        XCTAssertEqual(keys, expected)
    }

    func testSidebarAndRailKeepTheirLegacyDefaultsWhileSupportingLibraries() {
        let libraries = [
            library("movies"),
            library("music", isMusic: true),
            library("shows", kind: .series),
        ]

        let sidebar = NavigationDestinationDefaults.sidebar(
            visibleLibraries: libraries,
            hasMusic: true
        )
        XCTAssertEqual(sidebar.first, NavigationLibraryLayout.homeKey)
        XCTAssertEqual(Array(sidebar.suffix(4)), [
            NavigationLibraryLayout.allLibrariesKey,
            "account:movies",
            "account:shows",
            NavigationLibraryLayout.settingsKey,
        ])
        XCTAssertFalse(sidebar.contains("account:music"))

        let rail = NavigationDestinationDefaults.rail(
            visibleLibraries: libraries,
            hasMusic: true
        )
        XCTAssertEqual(rail.first, NavigationLibraryLayout.searchKey)
        XCTAssertEqual(rail.last, NavigationLibraryLayout.settingsKey)
        XCTAssertTrue(rail.contains("account:movies"))
        XCTAssertFalse(rail.contains("account:music"))
    }
}
#endif
