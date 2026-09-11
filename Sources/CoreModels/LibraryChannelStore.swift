import Foundation

public protocol LibraryChannelDefinitionStoring: Sendable {
    func load() throws -> [LibraryChannelDefinition]
    func save(_ definitions: [LibraryChannelDefinition]) throws
}

public protocol LibraryChannelDefinitionCompareAndSwapping: LibraryChannelDefinitionStoring {
    func save(_ definitions: [LibraryChannelDefinition], ifUnchangedFrom expected: [LibraryChannelDefinition]) throws
}

/// Small irreplaceable recipes and revision references survive tvOS cache
/// eviction. Large reconstructable catalogues belong in the SQLite cache.
public final class LibraryChannelDefinitionStore: LibraryChannelDefinitionCompareAndSwapping, @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let definitions: [LibraryChannelDefinition]
    }
    private let secureStore: any SecureStoring
    private let key: String
    private static let lock = NSRecursiveLock()

    public init(secureStore: any SecureStoring, namespace: String? = nil) {
        self.secureStore = secureStore
        key = SettingsKey.scoped("com.plozz.liveTV.libraryChannels", namespace: namespace)
    }

    public func load() throws -> [LibraryChannelDefinition] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try read()
    }

    public func save(_ definitions: [LibraryChannelDefinition]) throws {
        try persist(definitions, expected: nil)
    }

    public func save(
        _ definitions: [LibraryChannelDefinition], ifUnchangedFrom expected: [LibraryChannelDefinition]
    ) throws {
        try persist(definitions, expected: expected)
    }

    /// Snapshot retirement reads authoritative references under the same lock
    /// as cross-instance compare-and-swap, not an older view's cached references.
    public func withLockedDefinitions<T>(
        _ body: ([LibraryChannelDefinition]) throws -> T
    ) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body(read())
    }

    private func persist(_ definitions: [LibraryChannelDefinition], expected: [LibraryChannelDefinition]?) throws {
        guard definitions.count <= 100, Set(definitions.map(\.id)).count == definitions.count else {
            throw LibraryChannelError.invalidRecipe
        }
        for definition in definitions { try definition.validate() }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = try read()
        guard expected.map({ $0 == previous }) ?? true else { throw LibraryChannelError.publicationConflict }
        let data = try JSONEncoder().encode(Document(version: 1, definitions: definitions))
        guard data.count <= 2_000_000, let value = String(data: data, encoding: .utf8) else {
            throw LibraryChannelError.storageFailed
        }
        try secureStore.setString(value, for: key)
    }

    private func read() throws -> [LibraryChannelDefinition] {
        guard let value = try secureStore.readString(for: key) else { return [] }
        guard value.utf8.count <= 2_000_000 else { throw LibraryChannelError.storageFailed }
        let document = try JSONDecoder().decode(Document.self, from: Data(value.utf8))
        guard document.version == 1 else { throw LibraryChannelError.unsupportedVersion }
        guard document.definitions.count <= 100,
              Set(document.definitions.map(\.id)).count == document.definitions.count else {
            throw LibraryChannelError.invalidRecipe
        }
        for definition in document.definitions { try definition.validate() }
        return document.definitions
    }
}
