#if os(tvOS)
import XCTest
import CoreModels
@testable import AppShell

final class NavigationRailPresentationTests: XCTestCase {
    func testSearchHidesCollapsedRailWithoutReservingItsInset() {
        let presentation = make(.search)
        XCTAssertTrue(presentation.usesPageButton)
        XCTAssertFalse(presentation.isRailVisible)
        XCTAssertFalse(presentation.isRailEnabled)
        XCTAssertEqual(presentation.contentInset, 0)
        XCTAssertEqual(presentation.headerHeight, NavigationRailMetrics.searchHeaderHeight)
        XCTAssertTrue(presentation.shouldEnterSearchContent)
        XCTAssertFalse(presentation.opensExpanded)
    }

    func testOpeningSearchRevealsTheRailBeforeRequestingFocus() {
        let opening = make(.search, opening: true)
        XCTAssertTrue(opening.isRailEnabled)
        XCTAssertTrue(opening.isRailVisible)
        XCTAssertTrue(opening.opensExpanded)
        XCTAssertFalse(opening.shouldEnterSearchContent)
        let expanded = make(.search, expanded: true)
        XCTAssertTrue(expanded.isRailEnabled)
        XCTAssertTrue(expanded.isRailVisible)
        XCTAssertEqual(expanded.contentInset, 0)
        XCTAssertEqual(expanded.headerHeight, opening.headerHeight)
        XCTAssertFalse(expanded.shouldEnterSearchContent)
        XCTAssertFalse(expanded.opensExpanded)
    }

    func testSearchCapsuleCannotWinEntryOrNavigationDismissal() {
        let search = make(.search)
        XCTAssertFalse(search.isPageButtonEnabled(hasEnteredContent: false))
        XCTAssertTrue(search.isPageButtonEnabled(hasEnteredContent: true))
        XCTAssertFalse(make(.search, opening: true).isPageButtonEnabled(hasEnteredContent: true))
        XCTAssertFalse(make(.search, expanded: true).isPageButtonEnabled(hasEnteredContent: true))
        XCTAssertFalse(make(.search).isPageButtonEnabled(hasEnteredContent: false))
    }

    func testSearchPageKeepsLeftPressesAndSwipesForNativeNavigation() {
        XCTAssertFalse(make(.search).isEdgeNavigationEnabled())
        XCTAssertFalse(make(.search, opening: true).isEdgeNavigationEnabled())
    }

    func testExpandedSearchNavigationStillAllowsRightToReturnToThePage() {
        XCTAssertTrue(make(.search, expanded: true).isEdgeNavigationEnabled())
    }

    func testSearchResultsAllowLeadingEdgeNavigationButNotWhileMenuIsOpening() {
        XCTAssertTrue(make(.search).isEdgeNavigationEnabled(searchResultsHaveFocus: true))
        XCTAssertFalse(make(.search, opening: true).isEdgeNavigationEnabled(searchResultsHaveFocus: true))
    }

    func testOtherRootDestinationsKeepPinnedNavigation() {
        var destinations: [NavigationRailDestination] = [
            .home, .watchlist, .settings, .music, .allLibraries
        ]
        #if DEBUG
        destinations.append(.liveTV)
        #endif
        for destination in destinations {
            let presentation = make(destination)
            XCTAssertFalse(presentation.usesPageButton)
            XCTAssertTrue(presentation.isRailVisible)
            XCTAssertTrue(presentation.isRailEnabled)
            XCTAssertTrue(presentation.isEdgeNavigationEnabled())
            XCTAssertEqual(presentation.contentInset, NavigationRailMetrics.contentInset)
            XCTAssertEqual(presentation.headerHeight, 0)
            XCTAssertFalse(presentation.shouldEnterSearchContent)
            XCTAssertFalse(make(destination, opening: true).opensExpanded)
        }
    }

    func testPinnedEntryDoesNotExpandRowsBeforeNativeFocusArrives() {
        for destination in [NavigationRailDestination.home, .settings, .library("account:movies")] {
            let pending = make(destination, opening: true)
            XCTAssertFalse(pending.opensExpanded)
            XCTAssertTrue(pending.isRailEnabled)
            XCTAssertEqual(
                NavigationGlassSurface.resolve(
                    isExpanded: pending.isExpanded || pending.opensExpanded,
                    showsPageButton: pending.showsPageButton, hasButtonFrame: false
                ),
                .none
            )
            let closed = make(destination)
            XCTAssertFalse(closed.opensExpanded)
            XCTAssertEqual(
                NavigationGlassSurface.resolve(
                    isExpanded: closed.isExpanded || closed.isOpening,
                    showsPageButton: closed.showsPageButton, hasButtonFrame: false
                ),
                .none
            )
        }
    }

    func testDetailsKeepNavigationHiddenEvenDuringAnOpenRequest() {
        let presentation = NavigationRailPresentation(
            destination: .search,
            chromeHidden: true,
            isExpanded: true,
            isOpening: true
        )
        XCTAssertFalse(presentation.isRailVisible)
        XCTAssertFalse(presentation.isRailEnabled)
        XCTAssertFalse(presentation.isEdgeNavigationEnabled())
        XCTAssertFalse(presentation.isEdgeNavigationEnabled(searchResultsHaveFocus: true))
        XCTAssertEqual(presentation.contentInset, 0)
        XCTAssertFalse(presentation.showsPageButton)
        XCTAssertEqual(presentation.headerHeight, 0)
        XCTAssertFalse(presentation.shouldEnterSearchContent)
        XCTAssertFalse(presentation.opensExpanded)
    }

    #if DEBUG
    func testLiveTVSearchSuppressionBlocksEvenAnAlreadyRequestedMenu() {
        for expanded in [false, true] {
            for opening in [false, true] {
                let presentation = NavigationRailPresentation(
                    destination: .liveTV, chromeHidden: true,
                    isExpanded: expanded, isOpening: opening
                )
                XCTAssertFalse(presentation.isRailVisible)
                XCTAssertFalse(presentation.isRailEnabled)
                XCTAssertFalse(presentation.isEdgeNavigationEnabled())
                XCTAssertFalse(presentation.showsPageButton)
                XCTAssertEqual(presentation.contentInset, 0)
            }
        }
    }
    #endif

    private func make(
        _ destination: NavigationRailDestination,
        expanded: Bool = false,
        opening: Bool = false
    ) -> NavigationRailPresentation {
        NavigationRailPresentation(
            destination: destination,
            chromeHidden: false,
            isExpanded: expanded,
            isOpening: opening
        )
    }
}
#endif
