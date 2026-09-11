import XCTest
@testable import CoreModels

final class SeriesDownloadPresentationTests: XCTestCase {
    private let season = MediaItem(id: "season-1", title: "Season 1", kind: .season)

    private func item(kind: MediaItemKind = .series, hasTMDB: Bool = true) -> MediaItem {
        var item = MediaItem(id: "show", title: "A Show", kind: kind)
        if hasTMDB { item.providerIDs["Tmdb"] = "123" }
        return item
    }

    func testLibraryDownloadsRemainAvailableWithoutSeerr() {
        let presentation = SeriesDownloadPresentation(
            item: item(), children: [season], isDiscoveryItem: false, seerConnected: false
        )
        XCTAssertTrue(presentation.isVisible)
        XCTAssertTrue(presentation.hasLibraryDownloads)
        XCTAssertFalse(presentation.canRequestSeasons)
    }

    func testOwnedShowCanDownloadAndRequestMissingSeasons() {
        let presentation = SeriesDownloadPresentation(
            item: item(), children: [season], isDiscoveryItem: false, seerConnected: true
        )
        XCTAssertTrue(presentation.isVisible)
        XCTAssertTrue(presentation.hasLibraryDownloads)
        XCTAssertTrue(presentation.canRequestSeasons)
        XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: false))
        XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: true))
    }

    func testUnownedShowCanOpenRequestOnlySheet() {
        for children in [[], [season]] {
            let presentation = SeriesDownloadPresentation(
                item: item(), children: children, isDiscoveryItem: true, seerConnected: true
            )
            XCTAssertTrue(presentation.isVisible)
            XCTAssertFalse(presentation.hasLibraryDownloads, "Discovery metadata is not downloadable media.")
            XCTAssertTrue(presentation.canRequestSeasons)
            XCTAssertTrue(presentation.showsHeroRequest(hasPlayAction: false))
            XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: true))
        }
    }

    func testRequestControlDoesNotDependOnLoadedLibrarySeasons() {
        let presentation = SeriesDownloadPresentation(
            item: item(), children: [], isDiscoveryItem: false, seerConnected: true
        )
        XCTAssertTrue(presentation.isVisible)
        XCTAssertTrue(presentation.canRequestSeasons)
        XCTAssertFalse(presentation.hasLibraryDownloads)
        XCTAssertTrue(presentation.showsHeroRequest(hasPlayAction: false))
        XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: true))
    }

    func testMissingConnectionOrMetadataCannotOfferRequests() {
        for (connected, hasTMDB) in [(false, true), (true, false), (false, false)] {
            let presentation = SeriesDownloadPresentation(
                item: item(hasTMDB: hasTMDB),
                children: [season],
                isDiscoveryItem: true,
                seerConnected: connected
            )
            XCTAssertFalse(presentation.canRequestSeasons)
            XCTAssertFalse(presentation.isVisible)
            XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: false))
        }
    }

    func testMoviesAndEpisodesKeepTheirExistingControls() {
        for kind in [MediaItemKind.movie, .episode] {
            let presentation = SeriesDownloadPresentation(
                item: item(kind: kind), children: [season], isDiscoveryItem: false, seerConnected: true
            )
            XCTAssertFalse(presentation.isVisible)
            XCTAssertFalse(presentation.hasLibraryDownloads)
            XCTAssertFalse(presentation.canRequestSeasons)
            XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: false))
        }
    }

    func testLooseEpisodesStillProvideOfflineDownloads() {
        let episode = MediaItem(id: "episode-1", title: "Episode 1", kind: .episode)
        let presentation = SeriesDownloadPresentation(
            item: item(hasTMDB: false), children: [episode], isDiscoveryItem: false, seerConnected: false
        )
        XCTAssertTrue(presentation.hasLibraryDownloads)
        XCTAssertTrue(presentation.isVisible)
    }

    func testPlayableOrDownloadableShowsKeepRequestsInTheSeasonManager() {
        for children in [[season], [MediaItem(id: "episode", title: "Episode", kind: .episode)]] {
            let presentation = SeriesDownloadPresentation(
                item: item(), children: children, isDiscoveryItem: false, seerConnected: true
            )
            XCTAssertTrue(presentation.canRequestSeasons)
            XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: false))
            XCTAssertFalse(presentation.showsHeroRequest(hasPlayAction: true))
        }
    }

    func testRequestOnlyShowsRetainHeroAccessForEveryRequestStatus() {
        for status in [
            MediaAvailabilityStatus.unknown, .pending, .processing, .deleted,
            .available, .partiallyAvailable
        ] {
            var show = item()
            show.availability = status
            let presentation = SeriesDownloadPresentation(
                item: show, children: [], isDiscoveryItem: true, seerConnected: true
            )
            XCTAssertTrue(presentation.showsHeroRequest(hasPlayAction: false),
                          "Server status alone does not provide a playable episode.")
        }
    }

    func testBulkDownloadLabelsDescribeTheirActualActions() {
        let cases: [(SeriesDownloadAction, String, String, Bool)] = [
            (.download, "Download All Available Episodes", "arrow.down.circle", true),
            (.preparing, "Preparing Downloads…", "clock", false),
            (.pause, "Pause Downloads", "pause.circle", true),
            (.resume, "Resume Downloads", "play.circle", true)
        ]
        for (action, title, icon, enabled) in cases {
            var resource = action.title
            resource.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: resource), title)
            XCTAssertEqual(action.systemImage, icon)
            XCTAssertEqual(action.isEnabled, enabled)
        }
    }

    func testDownloadDestinationCopyNamesThePhysicalDevice() {
        let cases: [(MediaDownloadDestination, String, String)] = [
            (.iPhone, "Download to This iPhone", "Downloading to this iPhone"),
            (.iPad, "Download to This iPad", "Downloading to this iPad"),
            (.device, "Download to This Device", "Downloading to this device"),
        ]
        for (destination, title, progressTitle) in cases {
            var resource = SeriesDownloadAction.download.title(for: destination)
            resource.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: resource), title)
            resource = destination.downloadingTitle
            resource.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: resource), progressTitle)
            for action in [SeriesDownloadAction.preparing, .pause, .resume] {
                XCTAssertEqual(
                    String(localized: action.title(for: destination)),
                    String(localized: action.title)
                )
            }
        }
    }
}
