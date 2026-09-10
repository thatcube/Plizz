import CoreGraphics
import XCTest
@testable import FeatureHome

final class SeriesSeasonRevealEdgeTests: XCTestCase {
    func testFullyVisibleChipDoesNotMoveTheSeasonBar() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 20, y: 0, width: 160, height: 60),
            viewportWidth: 600
        ))
    }

    func testToleranceAvoidsSubpixelReveal() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: -0.4, y: 0, width: 600.8, height: 60),
            viewportWidth: 600
        ))
    }

    func testTrailingClippingRevealsToTrailingEdge() {
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: 520, y: 0, width: 160, height: 60),
                viewportWidth: 600
            ),
            .trailing
        )
    }

    func testLeadingClippingRevealsToLeadingEdge() {
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: -80, y: 0, width: 160, height: 60),
                viewportWidth: 600
            ),
            .leading
        )
    }

    func testMissingViewportDoesNotRequestReveal() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 100, y: 0, width: 160, height: 60),
            viewportWidth: 0
        ))
    }

    func testFocusClearanceRequiresAComfortablyVisibleChip() {
        XCTAssertNil(SeriesSeasonRevealEdge.clippedEdge(
            frame: CGRect(x: 32, y: 0, width: 160, height: 60),
            viewportWidth: 600,
            clearance: 32
        ))
        XCTAssertEqual(
            SeriesSeasonRevealEdge.clippedEdge(
                frame: CGRect(x: 420, y: 0, width: 160, height: 60),
                viewportWidth: 600,
                clearance: 32
            ),
            .trailing
        )
    }

    func testRevealAnchorPlacesChipInsideFocusComfortMargin() {
        let viewportWidth: CGFloat = 600
        let targetWidth: CGFloat = 160
        let clearance: CGFloat = 32

        let trailing = SeriesSeasonRevealEdge.trailing.revealAnchor(
            targetWidth: targetWidth,
            viewportWidth: viewportWidth,
            clearance: clearance
        )
        let trailingMaxX = trailing.x * (viewportWidth - targetWidth) + targetWidth
        XCTAssertEqual(trailingMaxX, viewportWidth - clearance, accuracy: 0.001)

        let leading = SeriesSeasonRevealEdge.leading.revealAnchor(
            targetWidth: targetWidth,
            viewportWidth: viewportWidth,
            clearance: clearance
        )
        let leadingMinX = leading.x * (viewportWidth - targetWidth)
        XCTAssertEqual(leadingMinX, clearance, accuracy: 0.001)
    }
}

final class SeriesDetailBrowserPolicyTests: XCTestCase {
    func testUnknownSeasonsRetainAnEntryAndBlockAbout() {
        XCTAssertTrue(SeriesDetailBrowserPolicy.showsSeasonEntry(childrenLoaded: false, hasSeasons: false))
        XCTAssertFalse(SeriesDetailBrowserPolicy.allowsLowerContent(
            browserEntered: false, hasEmptyBrowser: false
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.allowsEpisodeEntry(
            browserEntered: false, hasSeasonEntry: true, opensOnEpisode: false
        ))
    }

    func testLoadedSeasonsStillReceiveFirstDownBeforeEpisodesOrAbout() {
        XCTAssertTrue(SeriesDetailBrowserPolicy.showsSeasonEntry(childrenLoaded: true, hasSeasons: true))
        XCTAssertFalse(SeriesDetailBrowserPolicy.allowsEpisodeEntry(
            browserEntered: false, hasSeasonEntry: true, opensOnEpisode: false
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.allowsEpisodeEntry(
            browserEntered: true, hasSeasonEntry: true, opensOnEpisode: false
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.allowsLowerContent(
            browserEntered: true, hasEmptyBrowser: false
        ))
    }

    func testDirectEpisodeAndGenuinelyEmptySeriesKeepTheirEntryPaths() {
        XCTAssertTrue(SeriesDetailEntryPolicy.permitsInitialRailEntry(
            hasInitialEpisode: true, hasSettledOpeningFocus: false
        ))
        XCTAssertFalse(SeriesDetailEntryPolicy.permitsInitialRailEntry(
            hasInitialEpisode: true, hasSettledOpeningFocus: true
        ))
        XCTAssertFalse(SeriesDetailEntryPolicy.permitsInitialRailEntry(
            hasInitialEpisode: false, hasSettledOpeningFocus: false
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.allowsEpisodeEntry(
            browserEntered: false, hasSeasonEntry: true, opensOnEpisode: true
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.showsSeasonEntry(childrenLoaded: true, hasSeasons: false))
        XCTAssertTrue(SeriesDetailBrowserPolicy.allowsEpisodeEntry(
            browserEntered: false, hasSeasonEntry: false, opensOnEpisode: false
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.allowsLowerContent(
            browserEntered: false, hasEmptyBrowser: true
        ))
    }

    func testWholeSeriesEntryClaimsHeroPlay() {
        XCTAssertTrue(SeriesDetailEntryPolicy.claimsHeroPlay(
            hasOpenedOnce: false,
            hasInitialEpisode: false
        ))
    }

    func testIndividualEpisodeEntryLeavesInitialFocusToRail() {
        XCTAssertFalse(SeriesDetailEntryPolicy.claimsHeroPlay(
            hasOpenedOnce: false,
            hasInitialEpisode: true
        ))
    }

    func testReturningPageDoesNotReclaimHeroPlay() {
        XCTAssertFalse(SeriesDetailEntryPolicy.claimsHeroPlay(
            hasOpenedOnce: true,
            hasInitialEpisode: false
        ))
    }

    func testLooseEpisodeBrowserRearmsWhenHeroRegainsFocus() {
        XCTAssertTrue(SeriesDetailBrowserPolicy.rearmsEpisodeRailOnHeroFocus(hasSeasons: false))
        XCTAssertFalse(SeriesDetailBrowserPolicy.rearmsEpisodeRailOnHeroFocus(hasSeasons: true))
    }

    func testCastRevealsOnlyWhenAnEmptyBrowserHasFinishedLoading() {
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: false,
            hasSeasons: false,
            hasEpisodes: false
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: true,
            hasEpisodes: false
        ))
        XCTAssertFalse(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: false,
            hasEpisodes: true
        ))
        XCTAssertTrue(SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: true,
            hasSeasons: false,
            hasEpisodes: false
        ))
    }

    func testRequestAccessoryCannotStealInitialSeasonEntryFocus() {
        XCTAssertFalse(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: false,
            hasRequestHandler: true
        ))
        XCTAssertTrue(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: true,
            hasRequestHandler: true
        ))
        XCTAssertFalse(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: true,
            seasonBarEngaged: true,
            hasRequestHandler: false
        ))
        XCTAssertTrue(SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: false,
            seasonBarEngaged: false,
            hasRequestHandler: true
        ))
    }

    func testDiscoverySeriesInactiveCopyDistinguishesLoadingFromEmpty() {
        XCTAssertEqual(
            SeasonRequestHeroPresentation.inactiveTitle(
                availabilityLoaded: false,
                resolved: false
            ),
            "Loading Seasons…"
        )
        XCTAssertEqual(
            SeasonRequestHeroPresentation.inactiveTitle(
                availabilityLoaded: true,
                resolved: true
            ),
            "No Seasons to Request"
        )
    }

}
