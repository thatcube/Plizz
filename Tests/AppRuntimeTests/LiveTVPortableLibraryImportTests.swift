#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVPortableLibraryImportTests: XCTestCase {
    func testImmutableInputsStayPinnedDuringConcurrentRetentionUntilDefinitionCommit() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertEqual(try definitions.load(), [definition])
        let saved = try await snapshots.snapshot(id: snapshot.id, profileID: definition.profileID)
        XCTAssertEqual(saved, snapshot)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 1)
        XCTAssertEqual(counts.inserts, 0)
        XCTAssertEqual(counts.releases, 1)
    }

    func testFailedDefinitionCommitReleasesStagedSnapshotLease() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(failsSave: true)
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertEqual(bridge.statuses[definition.profileID], .unavailable)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
        try await snapshots.retain(ids: [], profileID: definition.profileID)
        let removed = try await snapshots.snapshot(id: snapshot.id, profileID: definition.profileID)
        XCTAssertNil(removed)
    }

    func testDisableTakesEffectWhileNewImmutableInputsAreStillMissing() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        try await snapshots.insert(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        var incoming = definition
        incoming.isEnabled = false
        incoming.revisions.append(.init(
            snapshotID: UUID(), recipe: definition.revisions[0].recipe, epochSeconds: 1_700_000_060
        ))
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        await bridge.apply([key: try LiveTVPortableRecord(library: incoming).encoded()])
        let current = try XCTUnwrap(definitions.load().first)
        XCTAssertFalse(current.isEnabled)
        XCTAssertEqual(current.revisions, definition.revisions)
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingSchedules(1))
    }

    func testPublishedRevisionMutationStaysPendingWithoutRewritingOrAcknowledging() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        try await snapshots.insert(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        var recipe = definition.revisions[0].recipe
        recipe.seed += 1
        var changed = definition
        changed.revisions = [.init(
            id: definition.revisions[0].id, snapshotID: snapshot.id, recipe: recipe,
            epochSeconds: definition.revisions[0].epochSeconds
        )]
        await bridge.apply(try records(snapshot: snapshot, definition: changed))
        XCTAssertEqual(try definitions.load(), [definition])
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryReview)
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(try definitions.load(), [definition])
        XCTAssertEqual(try fixture.pending().libraryDefinitions, [changed])
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
    }

    func testStaleRemoteDefinitionPreservesFutureRevisionAndItsLocalSnapshot() async throws {
        let fixture = try fixture()
        let (old, remote) = try library(profileID: fixture.profiles.activeProfileID)
        let (future, _) = try library(profileID: remote.profileID)
        let schedule = try LibraryChannelSchedule(definition: remote, snapshots: [old.id: old])
        let boundary = try schedule.slot(at: Date().addingTimeInterval(3_600)).endSeconds
        var local = remote
        local.revisions.append(.init(
            snapshotID: future.id, recipe: remote.revisions[0].recipe, epochSeconds: boundary
        ))
        local.publishedThrough = boundary
        let definitions = PortableImportDefinitions(values: [local])
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(old, profileID: remote.profileID)
        try await snapshots.seed(future, profileID: remote.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: old, definition: remote))
        XCTAssertEqual(try definitions.load(), [local])
        let retained = try await snapshots.snapshot(id: future.id, profileID: remote.profileID)
        XCTAssertEqual(retained, future)
        XCTAssertTrue(try fixture.pending().libraryDefinitions.isEmpty)
    }

    func testMissingExportSnapshotPreservesFallbackWhileChannelPreferencesStillCapture() async throws {
        let fixture = try fixture()
        let (_, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        try LiveTVPreferencesStore(
            defaults: fixture.defaults, namespace: fixture.profiles.activeNamespace
        ).save(.init(favoriteIDs: ["favorite"]))
        let first = await bridge.capture(fallback: [:])
        XCTAssertFalse(first.keys.contains { LiveTVPortableRecordKey.parse($0)?.kind == .library })
        XCTAssertTrue(first.keys.contains { LiveTVPortableRecordKey.parse($0)?.entityID == "favorite" })
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryInputs)
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        let previous = try LiveTVPortableRecord(library: definition).encoded()
        let next = await bridge.capture(fallback: [key: previous])
        XCTAssertEqual(next[key], previous)
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryInputs)
    }

    func testConcurrentLocalEditRemainsPendingAcrossLaterCapture() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        var paused = definition
        paused.isEnabled = false
        let snapshots = RetainingImportSnapshots(afterStage: { [paused] in
            try definitions.save([paused])
        })
        try await snapshots.seed(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertEqual(try definitions.load(), [paused])
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryReview)
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(try definitions.load(), [paused])
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 1)
    }

    func testConsentRevokedAndReenabledDuringStagingCannotCommitUnderNewConsent() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots(afterStage: {
            await MainActor.run {
                let consent = LiveTVPortableSyncPreferenceStore(
                    defaults: fixture.defaults, profileID: definition.profileID,
                    namespace: fixture.profiles.activeNamespace
                )
                consent.isEnabled = false
                consent.isEnabled = true
            }
        })
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertEqual(try fixture.pending().libraryDefinitions, [definition])
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testAccountChangeDuringStagingReleasesInputsWithoutCommitting() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots(afterStage: {
            await MainActor.run {
                LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
            }
        })
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertTrue(try fixture.pending().libraryDefinitions.isEmpty)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testDeletedDefinitionRevokesAuthorityWithoutItsOldSnapshot() async throws {
        let fixture = try fixture()
        let (_, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        await bridge.apply([key: try LiveTVPortableRecord(isDeleted: true).encoded()])
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertTrue(try fixture.pending().deletedLibraryIDs.isEmpty)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 0)
    }

    private func records(
        snapshot: LibraryChannelSnapshot, definition: LibraryChannelDefinition
    ) throws -> SyncLocalChanges {
        var changes: SyncLocalChanges = [:]
        let definitionKey = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        changes[definitionKey] = try LiveTVPortableRecord(library: definition).encoded()
        for part in try LiveTVPortableSnapshots.partition(snapshot) {
            let key = LiveTVPortableRecordKey(
                profileID: definition.profileID, kind: .snapshot, entityID: part.entityID
            ).recordName
            changes[key] = try LiveTVPortableRecord(snapshot: part).encoded()
        }
        return changes
    }

    private func library(profileID: String) throws -> (LibraryChannelSnapshot, LibraryChannelDefinition) {
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let item = try LibraryChannelItem(
            item: MediaItem(id: "movie", title: "Programme", kind: .movie, runtime: 60),
            library: library, serverID: "server", userID: "user"
        )
        let snapshot = try LibraryChannelSnapshot(
            items: [item], createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Channel", libraries: [library]), epochSeconds: 1_700_000_000)
        ], publishedThrough: 1_700_000_060)
        return (snapshot, definition)
    }

    private func fixture() throws -> PortableLibraryImportFixture {
        let suite = "LiveTVPortableLibraryImportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        LiveTVPortableSyncPreferenceStore(
            defaults: defaults, profileID: profiles.activeProfileID, namespace: profiles.activeNamespace
        ).isEnabled = true
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-library-import-tests/" + UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return PortableLibraryImportFixture(profiles: profiles, defaults: defaults, directory: directory)
    }
}

