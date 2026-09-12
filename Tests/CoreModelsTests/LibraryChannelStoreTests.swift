import CoreModels
import Foundation
import XCTest

final class LibraryChannelStoreTests: XCTestCase {
    private func definition() -> LibraryChannelDefinition {
        LibraryChannelDefinition(profileID: "profile", revisions: [
            LibraryChannelRevision(
                snapshotID: UUID(),
                recipe: LibraryChannelRecipe(name: "TV", libraries: [
                    LibraryChannelLibrary(accountID: "account", libraryID: "library")
                ]),
                epochSeconds: 1_700_000_000
            )
        ])
    }

    func testCompareAndSwapRejectsAnotherInstancesCompletedEdit() throws {
        let secure = LibraryChannelSecureFixture()
        let first = LibraryChannelDefinitionStore(secureStore: secure, namespace: "profile")
        let second = LibraryChannelDefinitionStore(secureStore: secure, namespace: "profile")
        let original = definition()
        try first.save([original])
        let expected = try second.load()
        var edited = original
        edited.isEnabled = false
        try first.save([edited], ifUnchangedFrom: [original])
        XCTAssertThrowsError(try second.save([], ifUnchangedFrom: expected)) {
            XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict)
        }
        XCTAssertEqual(try first.load(), [edited])
    }

    func testCompareAndSwapCanCreateAndDeleteAnExactKnownVersion() throws {
        let store = LibraryChannelDefinitionStore(secureStore: LibraryChannelSecureFixture(), namespace: "profile")
        let channel = definition()
        try store.save([channel], ifUnchangedFrom: [])
        XCTAssertEqual(try store.load(), [channel])
        try store.save([], ifUnchangedFrom: [channel])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testAuthoritativeReferenceReadUsesAReentrantStoreLock() throws {
        let store = LibraryChannelDefinitionStore(secureStore: LibraryChannelSecureFixture(), namespace: "profile")
        let channel = definition()
        try store.save([channel])
        try store.withLockedDefinitions { current in
            XCTAssertEqual(current, [channel])
            XCTAssertEqual(try store.load(), current)
        }
    }

    func testLegacyDefinitionDecodesAsCustomAndRoundTripsUnchanged() throws {
        let custom = definition()
        let data = try JSONEncoder().encode(custom)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("automaticKey"))
        let decoded = try JSONDecoder().decode(LibraryChannelDefinition.self, from: data)
        XCTAssertNil(decoded.automaticKey)
        XCTAssertFalse(decoded.isAutomatic)
        XCTAssertEqual(decoded, custom)
        try decoded.validate()
    }

    func testAutomaticIdentityIsProfileScopedStableAndStorePreservesOrigin() throws {
        let key = "v1/genre/comedy"
        let automatic = LibraryChannelDefinition(
            id: LibraryChannelAutomaticIdentity.channelID(profileID: "profile", key: key),
            sourceID: LibraryChannelAutomaticIdentity.sourceID(profileID: "profile", key: key),
            profileID: "profile", revisions: definition().revisions, automaticKey: key
        )
        XCTAssertTrue(automatic.isAutomatic)
        XCTAssertNotEqual(automatic.id, automatic.sourceID)
        XCTAssertNotEqual(automatic.id, LibraryChannelAutomaticIdentity.channelID(profileID: "other", key: key))
        XCTAssertEqual(automatic.id, LibraryChannelAutomaticIdentity.channelID(profileID: "profile", key: key))
        XCTAssertNotEqual(
            LibraryChannelAutomaticIdentity.seed(profileID: "profile", key: key),
            LibraryChannelAutomaticIdentity.seed(profileID: "other", key: key)
        )
        let store = LibraryChannelDefinitionStore(secureStore: LibraryChannelSecureFixture())
        try store.save([automatic])
        XCTAssertEqual(try store.load(), [automatic])
        let stripped = LibraryChannelDefinition(
            id: automatic.id, sourceID: automatic.sourceID, profileID: automatic.profileID,
            revisions: automatic.revisions
        )
        XCTAssertThrowsError(try store.save([stripped])) {
            XCTAssertEqual($0 as? LibraryChannelError, .publicationConflict)
        }
        XCTAssertEqual(try store.load(), [automatic])
    }

    func testAutomaticOriginCannotBeSpoofedWithCustomIDsOrAnotherProfile() throws {
        let custom = definition()
        XCTAssertThrowsError(try LibraryChannelDefinition(
            id: custom.id, sourceID: custom.sourceID, profileID: custom.profileID,
            revisions: custom.revisions, automaticKey: "v1/movies"
        ).validate())
        for key in ["", "movies", "v1/", "v1/movies\n", "v1/" + String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try LibraryChannelDefinition(
                id: LibraryChannelAutomaticIdentity.channelID(profileID: "profile", key: key),
                sourceID: LibraryChannelAutomaticIdentity.sourceID(profileID: "profile", key: key),
                profileID: "profile", revisions: custom.revisions, automaticKey: key
            ).validate())
        }
        XCTAssertThrowsError(try LibraryChannelDefinition(
            id: LibraryChannelAutomaticIdentity.channelID(profileID: "another", key: "v1/movies"),
            sourceID: LibraryChannelAutomaticIdentity.sourceID(profileID: "another", key: "v1/movies"),
            profileID: "profile", revisions: custom.revisions, automaticKey: "v1/movies"
        ).validate())
    }
}

private final class LibraryChannelSecureFixture: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}
