#if canImport(SwiftUI)
import CoreModels
import XCTest
@testable import CoreUI

@MainActor
final class DetailInformationConsolidationTests: XCTestCase {
    private let audience = ExternalRating(source: .rottenTomatoesAudience, value: 88, scale: .percent)
    private let imdb = ExternalRating(source: .imdb, value: 7.9, scale: .outOfTen)

    private func item(overview: String? = "The series synopsis.") -> MediaItem {
        var item = MediaItem(id: "show", title: "The show", kind: .series)
        item.overview = overview
        item.ratings = [imdb, audience]
        return item
    }

    func testDefaultKeepsTheExistingCompleteInformation() {
        let sections = DetailInformationSections(item: item(), horizontalInset: 22)
        XCTAssertTrue(sections.hasAbout)
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testHeaderSummaryAndRatingsAreNotRepeated() {
        let sections = DetailInformationSections(
            item: item(), horizontalInset: 22,
            overviewAlreadyShown: "  The series synopsis.\n",
            ratingsAlreadyShown: [imdb, audience]
        )
        XCTAssertFalse(sections.hasAbout)
        XCTAssertTrue(sections.sortedRatings.isEmpty)
    }

    func testDifferentSeriesSummaryAndScoresRemainAccessible() {
        let episodeScore = ExternalRating(source: .imdb, value: 9.1, scale: .outOfTen)
        let sections = DetailInformationSections(
            item: item(), horizontalInset: 22,
            overviewAlreadyShown: "A different episode synopsis.",
            ratingsAlreadyShown: [episodeScore]
        )
        XCTAssertTrue(sections.hasAbout)
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testPartialOrHiddenHeaderRatingsDoNotDiscardOtherScores() {
        let partial = DetailInformationSections(
            item: item(), horizontalInset: 22, ratingsAlreadyShown: [imdb]
        )
        XCTAssertEqual(partial.sortedRatings, [audience])
        let hidden = DetailInformationSections(
            item: item(), horizontalInset: 22,
            spoilerSettings: SpoilerSettings(hideRatingsUntilWatched: true),
            ratingsAlreadyShown: []
        )
        XCTAssertEqual(hidden.sortedRatings, [audience, imdb])
    }

    func testMissingDescriptionsDoNotCreateAnAboutSection() {
        for overview in [nil, "", " \n "] as [String?] {
            let sections = DetailInformationSections(
                item: item(overview: overview), horizontalInset: 22,
                overviewAlreadyShown: nil
            )
            XCTAssertFalse(sections.hasAbout)
        }
    }
}
#endif
