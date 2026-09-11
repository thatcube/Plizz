import CoreModels
import XCTest
@testable import FeatureHomeCore

final class CompactDetailGenresTests: XCTestCase {
    private func presentation(_ genres: [String]) -> HeroPresentation {
        var item = MediaItem(id: "title", title: "A title", kind: .movie)
        item.genres = genres
        return HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail)
    }

    func testLimitsDisplayedGenresAfterNormalizingAndDeduplicating() {
        let focused = presentation(["Science Fiction", "Sci-Fi", "Drama", "Adventure"])
        XCTAssertEqual(
            HeroContentPolicy.compactDetailGenres(focused: focused, root: focused),
            ["Sci-Fi", "Drama"]
        )
        XCTAssertEqual(
            HeroContentPolicy.genres(focused: focused, root: focused),
            ["Sci-Fi", "Drama", "Adventure"],
            "Only the compact hero is capped, not the complete details."
        )
    }

    func testUsesTheRootGenresWhenTheEpisodeHasNone() {
        XCTAssertEqual(
            HeroContentPolicy.compactDetailGenres(
                focused: presentation([]),
                root: presentation(["Adventure", "Fantasy", "Science Fiction", "Thriller"])
            ),
            ["Adventure", "Fantasy"]
        )
    }

    func testMissingOrSingleGenresDoNotCreateExtraEntries() {
        for genres in [[], ["Drama"]] {
            let item = presentation(genres)
            XCTAssertEqual(
                HeroContentPolicy.compactDetailGenres(focused: item, root: item),
                genres
            )
        }
    }
}
