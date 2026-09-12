import CoreModels
import XCTest
@testable import AppRuntime

final class LibraryChannelCompletionMutationTests: XCTestCase {
    private var item: MediaItem {
        var item = MediaItem(id: "movie-1", title: "Movie", kind: .movie, sourceAccountID: "origin")
        item.providerIDs = ["imdb": "tt1234567"]
        return item
    }

    private var additionalSources: [MediaSourceRef] {
        [MediaSourceRef(accountID: "other", itemID: "other-movie", kind: .movie, providerKind: .plex)]
    }

    func testCompletionPreservesCanonicalFanoutWithoutAnyResumeOperation() throws {
        let completion = try XCTUnwrap(WatchMutationFactory.libraryChannelCompletion(
            item: item, accountID: "origin", additionalSources: additionalSources
        ))
        XCTAssertEqual(completion.played, true)
        XCTAssertNil(completion.resumePosition)
        XCTAssertFalse(completion.clearResume)
        XCTAssertNotNil(completion.trakt)
        XCTAssertEqual(Set(completion.targets.map(\.accountID)), ["origin", "other"])
        XCTAssertTrue(try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: item, played: true, primaryAccountID: "origin"
        )).clearResume)
    }

    func testCompletionRespectsCrossServerOptOut() throws {
        let completion = try XCTUnwrap(WatchMutationFactory.libraryChannelCompletion(
            item: item, accountID: "origin", additionalSources: additionalSources, crossServerSync: false
        ))
        XCTAssertEqual(completion.targets.map(\.accountID), ["origin"])
        XCTAssertFalse(completion.expansionPending)
        XCTAssertTrue(completion.identities.isEmpty)
        XCTAssertNil(completion.episodeOrigin)
    }

    func testCompletionCannotUseAnotherAccountOrMarkAnEntireSeries() {
        XCTAssertNil(WatchMutationFactory.libraryChannelCompletion(item: item, accountID: "other"))
        let series = MediaItem(id: "series", title: "Series", kind: .series, sourceAccountID: "origin")
        XCTAssertNil(WatchMutationFactory.libraryChannelCompletion(item: series, accountID: "origin"))
    }
}
