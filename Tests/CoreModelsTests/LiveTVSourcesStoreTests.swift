import Foundation
import XCTest
@testable import CoreModels

final class LiveTVSourcesStoreTests: XCTestCase {
    func testLegacyGuideURLsDecodeIntoStableSourceIDsAndRoundTrip() throws {
        let data = Data("""
        {
            "id":"legacy", "name":"Existing", "playlistURL":"https://example.test/list.m3u",
            "guideURLs":["https://example.test/primary.xml","https://example.test/fallback.xml"]
        }
        """.utf8)
        let source = try JSONDecoder().decode(LiveTVPlaylistSource.self, from: data)
        XCTAssertEqual(source.guideSourceIDs, ["legacy.guide.0", "legacy.guide.1"])
        XCTAssertTrue(source.discoversPlaylistGuides)
        XCTAssertEqual(source.guideLookbackDays, 1)
        XCTAssertEqual(source.guideLookaheadDays, 7)
        XCTAssertNoThrow(try source.validate())
        let roundTrip = try JSONDecoder().decode(LiveTVPlaylistSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(roundTrip, source)
    }

    func testImportedFileReferencesAreOpaqueAndCannotBeUsedAsRemoteAddresses() throws {
        let id = UUID()
        let locator = "plozz-playlist://" + id.uuidString.lowercased()
        let source = LiveTVPlaylistSource(
            id: id.uuidString, name: "Imported", playlistURL: try XCTUnwrap(URL(string: locator))
        )
        XCTAssertNoThrow(try source.validate())
        XCTAssertEqual(source.importedPlaylistID, id)
        XCTAssertNil(LiveTVPlaylistSource.sourceURL(from: locator))
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure, namespace: "import-profile")
        try store.save(.init(playlists: [source]))
        XCTAssertEqual(try store.load().playlists, [source])
        for address in [locator + "/file.m3u", locator + "?token=secret", "file:///provider/list.m3u"] {
            let invalid = LiveTVPlaylistSource(
                id: id.uuidString, name: "Invalid", playlistURL: try XCTUnwrap(URL(string: address))
            )
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testManagedServersRoundTripOnlyNonsecretAccountReferencesWithPlaylists() throws {
        let secure = LiveTVSecureStoreDouble()
        let configuration = LiveTVSourcesConfiguration(
            playlists: [source()],
            servers: [LiveTVServerSource(id: "server-source", name: "Home TV", accountID: "account-one", isEnabled: false)]
        )
        let store = LiveTVSourcesStore(secureStore: secure, namespace: "profile-one")
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try LiveTVSourcesStore(secureStore: secure).load(), .empty)
        let raw = try XCTUnwrap(secure.values[SettingsKey.scoped(
            LiveTVSourcesStore.baseKey, namespace: "profile-one"
        )])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(document["servers"] as? [[String: Any]])
        XCTAssertEqual(Set(servers[0].keys), ["id", "name", "accountID", "isEnabled"])
        XCTAssertEqual(servers[0]["accountID"] as? String, "account-one")
    }

    func testExistingPlaylistDocumentDecodesWithNoImplicitServerSources() throws {
        let old = #"{"version":1,"playlists":[]}"#
        let decoded = try JSONDecoder().decode(LiveTVSourcesConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(decoded, .empty)
        XCTAssertTrue(decoded.servers.isEmpty)
        let legacyServer = """
            {"playlists":[],"servers":[{"id":"server","name":"TV","accountID":"account"}]}
            """
        let server = try JSONDecoder().decode(
            LiveTVSourcesConfiguration.self, from: Data(legacyServer.utf8)
        )
        XCTAssertTrue(server.servers[0].isEnabled)
    }

    func testSourcesMustHaveUniqueIDsAcrossPlaylistsAndServersAndValidAccountReferences() {
        let playlist = source()
        let duplicate = LiveTVServerSource(id: playlist.id, name: "Server", accountID: "account")
        XCTAssertThrowsError(try LiveTVSourcesConfiguration(playlists: [playlist], servers: [duplicate]).validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .duplicateSourceID)
        }
        let missingAccount = LiveTVServerSource(name: "Server", accountID: " \n ")
        XCTAssertThrowsError(try LiveTVSourcesConfiguration(servers: [missingAccount]).validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .invalidAccountReference)
        }
    }

