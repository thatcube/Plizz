import CoreModels
import Foundation
import XCTest

final class LibraryChannelScheduleTests: XCTestCase {
    private let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
    private let epoch: Int64 = 1_700_000_000

    private func item(_ id: String, duration: Double = 60, series: String? = nil, episode: Int? = nil) throws -> LibraryChannelItem {
        var item = MediaItem(id: id, title: id, kind: series == nil ? .movie : .episode, runtime: duration)
        item.seriesID = series
        item.seasonNumber = 1
        item.episodeNumber = episode
        return try LibraryChannelItem(item: item, library: library, serverID: "server", userID: "user")
    }

    private func schedule(_ items: [LibraryChannelItem], order: LibraryChannelOrdering = .roundRobin, seed: UInt64 = 1) throws -> LibraryChannelSchedule {
        let snapshot = try LibraryChannelSnapshot(items: items, createdAt: Date(timeIntervalSince1970: Double(epoch)))
        let recipe = LibraryChannelRecipe(name: "Channel", libraries: [library], ordering: order, seed: seed)
        return try LibraryChannelSchedule(
            definition: LibraryChannelDefinition(profileID: "profile", revisions: [
                LibraryChannelRevision(snapshotID: snapshot.id, recipe: recipe, epochSeconds: epoch)
            ]),
            snapshots: [snapshot.id: snapshot]
        )
    }

    func testRoundRobinPreservesEpisodeOrderAndCyclesContinuously() throws {
        let schedule = try schedule([
            item("a2", series: "a", episode: 2), item("b2", series: "b", episode: 2),
            item("a1", series: "a", episode: 1), item("b1", series: "b", episode: 1)
        ])
        let slots = try schedule.slots(
            from: Date(timeIntervalSince1970: Double(epoch)),
            to: Date(timeIntervalSince1970: Double(epoch + 300))
        )
        XCTAssertEqual(slots.count, 5)
        XCTAssertNotEqual(slots[0].item.seriesID, slots[1].item.seriesID)
        XCTAssertEqual(slots[0].item.episode, 1)
        XCTAssertEqual(slots[2].item.episode, 2)
        XCTAssertEqual(slots[0].item, slots[4].item)
        XCTAssertEqual(slots[4].startSeconds, epoch + 240)
    }

    func testSameSnapshotRecipeEpochClockIndependentOfInputOrderAndTimeZone() throws {
        let items = try (0..<20).map { try item("item-\($0)", duration: Double(30 + $0)) }
        let first = try schedule(items, order: .seededShuffle, seed: UInt64.max)
        var recipe = first.definition.revisions[0].recipe
        recipe.timeZoneID = "America/New_York"
        let snapshot = try LibraryChannelSnapshot(items: Array(items.reversed()), createdAt: Date())
        let second = try LibraryChannelSchedule(definition: LibraryChannelDefinition(profileID: "profile", revisions: [
            LibraryChannelRevision(snapshotID: snapshot.id, recipe: recipe, epochSeconds: epoch)
        ]), snapshots: [snapshot.id: snapshot])
        for delta in [0, 30, 3_600, 86_400, 315_360_000] {
            let date = Date(timeIntervalSince1970: Double(epoch) + Double(delta))
            XCTAssertEqual(try first.slot(at: date).item, try second.slot(at: date).item)
            XCTAssertEqual(try first.slot(at: date).startSeconds, try second.slot(at: date).startSeconds)
        }
    }

    func testBoundaryAndJoinOffsetUseIntegerUTCNotResume() throws {
        let schedule = try schedule([item("a", duration: 60.9), item("b", duration: 120.9)])
        let first = try schedule.slot(at: Date(timeIntervalSince1970: Double(epoch) + 59.5))
        XCTAssertEqual(first.offset(at: Date(timeIntervalSince1970: Double(epoch) + 59.5)), 59.5)
        XCTAssertEqual(first.endSeconds, epoch + 60)
        let second = try schedule.slot(at: first.end)
        XCTAssertNotEqual(first.item.id, second.item.id)
        XCTAssertEqual(second.offset(at: first.end), 0)
    }

    func testPortableShuffleHasAPinnedSeedOrdering() throws {
        let first = try schedule([item("a"), item("b")], order: .seededShuffle, seed: 1)
        let second = try schedule([item("a"), item("b")], order: .seededShuffle, seed: 2)
        let date = Date(timeIntervalSince1970: Double(epoch))
        XCTAssertEqual(try first.slot(at: date).item.itemID, "a")
        XCTAssertEqual(try second.slot(at: date).item.itemID, "b")
    }

