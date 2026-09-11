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
}

private final class LibraryChannelSecureFixture: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}
