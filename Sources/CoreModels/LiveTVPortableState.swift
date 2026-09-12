import CryptoKit
import Foundation

public struct LiveTVPortableSyncPreferenceStore: Sendable {
    private static let epochKey = "com.plozz.liveTV.portableSync.accountEpoch"
    private let defaults: UserDefaults
    private let key: String
    private let profileID: String

    public init(defaults: UserDefaults = .standard, profileID: String) {
        self.init(
            defaults: defaults, profileID: profileID,
            namespace: profileID == ProfileStore.defaultProfileID ? nil : profileID
        )
    }

    public init(defaults: UserDefaults = .standard, profileID: String, namespace: String?) {
        self.defaults = defaults
        self.profileID = profileID
        key = SettingsKey.scoped(
            "com.plozz.liveTV.portableSync.enabled",
            namespace: namespace
        )
    }

    /// Device-local consent. Never add this key to ProfileSettingsTransfer.
    public var isEnabled: Bool {
        get {
            let epoch = Self.storageEpoch(defaults: defaults)
            return epoch != "invalid" && defaults.bool(forKey: key)
                && defaults.string(forKey: key + ".consentEpoch") == epoch
                && defaults.string(forKey: key + ".consentProfileID") == profileID
        }
        nonmutating set {
            let epoch = Self.storageEpoch(defaults: defaults)
            if newValue, epoch != "invalid" {
                if !isEnabled || consentRevision == nil {
                    defaults.set(UUID().uuidString, forKey: key + ".consentRevision")
                }
                defaults.set(epoch, forKey: key + ".consentEpoch")
                defaults.set(profileID, forKey: key + ".consentProfileID")
            }
            defaults.set(newValue && epoch != "invalid", forKey: key)
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
        }
    }

    /// Local replay fence, not portable consent or a parental authorization.
    public var consentRevision: String? {
        guard isEnabled, let value = defaults.string(forKey: key + ".consentRevision") else { return nil }
        return UUID(uuidString: value)?.uuidString
    }

    public static func storageEpoch(defaults: UserDefaults = .standard) -> String {
        guard let stored = defaults.string(forKey: epochKey) else { return "initial" }
        return UUID(uuidString: stored)?.uuidString ?? "invalid"
    }

    /// Invalidates consent for every profile, including one not yet present in a
    /// hydrating roster. New-account captures cannot open the previous journal.
    public static func accountDidChange(defaults: UserDefaults = .standard) {
        defaults.set(UUID().uuidString, forKey: epochKey)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
    }
}

public extension Notification.Name {
    static let plozzLiveTVPortableStateDidChange = Notification.Name(
        "com.plozz.liveTV.portableStateDidChange"
    )
}

public enum LiveTVPortableStateError: Error, Equatable, Sendable {
    case invalidRecord, unsupportedVersion, tooLarge, wrongProfile, incompleteSnapshot
}

