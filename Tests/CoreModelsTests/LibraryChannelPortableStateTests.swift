import CoreModels
import Foundation
import XCTest

final class LibraryChannelPortableStateTests: XCTestCase {
    private let epoch: Int64 = 1_700_000_000
    private let library = LibraryChannelLibrary(accountID: "jellyfin|server|user", libraryID: "library")

    private func snapshot(_ itemID: String) throws -> LibraryChannelSnapshot {
        let item = try LibraryChannelItem(
            item: MediaItem(id: itemID, title: itemID, kind: .movie, runtime: 100),
            library: library, serverID: "server", userID: "user"
        )
        return try LibraryChannelSnapshot(items: [item], createdAt: Date(timeIntervalSince1970: Double(epoch)))
    }

    private func definition(_ snapshot: LibraryChannelSnapshot, horizon: Int64? = nil) -> LibraryChannelDefinition {
        LibraryChannelDefinition(profileID: "profile", revisions: [
            LibraryChannelRevision(
                snapshotID: snapshot.id, recipe: LibraryChannelRecipe(name: "Movies", libraries: [library]),
                epochSeconds: epoch
            )
        ], publishedThrough: horizon ?? epoch)
    }

    private func merge(
        _ local: [LibraryChannelDefinition], _ remote: [LibraryChannelDefinition],
        deleted: Set<UUID> = [], snapshots: [LibraryChannelSnapshot]
    ) throws -> [LibraryChannelDefinition] {
        try LibraryChannelImportMerger.merge(
            profileID: "profile", current: local, incoming: remote, deletedIDs: deleted,
            snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) }),
            at: Date(timeIntervalSince1970: Double(epoch + 10))
        )
    }

    func testCompletePortableStateRoundTripsTheSameProgrammeIdentityAndOffset() throws {
        let snapshot = try snapshot("movie")
        let channel = definition(snapshot)
        let state = try LibraryChannelPortableState(definitions: [channel], snapshots: [snapshot])
        let decoded = try JSONDecoder().decode(LibraryChannelPortableState.self, from: JSONEncoder().encode(state))
        try decoded.validate()
        let imported = try merge([], decoded.definitions, snapshots: decoded.snapshots)
        let originalSchedule = try LibraryChannelSchedule(definition: channel, snapshots: [snapshot.id: snapshot])
        let importedSchedule = try LibraryChannelSchedule(definition: imported[0], snapshots: [snapshot.id: snapshot])
        let time = Date(timeIntervalSince1970: Double(epoch + 432_123))
        XCTAssertEqual(try originalSchedule.slot(at: time), try importedSchedule.slot(at: time))
    }

    func testRecipeWithoutItsExactSnapshotCannotExportOrImport() throws {
        let snapshot = try snapshot("movie")
        let channel = definition(snapshot)
        XCTAssertThrowsError(try LibraryChannelPortableState(definitions: [channel], snapshots: []))
        XCTAssertThrowsError(try merge([], [channel], snapshots: [])) {
            XCTAssertEqual($0 as? LibraryChannelError, .snapshotUnavailable)
        }
    }

    func testStructuredIdentifiersCannotCarryCredentialURLsIntoPortableSnapshots() throws {
        for accountID in ["https://server.invalid?token=private", "account?token=private", "account\nprivate"] {
            let unsafe = LibraryChannelLibrary(accountID: accountID, libraryID: "library")
            XCTAssertThrowsError(try LibraryChannelRecipe(name: "TV", libraries: [unsafe]).validate())
            XCTAssertThrowsError(try LibraryChannelItem(
                item: MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 100),
                library: unsafe, serverID: "server", userID: "user"
            ))
        }
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 100)
        item.versions = [MediaVersion(
            id: "source", sourceMetadata: MediaSourceMetadata(sourceRevision: "https://server.invalid?token=private")
        )]
        XCTAssertThrowsError(try LibraryChannelItem(item: item, library: library, serverID: "server", userID: "user"))
    }

    func testFutureRevisionMergesWithoutRerollingPublishedGuide() throws {
        let old = try snapshot("old")
        let future = try snapshot("future")
        let local = definition(old, horizon: epoch + 200)
        var remote = local
        remote.revisions.append(LibraryChannelRevision(
            snapshotID: future.id, recipe: local.revisions[0].recipe, epochSeconds: epoch + 300
        ))
        let imported = try merge([local], [remote], snapshots: [old, future])
        let schedule = try LibraryChannelSchedule(
            definition: imported[0], snapshots: [old.id: old, future.id: future]
        )
        XCTAssertEqual(try schedule.slot(at: Date(timeIntervalSince1970: Double(epoch + 299))).item.itemID, "old")
        XCTAssertEqual(try schedule.slot(at: Date(timeIntervalSince1970: Double(epoch + 300))).item.itemID, "future")
    }

    func testRemoteEditInsideLocallyPublishedHorizonRemainsAConflict() throws {
        let old = try snapshot("old")
        let future = try snapshot("future")
        let local = definition(old, horizon: epoch + 500)
        var remote = local
        remote.revisions.append(LibraryChannelRevision(
            snapshotID: future.id, recipe: local.revisions[0].recipe, epochSeconds: epoch + 100
        ))
        XCTAssertThrowsError(try merge([local], [remote], snapshots: [old, future])) {
            XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict)
        }
    }

    func testSameRevisionIDCannotChangeItsRecipeOrEpoch() throws {
        let snapshot = try snapshot("movie")
        let local = definition(snapshot)
        var recipe = local.revisions[0].recipe
        recipe.seed += 1
        var remote = local
        remote.revisions = [LibraryChannelRevision(
            id: local.revisions[0].id, snapshotID: snapshot.id, recipe: recipe, epochSeconds: epoch
        )]
        XCTAssertThrowsError(try merge([local], [remote], snapshots: [snapshot])) {
            XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict)
        }
    }

    func testRemoteSourceIdentityCannotReuseAnApprovedLocalChannel() throws {
        let snapshot = try snapshot("movie")
        let local = definition(snapshot)
        let remote = LibraryChannelDefinition(
            id: local.id, sourceID: UUID(), profileID: local.profileID, revisions: local.revisions
        )
        XCTAssertThrowsError(try merge([local], [remote], snapshots: [snapshot])) {
            XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict)
        }
    }

    func testExplicitDeletionRemovesChannelButAbsenceDoesNot() throws {
        let snapshot = try snapshot("movie")
        let local = definition(snapshot)
        XCTAssertEqual(try merge([local], [], snapshots: [snapshot]), [local])
        XCTAssertTrue(try merge([local], [], deleted: [local.id], snapshots: []).isEmpty)
        XCTAssertThrowsError(try merge([local], [local], deleted: [local.id], snapshots: [snapshot]))
    }

    func testWrongProfileCannotImportEvenIntoAnEmptyDevice() throws {
        let snapshot = try snapshot("movie")
        let local = definition(snapshot)
        let remote = LibraryChannelDefinition(
            id: local.id, sourceID: local.sourceID, profileID: "another-profile", revisions: local.revisions
        )
        XCTAssertThrowsError(try merge([], [remote], snapshots: [snapshot])) {
            XCTAssertEqual($0 as? LibraryChannelError, .authorizationChanged)
        }
    }

    func testStaleRemoteRecordCannotDropALocallyPublishedFutureRevision() throws {
        let old = try snapshot("old")
        let future = try snapshot("future")
        let remote = definition(old)
        var local = remote
        local.revisions.append(LibraryChannelRevision(
            snapshotID: future.id, recipe: remote.revisions[0].recipe, epochSeconds: epoch + 300
        ))
        XCTAssertEqual(try merge([local], [remote], snapshots: [old, future])[0].revisions, local.revisions)
    }
}
