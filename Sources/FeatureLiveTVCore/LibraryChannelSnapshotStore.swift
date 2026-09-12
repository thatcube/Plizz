#if DEBUG
import CoreModels
import Foundation
import SQLite3

public protocol LibraryChannelSnapshotStoring: Sendable {
    func snapshot(id: UUID, profileID: String) async throws -> LibraryChannelSnapshot?
    func insert(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws
    func retain(ids: Set<UUID>, profileID: String) async throws
}

public struct LibraryChannelSnapshotLease: Sendable {
    fileprivate let id: UUID
    fileprivate let key: String
}

public protocol LibraryChannelSnapshotStaging: LibraryChannelSnapshotStoring {
    func stage(_ snapshots: [LibraryChannelSnapshot], profileID: String) async throws -> LibraryChannelSnapshotLease
    func release(_ lease: LibraryChannelSnapshotLease) async
    func retainReferenced(
        by store: any LibraryChannelDefinitionStoring, profileID: String
    ) async throws
}

/// One actor-confined connection, indexed by profile and immutable snapshot ID.
/// Recipes are elsewhere; cache eviction cannot silently invent a new schedule.
public actor LibraryChannelSnapshotStore: LibraryChannelSnapshotStaging {
    private let connection: LibrarySnapshotConnection
    private let cacheID: String

    public init(databaseURL: URL? = LibraryChannelSnapshotStore.defaultURL) {
        connection = LibrarySnapshotConnection(url: databaseURL)
        cacheID = databaseURL?.standardizedFileURL.path ?? UUID().uuidString
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.plozz.liveTV", isDirectory: true)
            .appendingPathComponent("library-snapshots.sqlite")
    }

    public func snapshot(id: UUID, profileID: String) throws -> LibraryChannelSnapshot? {
        try connection.open()
        return try connection.statement(
            "SELECT payload FROM snapshots WHERE profile=? AND id=?", values: [profileID, id.uuidString]
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { throw LibraryChannelError.storageFailed }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count <= 64_000_000 else { throw LibraryChannelError.invalidSnapshot }
            let snapshot = try JSONDecoder().decode(
                LibraryChannelSnapshot.self, from: Data(bytes: bytes, count: count)
            )
            guard snapshot.id == id else { throw LibraryChannelError.invalidSnapshot }
            try snapshot.validate()
            return snapshot
        }
    }

    public func insert(_ snapshot: LibraryChannelSnapshot, profileID: String) throws {
        try snapshot.validate()
        try connection.open()
        if let existing = try self.snapshot(id: snapshot.id, profileID: profileID) {
            guard existing == snapshot else { throw LibraryChannelError.publicationConflict }
            return
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 64_000_000 else { throw LibraryChannelError.catalogTooLarge }
        try connection.statement("SELECT COALESCE(SUM(length(payload)),0),COUNT(*) FROM snapshots", values: []) {
            guard sqlite3_step($0) == SQLITE_ROW else { throw LibraryChannelError.storageFailed }
            guard sqlite3_column_int64($0, 0) + Int64(data.count) <= 512_000_000,
                  sqlite3_column_int64($0, 1) < 3_200 else { throw LibraryChannelError.catalogTooLarge }
        }
        try connection.statement("""
            INSERT INTO snapshots(profile,id,payload)
            SELECT ?1,?2,?3
            WHERE (SELECT COALESCE(SUM(length(payload)),0) FROM snapshots) + length(?3) <= 512000000
              AND (SELECT COUNT(*) FROM snapshots) < 3200
            """, values: [
            profileID, snapshot.id.uuidString
        ]) { statement in
            try data.withUnsafeBytes { bytes in
                guard sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count),
                                        LibrarySnapshotConnection.transient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw LibraryChannelError.storageFailed }
                guard connection.changedRowCount == 1 else { throw LibraryChannelError.catalogTooLarge }
            }
        }
    }

