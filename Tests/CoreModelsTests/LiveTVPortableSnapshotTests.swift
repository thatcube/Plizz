import Foundation
import XCTest
@testable import CoreModels

final class LiveTVPortableSnapshotTests: XCTestCase {
    func testPartitionedImmutableInputsProduceSameScheduleAndOffset() throws {
        let snapshot = try makeSnapshot(count: 800)
        let parts = try LiveTVPortableSnapshots.partition(snapshot)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            let record = LiveTVPortableRecord(snapshot: part)
            let key = LiveTVPortableRecordKey(profileID: "profile", kind: .snapshot, entityID: part.entityID)
            let data = try record.encoded()
            XCTAssertLessThanOrEqual(data.count, LiveTVPortableRecord.maximumBytes)
            XCTAssertEqual(try LiveTVPortableRecord.decode(data, key: key), record)
        }
        let received = try LiveTVPortableSnapshots.assemble(parts.reversed())
        XCTAssertEqual(received, snapshot)
        let recipe = LibraryChannelRecipe(
            name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")],
            ordering: .seededShuffle, seed: 54321
        )
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: recipe, epochSeconds: 1_700_000_000)
        ], publishedThrough: 1_700_086_400)
        let originalSchedule = try LibraryChannelSchedule(definition: definition, snapshots: [snapshot.id: snapshot])
        let receivedSchedule = try LibraryChannelSchedule(definition: definition, snapshots: [received.id: received])
        for seconds in [1_700_000_001.5, 1_700_003_605.25, 1_800_000_000.0] {
            let now = Date(timeIntervalSince1970: seconds)
            let original = try originalSchedule.slot(at: now)
            let remote = try receivedSchedule.slot(at: now)
            XCTAssertEqual(remote.item, original.item)
            XCTAssertEqual(remote.startSeconds, original.startSeconds)
            XCTAssertEqual(remote.offset(at: now), original.offset(at: now))
        }
    }

    func testMissingDuplicateAndMixedRevisionPartsNeverPublishSnapshot() throws {
        let first = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 800))
        let other = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 800))
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble(Array(first.dropLast())))
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble([first[0], first[0]]))
        var mixed = first
        mixed[mixed.count - 1] = other.last!
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble(mixed))
    }

    func testSameSnapshotIDWithChangedInputsFailsDigestCheck() throws {
        let parts = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 300))
        let data = try JSONEncoder().encode(parts[0])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(value["items"] as? [[String: Any]])
        items[0]["durationSeconds"] = 999
        value["items"] = items
        let changed = try JSONDecoder().decode(
            LiveTVPortableSnapshotPart.self, from: JSONSerialization.data(withJSONObject: value)
        )
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble([changed] + parts.dropFirst()))
    }

    func testLibraryDefinitionCannotCrossProfileAndRejectsExtremeEpochWithoutTrapping() throws {
        let snapshot = try makeSnapshot(count: 1)
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(
                name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")]
            ), epochSeconds: Int64.min)
        ])
        let record = LiveTVPortableRecord(library: definition)
        XCTAssertThrowsError(try record.validate(key: .init(
            profileID: "profile", kind: .library, entityID: definition.id.uuidString
        )))
        XCTAssertThrowsError(try record.validate(key: .init(
            profileID: "another", kind: .library, entityID: definition.id.uuidString
        )))
    }

    private func makeSnapshot(count: Int) throws -> LibraryChannelSnapshot {
        let items = try (0..<count).map { index in
            try LibraryChannelItem(
                item: MediaItem(id: "item-\(index)", title: "Programme \(index)", kind: .movie, runtime: Double(60 + index)),
                library: .init(accountID: "account", libraryID: "library"), serverID: "server", userID: "user"
            )
        }
        return try LibraryChannelSnapshot(items: items, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
