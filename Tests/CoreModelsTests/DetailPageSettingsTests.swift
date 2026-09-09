import XCTest
@testable import CoreModels

final class DetailPageSettingsTests: XCTestCase {
    private let audience = ExternalRating(source: .rottenTomatoesAudience, value: 89, scale: .percent)
    private let critics = ExternalRating(source: .rottenTomatoes, value: 96, scale: .percent)
    private let imdb = ExternalRating(source: .imdb, value: 8.6, scale: .outOfTen)
    private let tmdb = ExternalRating(source: .tmdb, value: 8.3, scale: .outOfTen)
    private let anilist = ExternalRating(source: .anilist, value: 90, scale: .percent)

    func testDefaultPrefersAudienceAndCriticsRatherThanServerOrder() {
        XCTAssertEqual(DetailPageSettings.default.headerRatings(
            from: [tmdb, imdb, critics, audience], isAnime: false, hidesRatings: false
        ), [audience, critics])
    }

    func testMissingSourcesFallThroughAndSparseTitlesStaySparse() {
        for (available, expected) in [
            ([imdb, tmdb], [imdb, tmdb]),
            ([tmdb, critics], [critics, tmdb]),
            ([imdb], [imdb]),
            ([], [])
        ] {
            XCTAssertEqual(DetailPageSettings.default.headerRatings(
                from: available, isAnime: false, hidesRatings: false
            ), expected)
        }
    }

    func testPreferencesAndAnimeApplicabilityControlSelection() {
        let settings = DetailPageSettings(
            ratingSourceOrder: [.anilist, .tmdb, .imdb],
            enabledRatingSources: [.anilist, .imdb, .tmdb]
        )
        let available = [audience, critics, imdb, tmdb, anilist]
        XCTAssertEqual(settings.headerRatings(from: available, isAnime: true, hidesRatings: false), [anilist, tmdb])
        XCTAssertEqual(settings.headerRatings(from: available, isAnime: false, hidesRatings: false), [tmdb, imdb])
    }

    func testHiddenOrDisabledRatingsNeverFillTheHeader() {
        let available = [audience, critics, imdb, tmdb]
        XCTAssertTrue(DetailPageSettings.default.headerRatings(
            from: available, isAnime: false, hidesRatings: true
        ).isEmpty)
        XCTAssertTrue(DetailPageSettings(showsHeaderRatings: false).headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ).isEmpty)
        XCTAssertTrue(DetailPageSettings(enabledRatingSources: []).headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ).isEmpty)
    }

    func testDuplicateSourcesCannotTakeBothSlots() {
        let settings = DetailPageSettings(ratingSourceOrder: [.imdb, .imdb, .tmdb])
        XCTAssertEqual(settings.headerRatings(
            from: [imdb, imdb, tmdb], isAnime: false, hidesRatings: false
        ), [imdb, tmdb])
        XCTAssertEqual(Set(settings.orderedSources), Set(RatingSource.allCases))
        XCTAssertEqual(settings.orderedSources.count, RatingSource.allCases.count)
    }

    func testSettingsPersistPerProfileAndTransferWithoutChangingOtherProfiles() throws {
        let suite = "DetailPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DetailPageSettingsStore(defaults: defaults, namespace: "first")
        let second = DetailPageSettingsStore(defaults: defaults, namespace: "second")
        let selected = DetailPageSettings(
            showsHeaderRatings: false,
            ratingSourceOrder: [.imdb, .community] + DetailPageSettings.defaultRatingOrder.filter {
                $0 != .imdb && $0 != .community
            },
            enabledRatingSources: [.imdb, .community]
        )
        first.save(selected)
        XCTAssertEqual(first.load(), selected)
        XCTAssertEqual(second.load(), .default)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        XCTAssertNotNil(snapshot[DetailPageSettingsStore.baseKey])
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), selected)
        ProfileSettingsTransfer.removeOne(
            baseKey: DetailPageSettingsStore.baseKey, namespace: "second", defaults: defaults
        )
        XCTAssertEqual(second.load(), .default)
        XCTAssertEqual(first.load(), selected)
    }

    func testEmptySavedSelectionSurvivesReload() throws {
        let suite = "DetailPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DetailPageSettingsStore(defaults: defaults)
        store.save(DetailPageSettings(enabledRatingSources: []))
        XCTAssertTrue(store.load().enabledRatingSources.isEmpty)
    }

}