    public func stage(
        _ snapshots: [LibraryChannelSnapshot], profileID: String
    ) throws -> LibraryChannelSnapshotLease {
        guard snapshots.count <= 3_200, Set(snapshots.map(\.id)).count == snapshots.count else {
            throw LibraryChannelError.invalidSnapshot
        }
        var count = 0
        for snapshot in snapshots {
            try snapshot.validate()
            count += snapshot.items.count
            guard count <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
        }
        let lease = try LibrarySnapshotPins.shared.pin(
            ids: Set(snapshots.map(\.id)), key: pinKey(profileID)
        )
        do {
            for snapshot in snapshots { try insert(snapshot, profileID: profileID) }
            return lease
        } catch {
            LibrarySnapshotPins.shared.release(lease)
            throw error
        }
    }

    public func release(_ lease: LibraryChannelSnapshotLease) {
        LibrarySnapshotPins.shared.release(lease)
    }

    public func retainReferenced(
        by store: any LibraryChannelDefinitionStoring, profileID: String
    ) throws {
        if let store = store as? LibraryChannelDefinitionStore {
            try store.withLockedDefinitions { definitions in
                try retain(ids: Set(definitions.flatMap(\.revisions).map(\.snapshotID)), profileID: profileID)
            }
        } else {
            let definitions = try store.load()
            try retain(ids: Set(definitions.flatMap(\.revisions).map(\.snapshotID)), profileID: profileID)
        }
    }

    public func retain(ids: Set<UUID>, profileID: String) throws {
        try LibrarySnapshotPins.shared.withPinnedIDs(key: pinKey(profileID)) { pinned in
            try removeUnreferenced(ids: ids.union(pinned), profileID: profileID)
        }
    }

    private func pinKey(_ profileID: String) -> String { "\(cacheID.utf8.count):\(cacheID):\(profileID)" }

    private func removeUnreferenced(ids: Set<UUID>, profileID: String) throws {
        try connection.open()
        var stored: [String] = []
        try connection.statement("SELECT id FROM snapshots WHERE profile=?", values: [profileID]) { statement in
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let value = sqlite3_column_text(statement, 0) else { throw LibraryChannelError.storageFailed }
                stored.append(String(cString: value))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw LibraryChannelError.storageFailed }
        }
        let retained = Set(ids.map(\.uuidString))
        for id in stored where !retained.contains(id) {
            try connection.statement("DELETE FROM snapshots WHERE profile=? AND id=?", values: [profileID, id]) {
                guard sqlite3_step($0) == SQLITE_DONE else { throw LibraryChannelError.storageFailed }
            }
        }
    }
}

private final class LibrarySnapshotConnection {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let url: URL?
    private var handle: OpaquePointer?

    init(url: URL?) { self.url = url }
    deinit { if let handle { sqlite3_close(handle) } }
    var changedRowCount: Int { Int(sqlite3_changes(handle)) }

    func open() throws {
        guard handle == nil else { return }
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            url?.path ?? ":memory:", &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw LibraryChannelError.storageFailed
        }
        sqlite3_busy_timeout(opened, 5_000)
        guard sqlite3_exec(opened, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS snapshots(
                profile TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(profile,id)
            );
            """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            throw LibraryChannelError.storageFailed
        }
        handle = opened
    }

    func statement<T>(_ sql: String, values: [String], body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryChannelError.storageFailed
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient) == SQLITE_OK else {
                throw LibraryChannelError.storageFailed
            }
        }
        return try body(statement)
    }
}

private final class LibrarySnapshotPins: @unchecked Sendable {
    static let shared = LibrarySnapshotPins()
    private let lock = NSLock()
    private var leases: [String: [UUID: Set<UUID>]] = [:]

    func pin(ids: Set<UUID>, key: String) throws -> LibraryChannelSnapshotLease {
        lock.lock()
        defer { lock.unlock() }
        guard leases.values.reduce(0, { $0 + $1.count }) < 256 else {
            throw LibraryChannelError.storageFailed
        }
        let lease = LibraryChannelSnapshotLease(id: UUID(), key: key)
        leases[key, default: [:]][lease.id] = ids
        return lease
    }

    func release(_ lease: LibraryChannelSnapshotLease) {
        lock.lock()
        defer { lock.unlock() }
        leases[lease.key]?[lease.id] = nil
        if leases[lease.key]?.isEmpty == true { leases[lease.key] = nil }
    }

    func withPinnedIDs<T>(key: String, body: (Set<UUID>) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(Set(leases[key]?.values.flatMap { $0 } ?? []))
    }
}
#endif