    func testServerRenameKeepsSourceIdentityAndAccountReference() throws {
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure)
        let server = LiveTVServerSource(id: "stable-server", name: "Original", accountID: "account")
        try store.save(LiveTVSourcesConfiguration(servers: [server]))
        var configuration = try store.load()
        configuration.servers[0].name = "Renamed"
        try store.save(configuration)
        let loaded = try store.load()
        XCTAssertEqual(loaded.servers[0].id, server.id)
        XCTAssertEqual(loaded.servers[0].accountID, server.accountID)
        XCTAssertEqual(loaded.servers[0].name, "Renamed")
    }

    func testSharedAddressParserTrimsInputPreservesQueriesAndRejectsUserInfo() {
        let address = "https://example.test/list.m3u?username=sample&password=sample-only"
        XCTAssertEqual(
            LiveTVPlaylistSource.sourceURL(from: " \n\(address)\t")?.absoluteString,
            address
        )
        XCTAssertNotNil(LiveTVPlaylistSource.sourceURL(from: "http://example.test/guide.xml.gz"))
        for invalid in [
            "", " ", "/relative.m3u", "ftp://example.test/list.m3u",
            "https://user:sample-only@example.test/list.m3u"
        ] {
            XCTAssertNil(LiveTVPlaylistSource.sourceURL(from: invalid))
        }
    }

    func testMissingSecureValueIsEmptyWithoutSeedingOrWriting() throws {
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure)

        XCTAssertEqual(try store.load(), .empty)
        XCTAssertEqual(secure.readKeys, [LiveTVSourcesStore.baseKey])
        XCTAssertEqual(secure.nonthrowingReadCount, 0)
        XCTAssertEqual(secure.writeCount, 0)
        XCTAssertTrue(secure.values.isEmpty)
    }

    func testMultipleNamedSourcesAndCredentialQueriesRoundTripOnlyThroughSecureStorage() throws {
        let secure = LiveTVSecureStoreDouble()
        let configuration = LiveTVSourcesConfiguration(playlists: [
            source(id: "one"),
            LiveTVPlaylistSource(
                id: "two", name: "Second playlist", playlistURL: URL(string: "http://example.test/second.m3u")!,
                guideURLs: [], isEnabled: false
            )
        ])
        try LiveTVSourcesStore(secureStore: secure).save(configuration)

        XCTAssertEqual(try LiveTVSourcesStore(secureStore: secure).load(), configuration)
        XCTAssertEqual(secure.writeCount, 1)
        XCTAssertEqual(Set(secure.values.keys), [LiveTVSourcesStore.baseKey])
        XCTAssertEqual(secure.nonthrowingReadCount, 0)
        let stored = try XCTUnwrap(secure.values[LiveTVSourcesStore.baseKey])
        let decoded = try JSONDecoder().decode(LiveTVSourcesConfiguration.self, from: Data(stored.utf8))
        XCTAssertEqual(decoded.playlists[0].playlistURL.query, "username=sample&password=sample-only")
        XCTAssertEqual(decoded.playlists[0].guideURLs[0].query, "token=sample-only")
    }

    func testProfilesAreIsolatedAndDefaultNamespaceRemainsUnscoped() throws {
        let secure = LiveTVSecureStoreDouble()
        let primary = LiveTVSourcesStore(secureStore: secure)
        let secondary = LiveTVSourcesStore(secureStore: secure, namespace: "second-profile")
        let configuration = LiveTVSourcesConfiguration(playlists: [source()])
        try primary.save(configuration)
        XCTAssertEqual(try secondary.load(), .empty)
        try secondary.save(.empty)

        XCTAssertEqual(try primary.load(), configuration)
        XCTAssertEqual(try secondary.load(), .empty)
        XCTAssertNotNil(secure.values[LiveTVSourcesStore.baseKey])
        XCTAssertNotNil(secure.values[SettingsKey.scoped(LiveTVSourcesStore.baseKey, namespace: "second-profile")])
    }

    func testEditingEnablementAndRemovalPreserveIdentityAcrossReopening() throws {
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure)
        let original = source()
        try store.save(LiveTVSourcesConfiguration(playlists: [original]))
        var configuration = try store.load()
        configuration.playlists[0].name = "Renamed"
        configuration.playlists[0].isEnabled = false
        configuration.playlists[0].guideURLs = []
        try store.save(configuration)
        let reopened = try LiveTVSourcesStore(secureStore: secure).load()
        XCTAssertEqual(reopened.playlists[0].id, original.id)
        XCTAssertEqual(reopened, configuration)
        try store.save(.empty)
        XCTAssertEqual(try store.load(), .empty)
    }

    func testLegacyOptionalFieldsDecodeWithoutEnablingAnImplicitPreset() throws {
        let secure = LiveTVSecureStoreDouble()
        secure.values[LiveTVSourcesStore.baseKey] = """
            {"playlists":[{"id":"legacy","name":"Existing","playlistURL":"https://example.test/list.m3u"}]}
            """
        let loaded = try LiveTVSourcesStore(secureStore: secure).load()
        XCTAssertEqual(loaded.playlists.count, 1)
        XCTAssertEqual(loaded.playlists[0].id, "legacy")
        XCTAssertTrue(loaded.playlists[0].isEnabled)
        XCTAssertTrue(loaded.playlists[0].guideURLs.isEmpty)
        XCTAssertEqual(secure.writeCount, 0)
    }

    func testCorruptionIsReportedAndEvenDirectSaveCannotOverwriteIt() {
        for corrupted in ["", "not JSON", "{}", "{\"playlists\":null}", "{\"playlists\":\"bad\"}"] {
            let secure = LiveTVSecureStoreDouble()
            secure.values[LiveTVSourcesStore.baseKey] = corrupted
            let store = LiveTVSourcesStore(secureStore: secure)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? LiveTVSourcesStoreError, .invalidStoredValue)
            }
            XCTAssertThrowsError(try store.save(.empty)) {
                XCTAssertEqual($0 as? LiveTVSourcesStoreError, .invalidStoredValue)
            }
            XCTAssertEqual(secure.values[LiveTVSourcesStore.baseKey], corrupted)
            XCTAssertEqual(secure.writeCount, 0)
        }
    }

    func testNewerSchemaIsReportedAndCannotBeOverwritten() {
        let secure = LiveTVSecureStoreDouble()
        let newer = #"{"version":2,"playlists":[],"serverSources":[{"id":"future"}]}"#
        secure.values[LiveTVSourcesStore.baseKey] = newer
        let store = LiveTVSourcesStore(secureStore: secure)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try store.save(.empty)) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .unsupportedVersion)
        }
        XCTAssertEqual(secure.values[LiveTVSourcesStore.baseKey], newer)
        XCTAssertEqual(secure.writeCount, 0)
    }

    func testThrowingReadFailuresAreNotTreatedAsMissingAndProtectSavedState() throws {
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure)
        try store.save(LiveTVSourcesConfiguration(playlists: [source()]))
        let original = secure.values
        secure.failRead = true
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .loadFailed)
            XCTAssertFalse($0.localizedDescription.contains("sample-only"))
        }
        XCTAssertThrowsError(try store.save(.empty)) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .loadFailed)
        }
        XCTAssertEqual(secure.values, original)
        XCTAssertEqual(secure.writeCount, 1)
        XCTAssertEqual(secure.nonthrowingReadCount, 0)
    }

    func testSaveFailureIsDistinctSanitizedAndRetryable() throws {
        let secure = LiveTVSecureStoreDouble()
        let store = LiveTVSourcesStore(secureStore: secure)
        let configuration = LiveTVSourcesConfiguration(playlists: [source()])
        secure.failWrite = true
        XCTAssertThrowsError(try store.save(configuration)) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .saveFailed)
            XCTAssertFalse($0.localizedDescription.contains("sample-only"))
            XCTAssertFalse($0.localizedDescription.contains("example.test"))
        }
        XCTAssertEqual(try store.load(), .empty)
        secure.failWrite = false
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
    }

    func testInvalidAddressesAreRejectedBeforeAnyWriteAndNeverAppearInErrors() throws {
        for address in [
            "file:///playlist.m3u", "ftp://example.test/list.m3u", "/relative.m3u",
            "https://user:sample-only@example.test/list.m3u", "https://sample-only@example.test/list.m3u"
        ] {
            let secure = LiveTVSecureStoreDouble()
            let store = LiveTVSourcesStore(secureStore: secure)
            var playlist = source()
            playlist.playlistURL = try XCTUnwrap(URL(string: address))
            XCTAssertThrowsError(try store.save(LiveTVSourcesConfiguration(playlists: [playlist]))) {
                XCTAssertEqual($0 as? LiveTVSourcesValidationError, .invalidPlaylistURL)
                XCTAssertFalse($0.localizedDescription.contains(address))
                XCTAssertFalse($0.localizedDescription.contains("sample-only"))
            }
            XCTAssertEqual(secure.writeCount, 0)
        }
    }

    func testInvalidGuideAndDuplicateSourcesAreRejectedRatherThanSilentlyDropped() throws {
        var playlist = source()
        playlist.guideURLs = [URL(string: "https://user:sample-only@example.test/guide.xml.gz")!]
        XCTAssertThrowsError(try playlist.validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .invalidGuideURL)
        }
        playlist = source()
        playlist.guideURLs += playlist.guideURLs
        XCTAssertThrowsError(try playlist.validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .invalidGuideSources)
        }
        XCTAssertThrowsError(try LiveTVSourcesConfiguration(playlists: [source(), source()]).validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .duplicateSourceID)
        }
        playlist = source()
        playlist.name = " \n "
        XCTAssertThrowsError(try playlist.validate()) {
            XCTAssertEqual($0 as? LiveTVSourcesValidationError, .invalidName)
        }
    }

    func testSemanticallyInvalidSavedConfigurationIsProtectedAsCorruption() throws {
        let secure = LiveTVSecureStoreDouble()
        var invalid = source()
        invalid.playlistURL = URL(string: "file:///private-list.m3u")!
        let value = try JSONEncoder().encode(LiveTVSourcesConfiguration(playlists: [invalid]))
        secure.values[LiveTVSourcesStore.baseKey] = String(data: value, encoding: .utf8)
        let store = LiveTVSourcesStore(secureStore: secure)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? LiveTVSourcesStoreError, .invalidStoredValue)
        }
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(secure.writeCount, 0)
    }

    private func source(id: String = "stable-source") -> LiveTVPlaylistSource {
        LiveTVPlaylistSource(
            id: id, name: "My playlist",
            playlistURL: URL(string: "https://example.test/list.m3u?username=sample&password=sample-only")!,
            guideURLs: [URL(string: "https://example.test/guide.xml.gz?token=sample-only")!]
        )
    }
}

private final class LiveTVSecureStoreDouble: SecureStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var readKeys: [String] = []
    var nonthrowingReadCount = 0
    var writeCount = 0
    var failRead = false
    var failWrite = false

    func setString(_ value: String, for key: String) throws {
        if failWrite { throw failure }
        writeCount += 1
        values[key] = value
    }

    func readString(for key: String) throws -> String? {
        readKeys.append(key)
        if failRead { throw failure }
        return values[key]
    }

    func string(for key: String) -> String? {
        nonthrowingReadCount += 1
        return values[key]
    }

    func removeValue(for key: String) throws { values[key] = nil }

    private var failure: NSError {
        NSError(
            domain: "LiveTVSecureStoreDouble", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "https://example.test/?token=sample-only"]
        )
    }
}