    func testRevisionCannotTruncateAnAlreadyScheduledProgramme() throws {
        let original = try schedule([item("old")])
        let oldID = original.definition.revisions[0].snapshotID
        let oldSnapshot = try LibraryChannelSnapshot(id: oldID, items: [item("old")], createdAt: Date())
        let next = try LibraryChannelSnapshot(items: [item("new")], createdAt: Date())
        var definition = original.definition
        definition.revisions.append(LibraryChannelRevision(
            snapshotID: next.id, recipe: definition.revisions[0].recipe, epochSeconds: epoch + 10
        ))
        XCTAssertThrowsError(try LibraryChannelSchedule(
            definition: definition, snapshots: [oldID: oldSnapshot, next.id: next]
        )) { XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict) }
    }

    func testFutureRevisionCannotChangePreviouslyPublishedSlots() throws {
        let original = try schedule([item("old")])
        let newSnapshot = try LibraryChannelSnapshot(items: [item("new")], createdAt: Date())
        let oldItem = try original.slot(at: Date(timeIntervalSince1970: Double(epoch))).item
        let oldSnapshotID = original.definition.revisions[0].snapshotID
        let oldSnapshot = try LibraryChannelSnapshot(
            id: oldSnapshotID, items: [oldItem], createdAt: Date()
        )
        var definition = original.definition
        definition.revisions.append(LibraryChannelRevision(
            snapshotID: newSnapshot.id, recipe: definition.revisions[0].recipe, epochSeconds: epoch + 120
        ))
        let revised = try LibraryChannelSchedule(
            definition: definition, snapshots: [oldSnapshot.id: oldSnapshot, newSnapshot.id: newSnapshot]
        )
        XCTAssertEqual(try revised.slot(at: Date(timeIntervalSince1970: Double(epoch + 119))).item.itemID, "old")
        XCTAssertEqual(try revised.slot(at: Date(timeIntervalSince1970: Double(epoch + 120))).item.itemID, "new")
    }

    func testInvalidDurationsNeverReceiveInventedSlots() throws {
        for duration in [0, -1, Double.nan, .infinity, 604_801] {
            XCTAssertThrowsError(try item("bad", duration: duration))
        }
        XCTAssertThrowsError(try LibraryChannelSnapshot(items: [], createdAt: Date()))
    }

    func testDecodedExtremeEpochsFailValidationWithoutIntegerOverflow() throws {
        for epoch in [Int64.min, Int64.max, -253_402_300_799, 253_402_300_799] {
            let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
                LibraryChannelRevision(
                    snapshotID: UUID(), recipe: LibraryChannelRecipe(name: "TV", libraries: [library]),
                    epochSeconds: epoch
                )
            ])
            let decoded = try JSONDecoder().decode(
                LibraryChannelDefinition.self, from: JSONEncoder().encode(definition)
            )
            XCTAssertThrowsError(try decoded.validate()) {
                XCTAssertEqual($0 as? LibraryChannelError, .invalidRecipe)
            }
        }
    }

    func testRulesMatchShowsAndRespectRatingAndGenre() {
        var episode = MediaItem(id: "e", title: "Pilot", kind: .episode, runtime: 60)
        episode.parentTitle = "My Show"
        episode.genres = ["Comedy"]
        episode.officialRating = "TV-PG"
        var recipe = LibraryChannelRecipe(
            name: "Comedy", libraries: [library], includeTitles: ["my show"],
            genres: ["comedy"], allowedRatings: ["TV-PG"], includeUnrated: false
        )
        XCTAssertTrue(recipe.includes(episode))
        recipe.excludeTitles = ["My Show"]
        XCTAssertFalse(recipe.includes(episode))
        recipe.excludeTitles = []
        episode.officialRating = nil
        XCTAssertFalse(recipe.includes(episode))
    }
}

final class LibraryChannelWatchCoverageTests: XCTestCase {
    func testJoiningNearEndDoesNotCountInitialSeek() {
        var coverage = LibraryChannelWatchCoverage(duration: 1_000)
        for second in 0...100 { coverage.sample(position: Double(900 + second), instant: Double(second), isPlaying: true) }
        XCTAssertEqual(coverage.secondsWatched, 100, accuracy: 0.01)
        XCTAssertFalse(coverage.isComplete)
    }

    func testPauseSkipStallAndRepeatedSegmentsCannotInflateCompletion() {
        var coverage = LibraryChannelWatchCoverage(duration: 100)
        for second in 0...20 { coverage.sample(position: Double(second), instant: Double(second), isPlaying: true) }
        coverage.sample(position: 20, instant: 30, isPlaying: false)
        coverage.sample(position: 90, instant: 31, isPlaying: true)
        coverage.sample(position: 90, instant: 32, isPlaying: true)
        coverage.sample(position: 91, instant: 33, isPlaying: true)
        coverage.discontinuity()
        for second in 0...20 { coverage.sample(position: Double(second), instant: Double(40 + second), isPlaying: true) }
        XCTAssertEqual(coverage.secondsWatched, 21, accuracy: 0.01)
        XCTAssertFalse(coverage.isComplete)
    }

    func testCompletionRequiresNinetyPercentUniqueCoverage() {
        var coverage = LibraryChannelWatchCoverage(duration: 100)
        for second in 0...89 { coverage.sample(position: Double(second), instant: Double(second), isPlaying: true) }
        XCTAssertFalse(coverage.isComplete)
        coverage.sample(position: 90, instant: 90, isPlaying: true)
        XCTAssertTrue(coverage.isComplete)
    }
}