public struct LiveTVPortableRecordKey: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case channel, source, library, snapshot, serverEnrollment }
    public let profileID: String
    public let kind: Kind
    public let entityID: String

    public init(profileID: String, kind: Kind, entityID: String) {
        self.profileID = profileID
        self.kind = kind
        self.entityID = entityID
    }

    public var recordName: String {
        "liveTV:\(Self.encoded(profileID)):\(kind.rawValue):\(Self.encoded(entityID))"
    }

    public static func parse(_ name: String) -> Self? {
        guard name.utf8.count <= 2_048 else { return nil }
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "liveTV",
              let profile = decoded(String(parts[1])), !profile.isEmpty,
              let kind = Kind(rawValue: String(parts[2])),
              let entity = decoded(String(parts[3])), !entity.isEmpty else { return nil }
        let key = Self(profileID: profile, kind: kind, entityID: entity)
        return key.recordName == name ? key : nil
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decoded(_ value: String) -> String? {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64 + padding) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// No recents, stream addresses, presentation/focus state or inferred authority.
public struct LiveTVPortableChannel: Codable, Equatable, Sendable {
    public var isFavorite: Bool
    public var hiddenName: String?
    public var favoriteName: String?
    public var favoritePosition: Int?
    public var metadata: LiveTVChannelMetadataOverride?
    public var guideMapping: LiveTVPortableGuideMapping?
    public var identityHint: LiveTVPortableChannelIdentityHint?

    public init(
        isFavorite: Bool = false, hiddenName: String? = nil, favoriteName: String? = nil,
        favoritePosition: Int? = nil, metadata: LiveTVChannelMetadataOverride? = nil,
        guideMapping: LiveTVPortableGuideMapping? = nil,
        identityHint: LiveTVPortableChannelIdentityHint? = nil
    ) {
        self.isFavorite = isFavorite
        self.hiddenName = hiddenName
        self.favoriteName = favoriteName
        self.favoritePosition = favoritePosition
        self.metadata = metadata
        self.guideMapping = guideMapping
        self.identityHint = identityHint
    }
}

/// Only a unique, non-URL provider station identifier can connect independently
/// imported playlist IDs. Locator HMACs and their keys are deliberately excluded.
public struct LiveTVPortableChannelIdentityHint: Codable, Equatable, Sendable {
    public let sourceID: String
    public let nativeID: String

    public init(sourceID: String, nativeID: String) {
        self.sourceID = sourceID
        self.nativeID = nativeID
    }

    public var isSafe: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:+"))
        return [sourceID, nativeID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512 && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

public struct LiveTVPortableGuideMapping: Codable, Equatable, Sendable {
    public let guideSourceID: String
    public let guideChannelID: String

    public init(guideSourceID: String, guideChannelID: String) {
        self.guideSourceID = guideSourceID
        self.guideChannelID = guideChannelID
    }

    /// Portable feed identity, not a device's configured/discovered guide ID.
    /// Exact addresses include credential changes; neither addresses nor local
    /// HMAC keys leave the device. Older unbound mappings remain pending.
    public static func boundSourceID(playlist: LiveTVPlaylistSource, guideURL: URL) -> String {
        "feed-v1-" + LiveTVChannelHealthIdentity.digest([
            "live-tv-portable-guide-v1", playlist.id, playlist.playlistURL.absoluteString,
            guideURL.absoluteString
        ])
    }

    public var hasBoundSourceIdentity: Bool {
        let prefix = "feed-v1-"
        guard guideSourceID.hasPrefix(prefix) else { return false }
        let digest = guideSourceID.dropFirst(prefix.count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Arbitrary XMLTV IDs may contain addresses. Only station-ID tokens cross
    /// the non-secret channel; unsupported mappings remain in the local cache.
    public var isSafe: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:@+"))
        return [guideSourceID, guideChannelID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512
                && !($0.contains(":") && $0.contains("@"))
                && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

/// A playlist descriptor cannot enroll a source on a different device. Addresses
/// may carry path/query credentials and remain in its profile-scoped secure store.
public struct LiveTVPortableSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case playlist, importedPlaylist, server }
    public var kind: Kind
    public var name: String
    public var isEnabled: Bool
    public var accountID: String?
    public var discoversPlaylistGuides: Bool?
    public var guideLookbackDays: Int?
    public var guideLookaheadDays: Int?

    public init(
        kind: Kind, name: String, isEnabled: Bool, accountID: String? = nil,
        discoversPlaylistGuides: Bool? = nil,
        guideLookbackDays: Int? = nil, guideLookaheadDays: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        self.accountID = accountID
        self.discoversPlaylistGuides = discoversPlaylistGuides == false ? false : nil
        self.guideLookbackDays = guideLookbackDays == 1 ? nil : guideLookbackDays
        self.guideLookaheadDays = guideLookaheadDays == 7 ? nil : guideLookaheadDays
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.name == rhs.name && lhs.isEnabled == rhs.isEnabled
            && lhs.accountID == rhs.accountID
            && (lhs.discoversPlaylistGuides ?? true) == (rhs.discoversPlaylistGuides ?? true)
            && (lhs.guideLookbackDays ?? 1) == (rhs.guideLookbackDays ?? 1)
            && (lhs.guideLookaheadDays ?? 7) == (rhs.guideLookaheadDays ?? 7)
    }
}

/// Full immutable revision inputs are partitioned, not regenerated from a recipe.
public struct LiveTVPortableSnapshotPart: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let part: Int
    public let partCount: Int
    public let contentDigest: String
    public let createdAt: Date
    public let ineligibleDurationCount: Int
    public let items: [LibraryChannelItem]

    public var entityID: String { "\(snapshotID.uuidString).\(part)" }
}

public struct LiveTVPortableRecord: Codable, Equatable, Sendable {
    public static let maximumBytes = 192 * 1_024
    public let version: Int
    public let isDeleted: Bool
    public let channel: LiveTVPortableChannel?
    public let source: LiveTVPortableSource?
    public let library: LibraryChannelDefinition?
    public let snapshot: LiveTVPortableSnapshotPart?
    public let serverEnrollmentSuppressed: Bool?

    public init(
        isDeleted: Bool = false, channel: LiveTVPortableChannel? = nil,
        source: LiveTVPortableSource? = nil, library: LibraryChannelDefinition? = nil,
        snapshot: LiveTVPortableSnapshotPart? = nil, serverEnrollmentSuppressed: Bool? = nil
    ) {
        version = 1
        self.isDeleted = isDeleted
        self.channel = channel
        self.source = source
        self.library = library
        self.snapshot = snapshot
        self.serverEnrollmentSuppressed = serverEnrollmentSuppressed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw LiveTVPortableStateError.tooLarge }
        return data
    }

    public static func decode(_ data: Data, key: LiveTVPortableRecordKey) throws -> Self {
        guard data.count <= maximumBytes else { throw LiveTVPortableStateError.tooLarge }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate(key: key)
        return record
    }

    public func validate(key: LiveTVPortableRecordKey) throws {
        guard version == 1 else { throw LiveTVPortableStateError.unsupportedVersion }
        guard !key.profileID.isEmpty, key.profileID.utf8.count <= 512,
              !key.entityID.isEmpty, key.entityID.utf8.count <= 1_024 else {
            throw LiveTVPortableStateError.invalidRecord
        }
        if key.kind == .serverEnrollment, !Self.safeIdentifier(key.entityID) {
            throw LiveTVPortableStateError.invalidRecord
        }
        let count = [channel != nil, source != nil, library != nil, snapshot != nil, serverEnrollmentSuppressed != nil].filter { $0 }.count
        guard count == (isDeleted ? 0 : 1) else { throw LiveTVPortableStateError.invalidRecord }
        guard !isDeleted else { return }
        switch key.kind {
        case .serverEnrollment:
            guard serverEnrollmentSuppressed != nil, Self.safeIdentifier(key.entityID) else {
                throw LiveTVPortableStateError.invalidRecord
            }
        case .channel:
            guard let channel,
                  [channel.hiddenName, channel.favoriteName, channel.metadata?.name,
                   channel.metadata?.category, channel.metadata?.language, channel.metadata?.country]
                    .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
                  channel.favoritePosition.map({ (0..<10_000).contains($0) }) ?? true,
                  channel.isFavorite || (channel.favoritePosition == nil && channel.favoriteName == nil),
                  channel.guideMapping?.isSafe ?? true,
                  channel.identityHint?.isSafe ?? true else {
                throw LiveTVPortableStateError.invalidRecord
            }
        case .source:
            guard let source, !source.name.isEmpty, source.name.utf8.count <= 512,
                  source.guideLookbackDays.map({ (0...7).contains($0) }) ?? true,
                  source.guideLookaheadDays.map({ (1...28).contains($0) }) ?? true,
                  ((source.kind == .playlist || source.kind == .importedPlaylist) && source.accountID == nil)
                    || (source.kind == .server && Self.safeIdentifier(source.accountID)
                        && source.discoversPlaylistGuides == nil
                        && source.guideLookbackDays == nil && source.guideLookaheadDays == nil) else {
                throw LiveTVPortableStateError.invalidRecord
            }
        case .library:
            guard let library, library.profileID == key.profileID,
                  library.id.uuidString == key.entityID else { throw LiveTVPortableStateError.wrongProfile }
            guard library.revisions.allSatisfy({
                $0.epochSeconds > -253_402_300_799 && $0.epochSeconds < 253_402_300_799
            }) else { throw LiveTVPortableStateError.invalidRecord }
            try library.validate()
            guard library.revisions.allSatisfy({ revision in
                revision.recipe.libraries.allSatisfy {
                    Self.safeIdentifier($0.accountID) && Self.safeIdentifier($0.libraryID)
                }
            }) else { throw LiveTVPortableStateError.invalidRecord }
        case .snapshot:
            guard let snapshot, snapshot.entityID == key.entityID,
                  (1...1_024).contains(snapshot.partCount),
                  (0..<snapshot.partCount).contains(snapshot.part),
                  !snapshot.items.isEmpty, snapshot.items.count <= 256,
                  snapshot.contentDigest.count == 64,
                  snapshot.createdAt.timeIntervalSince1970.isFinite,
                  snapshot.ineligibleDurationCount >= 0 else {
                throw LiveTVPortableStateError.invalidRecord
            }
            for item in snapshot.items {
                guard Self.safeIdentifier(item.library.accountID),
                      Self.safeIdentifier(item.serverID), Self.safeIdentifier(item.userID),
                      !item.itemID.isEmpty, item.itemID.utf8.count <= 2_048,
                      item.title.utf8.count <= 8_192,
                      (1...604_800).contains(item.durationSeconds),
                      item.kind == .movie || item.kind == .episode else {
                    throw LiveTVPortableStateError.invalidRecord
                }
            }
        }
    }

    private static func safeIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 512 else { return false }
        return !value.contains("://") && !value.contains("?") && !value.contains("\n")
    }
}

public enum LiveTVPortableSnapshots {
    public static func partition(_ snapshot: LibraryChannelSnapshot) throws -> [LiveTVPortableSnapshotPart] {
        try snapshot.validate()
        let digest = try contentDigest(snapshot)
        // Adaptive packing bounds records even when upstream titles are unusually long.
        var groups: [[LibraryChannelItem]] = []
        var current: [LibraryChannelItem] = []
        var bytes = 0
        let encoder = JSONEncoder()
        for item in snapshot.items {
            let size = try encoder.encode(item).count
            guard size <= 128 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
            if !current.isEmpty && (current.count == 256 || bytes + size > 128 * 1_024) {
                groups.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += size
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count <= 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return groups.enumerated().map { index, items in
            LiveTVPortableSnapshotPart(
                snapshotID: snapshot.id, part: index, partCount: groups.count, contentDigest: digest,
                createdAt: snapshot.createdAt, ineligibleDurationCount: snapshot.ineligibleDurationCount,
                items: items
            )
        }
    }

    public static func assemble(_ parts: [LiveTVPortableSnapshotPart]) throws -> LibraryChannelSnapshot {
        guard let first = parts.first, (1...1_024).contains(first.partCount),
              parts.count == first.partCount,
              parts.reduce(0, { $0 + $1.items.count }) <= LibraryChannelSnapshot.maximumItems,
              Set(parts.map(\.part)) == Set(0..<first.partCount),
              parts.allSatisfy({
                  $0.snapshotID == first.snapshotID && $0.partCount == first.partCount
                      && $0.contentDigest == first.contentDigest && $0.createdAt == first.createdAt
                      && $0.ineligibleDurationCount == first.ineligibleDurationCount
              }) else { throw LiveTVPortableStateError.incompleteSnapshot }
        let items = parts.sorted { $0.part < $1.part }.flatMap(\.items)
        let snapshot = try LibraryChannelSnapshot(
            id: first.snapshotID, items: items, createdAt: first.createdAt,
            ineligibleDurationCount: first.ineligibleDurationCount
        )
        guard try contentDigest(snapshot) == first.contentDigest else {
            throw LiveTVPortableStateError.invalidRecord
        }
        return snapshot
    }

    private static func contentDigest(_ snapshot: LibraryChannelSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot))
            .map { String(format: "%02x", $0) }.joined()
    }
}
