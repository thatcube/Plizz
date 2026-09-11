#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSourceManagementTests: XCTestCase {
    func testImportedSourceEditsPreserveOpaqueIdentityAndRejectStaleChanges() throws {
        let id = UUID()
        let locator = try XCTUnwrap(URL(string: "plozz-playlist://" + id.uuidString.lowercased()))
        let original = LiveTVPlaylistSource(id: id.uuidString, name: "Imported", playlistURL: locator)
        let store = SourceManagementTestStore()
        let model = LiveTVSourceManagementModel(store: store, canMutate: { true })
        model.reload()
        try model.saveImportedPlaylist(original)
        var updated = original
        updated.name = "Renamed import"
        updated.guideURLs = [try XCTUnwrap(URL(string: "https://example.test/guide.xml"))]
        try model.saveImportedPlaylist(updated, replacing: original)
        XCTAssertEqual(store.snapshot.playlists, [updated])
        XCTAssertEqual(updated.importedPlaylistID, id)
        XCTAssertThrowsError(try model.saveImportedPlaylist(original, replacing: original))
        model.authorizeMutations { false }
        XCTAssertThrowsError(try model.saveImportedPlaylist(original, replacing: updated))
        XCTAssertEqual(store.snapshot.playlists, [updated])
    }

    func testEmptyStorageDoesNotEnablePublicFeeds() {
        let store = SourceManagementTestStore()
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.configuration, .empty)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testUnreadableStorageCannotBeOverwrittenByPlaylistSetup() {
        let original = LiveTVSourcesConfiguration(playlists: [source("existing")])
        let store = SourceManagementTestStore(original)
        store.setReadFailure(true)
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        XCTAssertThrowsError(try model.savePlaylist(input: input("new")))
        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(model.loadIssue, .load)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testAddRebasesOnLatestConfiguration() throws {
        let first = source("first")
        let second = source("second")
        let store = SourceManagementTestStore(.init(playlists: [first]))
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        try store.save(.init(playlists: [first, second]))
        try model.savePlaylist(input: input("third"))
        XCTAssertEqual(model.configuration.playlists.map(\.name), ["first", "second", "third"])
        XCTAssertEqual(model.configuration, store.snapshot)
    }

    func testEditPreservesIdentityAndDisabledState() throws {
        let original = source("first", enabled: false)
        let store = SourceManagementTestStore(.init(playlists: [original]))
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        try model.savePlaylist(input: input("renamed"), replacing: original)
        let updated = try XCTUnwrap(model.configuration.playlists.first)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, "renamed")
        XCTAssertFalse(updated.isEnabled)
    }

    func testStaleEditDoesNotOverwriteNewerSource() throws {
        let original = source("first")
        let store = SourceManagementTestStore(.init(playlists: [original]))
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        var latest = original
        latest.name = "Edited in another scene"
        try store.save(.init(playlists: [latest]))
        XCTAssertThrowsError(try model.savePlaylist(input: input("stale"), replacing: original))
        XCTAssertEqual(store.snapshot.playlists, [latest])
        XCTAssertEqual(store.writeCount, 1)
    }

    func testFailedSaveDoesNotPublishOrApplyConfiguration() {
        let original = LiveTVSourcesConfiguration(playlists: [source("first")])
        let store = SourceManagementTestStore(original)
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        store.setWriteFailure(true)
        model.setPlaylistEnabled("first", enabled: false)
        XCTAssertEqual(model.configuration, original)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(model.mutationRevision, 0)
        XCTAssertEqual(model.mutationIssue, .save)
    }

    func testRemovingFinalSourceReturnsToEmptyConfiguration() {
        let store = SourceManagementTestStore(.init(playlists: [source("first")]))
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        model.removePlaylist("first")
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.configuration, .empty)
        XCTAssertEqual(store.snapshot, .empty)
        XCTAssertEqual(model.mutationRevision, 1)
    }

    func testReloadPreservesPreviouslyAddedTestSourcesWithoutWriting() {
        let custom = source("custom")
        let legacy = source("free-us", enabled: false)
        let original = LiveTVSourcesConfiguration(playlists: [custom, legacy])
        let store = SourceManagementTestStore(original)
        let model = LiveTVSourceManagementModel(store: store)
        model.reload()
        XCTAssertEqual(model.configuration, original)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testRevokedSourceManagementCannotPersistChanges() {
        let store = SourceManagementTestStore()
        var allowed = true
        let model = LiveTVSourceManagementModel(store: store, canMutate: { allowed })
        model.reload()
        allowed = false
        model.setPlaylistEnabled("missing", enabled: true)
        XCTAssertEqual(model.mutationIssue, .accessDenied)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(model.configuration, .empty)
    }

    private func source(_ name: String, enabled: Bool = true) -> LiveTVPlaylistSource {
        LiveTVPlaylistSource(
            id: name, name: name, playlistURL: URL(string: "https://example.invalid/\(name).m3u")!,
            isEnabled: enabled
        )
    }

    private func input(_ name: String) -> LiveTVPlaylistEditorModel.ValidatedInput {
        .init(name: name, playlistURL: URL(string: "https://example.invalid/\(name).m3u")!, guideURLs: [])
    }
}

private extension LiveTVSourceManagementModel {
    convenience init(store: any LiveTVSourcesStoring) {
        self.init(store: store, canMutate: { true })
    }
}

private final class SourceManagementTestStore: LiveTVSourcesStoring, @unchecked Sendable {
    enum Failure: Error { case unavailable }
    private let lock = NSLock()
    private var value: LiveTVSourcesConfiguration
    private var writes = 0
    private var readFailure = false
    private var writeFailure = false

    init(_ value: LiveTVSourcesConfiguration = .empty) { self.value = value }
    var writeCount: Int { lock.withLock { writes } }
    var snapshot: LiveTVSourcesConfiguration { lock.withLock { value } }
    func setReadFailure(_ failure: Bool) { lock.withLock { readFailure = failure } }
    func setWriteFailure(_ failure: Bool) { lock.withLock { writeFailure = failure } }

    func load() throws -> LiveTVSourcesConfiguration {
        try lock.withLock {
            if readFailure { throw Failure.unavailable }
            return value
        }
    }

    func save(_ configuration: LiveTVSourcesConfiguration) throws {
        try configuration.validate()
        try lock.withLock {
            if writeFailure { throw Failure.unavailable }
            value = configuration
            writes += 1
        }
    }
}
#endif