@MainActor
private struct PortableLibraryImportFixture {
    let profiles: ProfilesModel
    let defaults: UserDefaults
    let directory: URL
    func pending() throws -> LiveTVPortableImport {
        try LiveTVPortableSyncAdapter(
            directory: directory, profileID: profiles.activeProfileID, defaults: defaults,
            namespace: profiles.activeNamespace
        ).pending(sourceStore: PortableImportSources())
    }
    func bridge(
        definitions: any LibraryChannelDefinitionStoring, snapshots: any LibraryChannelSnapshotStoring
    ) -> LiveTVPortableSyncBridge {
        LiveTVPortableSyncBridge(
            profiles: profiles, directory: directory, defaults: defaults,
            sourceStore: { _ in PortableImportSources() }, definitions: { _ in definitions }, snapshots: snapshots
        )
    }
}

private struct PortableImportSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private final class PortableImportDefinitions: LibraryChannelDefinitionCompareAndSwapping, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var values: [LibraryChannelDefinition]
    private let failsSave: Bool
    init(values: [LibraryChannelDefinition] = [], failsSave: Bool = false) {
        self.values = values
        self.failsSave = failsSave
    }
    func load() throws -> [LibraryChannelDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
    func save(_ definitions: [LibraryChannelDefinition]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failsSave else { throw LibraryChannelError.storageFailed }
        values = definitions
    }
    func save(_ definitions: [LibraryChannelDefinition], ifUnchangedFrom expected: [LibraryChannelDefinition]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard values == expected else { throw LibraryChannelError.publicationConflict }
        try save(definitions)
    }
}

private actor RetainingImportSnapshots: LibraryChannelSnapshotStaging {
    private let store = LibraryChannelSnapshotStore(databaseURL: nil)
    private var stageCount = 0
    private var insertCount = 0
    private var releaseCount = 0
    private let afterStage: (@Sendable () async throws -> Void)?
    init(afterStage: (@Sendable () async throws -> Void)? = nil) { self.afterStage = afterStage }
    func seed(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws {
        try await store.insert(snapshot, profileID: profileID)
    }
    func counts() -> (stages: Int, inserts: Int, releases: Int) { (stageCount, insertCount, releaseCount) }
    func snapshot(id: UUID, profileID: String) async throws -> LibraryChannelSnapshot? {
        try await store.snapshot(id: id, profileID: profileID)
    }
    func insert(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws {
        insertCount += 1
        try await store.insert(snapshot, profileID: profileID)
        try await store.retain(ids: [], profileID: profileID)
    }
    func stage(_ snapshots: [LibraryChannelSnapshot], profileID: String) async throws -> LibraryChannelSnapshotLease {
        stageCount += 1
        let lease = try await store.stage(snapshots, profileID: profileID)
        do {
            try await store.retain(ids: [], profileID: profileID)
            try await afterStage?()
            return lease
        } catch {
            await store.release(lease)
            throw error
        }
    }
    func release(_ lease: LibraryChannelSnapshotLease) async {
        releaseCount += 1
        await store.release(lease)
    }
    func retain(ids: Set<UUID>, profileID: String) async throws {
        try await store.retain(ids: ids, profileID: profileID)
    }
    func retainReferenced(by definitions: any LibraryChannelDefinitionStoring, profileID: String) async throws {
        try await store.retainReferenced(by: definitions, profileID: profileID)
    }
}
#endif
