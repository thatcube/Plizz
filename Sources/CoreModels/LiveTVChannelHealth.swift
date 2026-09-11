import CryptoKit
import Foundation

/// These values describe reachability, not decoder or entitlement support.
public enum LiveTVChannelHealthStatus: String, Codable, Equatable, Sendable {
    case reachable
    case unavailable
    case uncertain
}

public enum LiveTVChannelHealthReason: String, Codable, Equatable, Sendable {
    case mediaObserved
    case repeatedlyMissing
    case authorizationRequired
    case restricted
    case timedOut
    case networkUnavailable
    case rateLimited
    case serverFailure
    case staleManifest
    case expiredSegment
    case encryptedMedia
    case unsupportedMedia
    case invalidManifest
    case unsafeOrigin
    case responseLimit
    case requestLimit
}

/// Every identity component is hashed, including legacy channel IDs which may
/// have been derived from a credential-bearing address. No locator is retained.
public struct LiveTVChannelHealthIdentity: Codable, Hashable, Sendable {
    public let profile: String
    public let source: String
    public let channel: String
    public let stream: String

    public init(profileID: String, sourceID: String, channelID: String, streamIdentity: String) {
        profile = Self.digest([profileID])
        source = Self.digest([sourceID])
        channel = Self.digest([channelID])
        stream = Self.digest([streamIdentity])
    }

    public static func digest(_ components: [String]) -> String {
        var hash = SHA256()
        for component in components {
            // Length-prefixing prevents ambiguous concatenations.
            hash.update(data: Data("\(component.utf8.count):".utf8))
            hash.update(data: Data(component.utf8))
        }
        let alphabet = Array("0123456789abcdef".utf8)
        let bytes = hash.finalize().flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
        return String(decoding: bytes, as: UTF8.self)
    }

    var isValid: Bool {
        [profile, source, channel, stream].allSatisfy {
            $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

public struct LiveTVChannelHealthRecord: Codable, Equatable, Sendable {
    public let identity: LiveTVChannelHealthIdentity
    public let status: LiveTVChannelHealthStatus
    public let reason: LiveTVChannelHealthReason
    public let checkedAt: Date
    public let isScanHidden: Bool

    public init(
        identity: LiveTVChannelHealthIdentity,
        status: LiveTVChannelHealthStatus,
        reason: LiveTVChannelHealthReason,
        checkedAt: Date,
        isScanHidden: Bool
    ) {
        self.identity = identity
        self.status = status
        self.reason = reason
        self.checkedAt = checkedAt
        self.isScanHidden = isScanHidden && status == .unavailable && reason == .repeatedlyMissing
    }

    public func restored() -> Self {
        Self(identity: identity, status: status, reason: reason, checkedAt: checkedAt, isScanHidden: false)
    }
}

public protocol LiveTVChannelHealthStoring: Sendable {
    func load() throws -> [LiveTVChannelHealthRecord]
    func save(_ records: [LiveTVChannelHealthRecord]) throws
}

public enum LiveTVChannelHealthStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
    case encodingFailed
}

/// Separate from favorites, mappings and manual hides. Corruption is surfaced,
/// never silently replaced with an empty value.
public final class LiveTVChannelHealthStore: LiveTVChannelHealthStoring, @unchecked Sendable {
    static let baseKey = "com.plozz.liveTV.channelHealth"
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
    }

    public func load() throws -> [LiveTVChannelHealthRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ records: [LiveTVChannelHealthRecord]) throws {
        guard Self.valid(records) else { throw LiveTVChannelHealthStoreError.invalidStoredValue }
        let data: Data
        do { data = try JSONEncoder().encode(records) }
        catch { throw LiveTVChannelHealthStoreError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        _ = try loadLocked()
        defaults.set(data, forKey: key)
    }

    private func loadLocked() throws -> [LiveTVChannelHealthRecord] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data,
              let records = try? JSONDecoder().decode([LiveTVChannelHealthRecord].self, from: data),
              Self.valid(records) else { throw LiveTVChannelHealthStoreError.invalidStoredValue }
        return records
    }

    private static func valid(_ records: [LiveTVChannelHealthRecord]) -> Bool {
        records.count <= 100_000 &&
            Set(records.map(\.identity)).count == records.count &&
            records.allSatisfy {
                $0.identity.isValid && $0.checkedAt.timeIntervalSince1970.isFinite &&
                    (!$0.isScanHidden || ($0.status == .unavailable && $0.reason == .repeatedlyMissing))
            }
    }
}
