#if DEBUG
import CoreModels
import CryptoKit
import Foundation
import SQLite3

public struct LiveTVCacheFreshness: Codable, Equatable, Sendable {
    public let generation: String
    public let refreshedAt: Date
    public let expiresAt: Date?
}

public struct LiveTVGuideMappingOverride: Codable, Equatable, Sendable {
    public let guideSourceID: String
    public let guideChannelID: String

    public init(guideSourceID: String, guideChannelID: String) {
        self.guideSourceID = guideSourceID
        self.guideChannelID = guideChannelID
    }
}

public struct LiveTVGuideChannelOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var displayID: String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@+"))
        return id.utf8.count <= 512 && id.unicodeScalars.allSatisfy(allowed.contains) ? id : nil
    }
}

public enum LiveTVCacheError: Error, Equatable, Sendable {
    case unavailable, invalidRecord, tooLarge, invalidRange, authorizationScopeMismatch
}

/// IPTV-only cache: use a stable profile namespace and schema-authority label, not
/// a rotating server session. Callers admit only currently authorized, enabled sources.
/// Restores require current source URLs (and imported-file content); guide documents
/// also validate retention, provider and manual mappings. Identity history is profile-scoped
/// independently of downloaded generations. URLs/headers/artwork remain authenticated ciphertext.
public actor LiveTVIndexedCache {
    public static let maximumWindowChannels = 200
    public static let maximumWindowPrograms = 20_000
    private let url: URL
    private let secureStore: any SecureStoring
    private let scope: String
    private let durableScope: String
    private let importedFilesURL: URL?
    private var connection: LiveTVCacheConnection?
    private var encryptionKey: SymmetricKey?
    private var identityEncryptionKey: SymmetricKey?
    private var pendingPortableGuideChannelIDs: Set<String> = []
    private let catalogEncoder = JSONEncoder()
    private let catalogDecoder = JSONDecoder()

    private struct GuideSettings: Codable, Equatable {
        let version: Int
        let provider: String?
        let lookbackDays: Int
        let lookaheadDays: Int
        let mappingsDigest: String
    }

    private struct GuideDocument: Codable {
        let guide: LiveTVGuideImport?
        let settings: GuideSettings?
    }

    public init(
        url: URL, namespace: String, authorizationScope: String, secureStore: any SecureStoring,
        importedFilesURL: URL? = nil
    ) {
        self.url = url
        self.secureStore = secureStore
        self.importedFilesURL = importedFilesURL
        self.scope = SHA256.hash(data: Data((namespace + "\u{1f}" + authorizationScope).utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.durableScope = LiveTVIdentityDigest.hex(SHA256.hash(data: Data(namespace.utf8)))
    }

    public static func defaultURL(namespace: String, authorizationScope: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let scope = SHA256.hash(data: Data((namespace + "\u{1f}" + authorizationScope).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("LiveTV", isDirectory: true).appendingPathComponent(scope + ".sqlite")
    }

    public func importPlaylistFile(
        at fileURL: URL, id: UUID, baseURL: URL? = nil
    ) throws -> LiveTVPlaylistImport {
        guard fileURL.isFileURL else { throw LiveTVSourceImportError.invalidPlaylist }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        let data = try readBoundedFile(fileURL, maximumBytes: LiveTVPlaylistParser.maximumBytes)
        return try storeImportedPlaylist(data: data, id: id, baseURL: baseURL)
    }

    public func storeImportedPlaylist(
        data: Data, id: UUID, baseURL: URL? = nil
    ) throws -> LiveTVPlaylistImport {
        guard baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        let playlist = try LiveTVPlaylistParser(baseURL: baseURL).parse(data)
        guard !playlist.channels.isEmpty else { throw LiveTVSourceImportError.invalidPlaylist }
        let payload = try catalogEncoder.encode(ImportedPlaylistDocument(data: data, baseURL: baseURL))
        let aad = Data((durableScope + ":" + id.uuidString.lowercased()).utf8)
        let sealed = try AES.GCM.seal(payload, using: importedFileKey(), authenticating: aad)
        guard let bytes = sealed.combined else { throw LiveTVCacheError.invalidRecord }
        try Task.checkCancellation()
        let destination = try importedPlaylistURL(id)
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return playlist
    }

    public func importedPlaylist(id: UUID) throws -> LiveTVPlaylistImport {
        let bytes = try readBoundedFile(
            importedPlaylistURL(id), maximumBytes: LiveTVPlaylistParser.maximumBytes * 2 + 65_536
        )
        let aad = Data((durableScope + ":" + id.uuidString.lowercased()).utf8)
        let plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: bytes), using: importedFileKey(), authenticating: aad
        )
        let document = try catalogDecoder.decode(ImportedPlaylistDocument.self, from: plaintext)
        return try LiveTVPlaylistParser(baseURL: document.baseURL).parse(document.data)
    }

    public func removeImportedPlaylist(id: UUID) throws {
        let url = try importedPlaylistURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private struct ImportedPlaylistDocument: Codable {
        let data: Data
        let baseURL: URL?
    }

    private func importedPlaylistURL(_ id: UUID) throws -> URL {
        let base: URL
        if let importedFilesURL {
            base = importedFilesURL
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("LiveTVImports", isDirectory: true)
        }
        var directory = base.appendingPathComponent(durableScope, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directory.setResourceValues(resourceValues)
        return directory.appendingPathComponent(id.uuidString.lowercased() + ".sealed")
    }

    private func importedFileKey() throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: try identityKey(), salt: Data(durableScope.utf8),
            info: Data("imported-playlist-file".utf8), outputByteCount: 32
        )
    }

    private func readBoundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: min(65_536, maximumBytes - data.count + 1)),
              !next.isEmpty {
            try Task.checkCancellation()
            data.append(next)
            guard data.count <= maximumBytes else { throw LiveTVSourceImportError.responseTooLarge }
        }
        return data
    }

    func identityReviews(
        for playlist: LiveTVPlaylistImport, sourceID: String
    ) throws -> [LiveTVIdentityReview] {
        let records: [LiveTVChannelIdentityRecord] = try readPartitioned("identity." + sourceID)
        guard Set(records.map(\.id)).count == records.count else { throw LiveTVCacheError.invalidRecord }
        let currentIDs = Set(playlist.channels.map(\.id))
        let historical = records.filter { !currentIDs.contains($0.id) }
        let nativeCandidates = Dictionary(grouping: historical.compactMap { record in
            record.nativeKey.map { ($0, record.id) }
        }, by: \.0)
        let endpointCandidates = Dictionary(grouping: historical.compactMap { record in
            record.endpointKey.map { ($0, record.id) }
        }, by: \.0)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return playlist.channels.compactMap { channel in
            guard let record = byID[channel.id], record.requiresReview == true else { return nil }
            let native = record.nativeKey.flatMap { nativeCandidates[$0] } ?? []
            let endpoint = record.endpointKey.flatMap { endpointCandidates[$0] } ?? []
            let candidates = Set((Array(native.prefix(32)) + Array(endpoint.prefix(32))).map(\.1))
            return LiveTVIdentityReview(
                channelID: channel.id, name: channel.name, candidateIDs: Array(candidates.sorted().prefix(32))
            )
        }
    }

    public func reconcile(
        _ playlist: LiveTVPlaylistImport, sourceID: String
    ) throws -> LiveTVIdentityResolution {
        var records: [LiveTVChannelIdentityRecord] = try readPartitioned("identity." + sourceID)
        let identity = LiveTVChannelIdentity(key: try identityKey())
        let hints: [PortableIdentityRecord] = try readPartitioned("portable-identities")
        let nativeHints = hints.filter { $0.hint.sourceID == sourceID }.compactMap { record -> (String, String)? in
            LiveTVChannelIdentity.nativeEvidence(for: record.hint.nativeID).map {
                (identity.fingerprint($0), record.channelID)
            }
        }
        let preferred = Dictionary(grouping: nativeHints, by: \.0).mapValues { $0.map(\.1) }
        let result = try identity.reconcile(
            playlist, sourceID: sourceID, records: &records, preferredIDsByNativeKey: preferred
        )
        guard records.count <= LiveTVPlaylistParser.maximumEntries else { throw LiveTVCacheError.tooLarge }
        try writePartitioned(records, name: "identity." + sourceID)
        var mappings = try mappingOverrides()
        let originalMappings = mappings
        for (old, new) in result.migratedIDs.sorted(by: { $0.key < $1.key }) where old != new {
            if let value = mappings[old] {
                if mappings[new] == nil { mappings[new] = value }
                mappings[old] = nil
            }
        }
        if mappings != originalMappings {
            try writeMappings(mappings)
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
        }
        return result
    }

    public func confirmIdentity(
        sourceID: String, channelID: String, previousChannelID: String
    ) throws {
        var records: [LiveTVChannelIdentityRecord] = try readPartitioned("identity." + sourceID)
        guard channelID != previousChannelID,
              let current = records.first(where: { $0.id == channelID }),
              let previous = records.first(where: { $0.id == previousChannelID }) else {
            throw LiveTVCacheError.invalidRecord
        }

        records.removeAll { $0.id == channelID || $0.id == previousChannelID }
        records.append(LiveTVChannelIdentityRecord(
            id: previousChannelID, nativeKey: current.nativeKey, exactLocatorKey: current.exactLocatorKey,
            endpointKey: current.endpointKey, variantKey: current.variantKey,
            originalLegacyID: previous.originalLegacyID,
            legacyIDs: previous.legacyIDs.union(current.legacyIDs).union([channelID])
        ))
        try writePartitioned(records, name: "identity." + sourceID)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
    }

    public func discoveredGuideSourceID(sourceID: String, url: URL) throws -> String {
        var records: [DiscoveredGuideRecord] = try readPartitioned("discovered." + sourceID)
        let identity = LiveTVChannelIdentity(key: try identityKey())
        let fingerprint = identity.fingerprint(url.absoluteString)
        let stableFingerprint = try discoveredGuideStableFingerprint(url: url, identity: identity)
        if let existing = records.first(where: {
            $0.fingerprint == fingerprint || $0.stableFingerprint == stableFingerprint
        }) { return existing.id }
        guard records.count < 256 else { throw LiveTVCacheError.tooLarge }
        let id = "guide-" + UUID().uuidString.lowercased()
        records.append(DiscoveredGuideRecord(id: id, fingerprint: fingerprint, stableFingerprint: stableFingerprint))
        try writePartitioned(records, name: "discovered." + sourceID)
        return id
    }

    private func discoveredGuideStableFingerprint(url: URL, identity: LiveTVChannelIdentity) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw LiveTVCacheError.invalidRecord
        }
        let credentials: Set<String> = [
            "token", "access_token", "auth", "authorization", "expires", "expiry", "exp",
            "signature", "sig", "policy", "key-pair-id", "hdnts", "hdnea", "jwt"
        ]
        let query = components.queryItems?.filter { !credentials.contains($0.name.lowercased()) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.queryItems = query?.isEmpty == true ? nil : query
        components.fragment = nil
        guard let stableURL = components.url else { throw LiveTVCacheError.invalidRecord }
        return identity.fingerprint(stableURL.absoluteString)
    }

    public func associateLegacyID(sourceID: String, channelID: String, legacyID: String) throws {
        var records: [LiveTVChannelIdentityRecord] = try readPartitioned("identity." + sourceID)
        guard let index = records.firstIndex(where: { $0.id == channelID }),
              !records.contains(where: { $0.id != channelID && $0.legacyIDs.contains(legacyID) }) else {
            throw LiveTVCacheError.invalidRecord
        }
        let identityChanged = records[index].legacyIDs.insert(legacyID).inserted
        if identityChanged { try writePartitioned(records, name: "identity." + sourceID) }
        var mappings = try mappingOverrides()
        let originalMappings = mappings
        if mappings[channelID] == nil, let previous = mappings[legacyID] {
            mappings[channelID] = previous
            mappings[legacyID] = nil
            try writeMappings(mappings)
        }
        if identityChanged || mappings != originalMappings {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
        }
    }

    /// Input comes from the existing authenticated, per-profile portable sync
    /// adapter. Missing/ambiguous native identities are never inferred by name.
    public func applyPortableIdentityHints(_ changes: [String: LiveTVPortableChannelIdentityHint?]) throws {
        let records: [PortableIdentityRecord] = try readPartitioned("portable-identities")
        var hints = Dictionary(uniqueKeysWithValues: records.map { ($0.channelID, $0.hint) })
        let originalHints = hints
        for (channelID, hint) in changes {
            guard channelID.hasPrefix("channel-") else { continue }
            guard UUID(uuidString: String(channelID.dropFirst("channel-".count))) != nil,
                  hint?.isSafe ?? true,
                  hint.map({ LiveTVChannelIdentity.nativeEvidence(for: $0.nativeID) != nil }) ?? true else {
                throw LiveTVCacheError.invalidRecord
            }
            hints[channelID] = hint
        }
        guard hints.count <= 100_000 else { throw LiveTVCacheError.tooLarge }
        guard hints != originalHints else { return }
        try writePartitioned(hints.sorted(by: { $0.key < $1.key }).map {
            PortableIdentityRecord(channelID: $0.key, hint: $0.value)
        }, name: "portable-identities")
    }

    /// Only successfully resolved IDs may be acknowledged by the portable journal.
    /// `configuration` has already been filtered through fresh local source approval.
    @discardableResult
    public func applyPortableGuideMappings(
        _ changes: [String: LiveTVPortableGuideMapping?],
        configuration: LiveTVSourcesConfiguration = .empty
    ) throws -> Set<String> {
        guard !changes.isEmpty else { return [] }
        let catalog = try portableGuideCatalog(configuration: configuration)
        var mappings = try mappingOverrides()
        let originalMappings = mappings
        var resolved: Set<String> = []
        for (channelID, mapping) in changes {
            try Task.checkCancellation()
            guard channelID.hasPrefix("channel-"),
                  UUID(uuidString: String(channelID.dropFirst("channel-".count))) != nil else { continue }
            guard let mapping else {
                mappings[channelID] = nil
                resolved.insert(channelID)
                continue
            }
            guard mapping.isSafe, mapping.hasBoundSourceIdentity,
                  let owner = catalog[channelID], owner.count == 1 else { continue }
            let candidates = owner[0].guides.filter { $0.portableID == mapping.guideSourceID }
            guard candidates.count == 1,
                  candidates[0].stationIDs.contains(mapping.guideChannelID) else { continue }
            let value = LiveTVGuideMappingOverride(
                guideSourceID: candidates[0].localID, guideChannelID: mapping.guideChannelID
            )
            try validateMapping(value, channelID: channelID)
            mappings[channelID] = value
            resolved.insert(channelID)
        }
        if mappings != originalMappings { try writeMappings(mappings) }
        for (channelID, mapping) in changes {
            if !resolved.contains(channelID), mapping?.hasBoundSourceIdentity == true, mapping?.isSafe == true {
                pendingPortableGuideChannelIDs.insert(channelID)
            } else {
                pendingPortableGuideChannelIDs.remove(channelID)
            }
        }
        return resolved
    }

    struct PortableGuideCandidate {
        let localID: String
        let portableID: String
        let stationIDs: Set<String>
    }

    struct PortableGuideOwner {
        let guides: [PortableGuideCandidate]
    }

    func portableGuideCatalog(
        configuration: LiveTVSourcesConfiguration
    ) throws -> [String: [PortableGuideOwner]] {
        try configuration.validate()
        var result: [String: [PortableGuideOwner]] = [:]
        for source in configuration.playlists where source.isEnabled {
            try Task.checkCancellation()
            guard let playlist = try playlist(source: source) else { continue }
            var guides = LiveTVConfiguredSources.guides(for: source)
            if source.discoversPlaylistGuides {
                let records: [DiscoveredGuideRecord] = try readPartitioned("discovered." + source.id)
                let identity = LiveTVChannelIdentity(key: try identityKey())
                var seen = Set<URL>()
                for url in playlist.declaredGuideURLs where seen.insert(url).inserted {
                    guard guides.count < 32,
                          !source.guideURLs.contains(where: { LiveTVPlaylistSource.guideURLsShareIdentity($0, url) }),
                          LiveTVSourceOriginPolicy.permits(url, from: playlist.originURL ?? source.playlistURL) else { continue }
                    let exact = identity.fingerprint(url.absoluteString)
                    let stable = try discoveredGuideStableFingerprint(url: url, identity: identity)
                    for record in records where record.fingerprint == exact || record.stableFingerprint == stable {
                        guides.append(.init(
                            id: record.id, name: source.name, url: url, provider: LiveTVGuideSource.provider(for: url)
                        ))
                    }
                }
            }
            let db = try database()
            let candidates = try guides.compactMap { guide -> PortableGuideCandidate? in
                let binding = try sourceBinding(kind: "guide", sourceID: guide.id, url: guide.url)
                guard let binding,
                      try storedSourceBinding(kind: "guide", sourceID: guide.id, database: db) == binding,
                      let row = try db.rows(
                        "SELECT payload FROM documents WHERE kind='guide' AND source=?", [.text(guide.id)]
                      ).first else { return nil }
                let document = try open(row.blob(0), as: GuideDocument.self, binding: binding)
                guard let summary = document.guide else { return nil }
                return PortableGuideCandidate(
                    localID: guide.id,
                    portableID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guide.url),
                    stationIDs: Set(summary.guideChannels.keys)
                )
            }
            let owner = PortableGuideOwner(guides: candidates)
            for channel in playlist.channels {
                result[channel.id, default: []].append(owner)
            }
        }
        return result
    }

    public func storePlaylist(
        _ playlist: LiveTVPlaylistImport, source: LiveTVPlaylistSource, now: Date
    ) throws {
        try source.validate()
        try storePlaylist(playlist, sourceID: source.id, now: now, sourceURL: source.playlistURL)
    }

    /// Omitting the URL writes an unbound fixture record, never accepted by a source-bound restore.
    public func storePlaylist(
        _ playlist: LiveTVPlaylistImport, sourceID: String, now: Date, sourceURL: URL? = nil
    ) throws {
        let db = try database()
        let binding = try sourceBinding(kind: "playlist", sourceID: sourceID, url: sourceURL)
        try db.transaction {
            if !playlist.permitsPersistence,
               let previous = try storedSourceBinding(kind: "playlist", sourceID: sourceID, database: db),
               previous != binding { return }
            try db.execute("DELETE FROM channels WHERE source = ?", [.text(sourceID)])
            if !playlist.permitsPersistence {
                try db.execute("DELETE FROM documents WHERE kind='playlist' AND source=?", [.text(sourceID)])
                try writeSourceBinding(nil, kind: "playlist", sourceID: sourceID, database: db)
                return
            }
            for (ordinal, channel) in playlist.channels.enumerated() {
                if ordinal.isMultiple(of: 128) { try Task.checkCancellation() }
                try db.execute(
                    "INSERT INTO channels(source,id,ordinal,payload) VALUES(?,?,?,?)",
                    [.text(sourceID), .text(channel.id), .integer(ordinal), .blob(try seal(channel, binding: binding))]
                )
            }
            guard let totals = try db.rows("SELECT count(*),coalesce(sum(length(payload)),0) FROM channels").first,
                  try totals.real(0) <= Double(LiveTVPlaylistParser.maximumEntries),
                  try totals.real(1) <= 128 * 1_024 * 1_024 else {
                throw LiveTVCacheError.tooLarge
            }
            let metadata = LiveTVPlaylistImport(
                channels: [], entryCount: playlist.entryCount, skippedEntryCount: playlist.skippedEntryCount,
                declaredGuideURLs: playlist.declaredGuideURLs, originURL: playlist.originURL
            )
            try db.execute(
                "INSERT OR REPLACE INTO documents(kind,source,payload,generation,refreshed) VALUES('playlist',?,?,?,?)",
                [.text(sourceID), .blob(try seal(metadata, binding: binding)), .text(UUID().uuidString), .real(now.timeIntervalSince1970)]
            )
            try writeSourceBinding(binding, kind: "playlist", sourceID: sourceID, database: db)
        }
        if playlist.permitsPersistence,
           playlist.channels.contains(where: { pendingPortableGuideChannelIDs.contains($0.id) }) {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
        }
    }

    public func playlist(source: LiveTVPlaylistSource) throws -> LiveTVPlaylistImport? {
        try source.validate()
        guard source.isEnabled else { return nil }
        return try playlist(sourceID: source.id, sourceURL: source.playlistURL)
    }

    /// Internal fixture/implementation reader; production admission requires the source descriptor.
    func playlist(sourceID: String, sourceURL: URL? = nil) throws -> LiveTVPlaylistImport? {
        let db = try database()
        let binding = try sourceBinding(kind: "playlist", sourceID: sourceID, url: sourceURL)
        guard try storedSourceBinding(kind: "playlist", sourceID: sourceID, database: db) == binding else { return nil }
        guard let payload = try db.rows(
            "SELECT payload FROM documents WHERE kind='playlist' AND source=?", [.text(sourceID)]
        ).first?.blob(0) else { return nil }
        let metadata = try open(payload, as: LiveTVPlaylistImport.self, binding: binding)
        let channels = try db.rows(
            "SELECT payload FROM channels WHERE source=? ORDER BY ordinal LIMIT ?",
            [.text(sourceID), .integer(LiveTVPlaylistParser.maximumEntries)]
        ).map { try open($0.blob(0), as: LiveTVPrototypeChannel.self, binding: binding) }
        return LiveTVPlaylistImport(
            channels: channels, entryCount: metadata.entryCount, skippedEntryCount: metadata.skippedEntryCount,
            declaredGuideURLs: metadata.declaredGuideURLs, originURL: metadata.originURL
        )
    }

    public func guide(
        sourceID: String, sourceURL: URL? = nil, provider: LiveTVGuideProvider? = nil,
        lookbackDays: Int = 1, lookaheadDays: Int = 7
    ) throws -> LiveTVGuideImport? {
        let db = try database()
        let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURL)
        guard try storedSourceBinding(kind: "guide", sourceID: sourceID, database: db) == binding else { return nil }
        guard let data = try db.rows(
            "SELECT payload FROM documents WHERE kind='guide' AND source=?", [.text(sourceID)]
        ).first?.blob(0) else { return nil }
        let document = try open(data, as: GuideDocument.self, binding: binding)
        let overrides = try mappingOverrides().filter { $0.value.guideSourceID == sourceID }
            .mapValues(\.guideChannelID)
        let settings = try guideSettings(
            provider: provider, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays,
            overrides: overrides
        )
        guard document.settings == settings else { return nil }
        return document.guide
    }

    public func removeDownloadedGuide(sourceID: String, sourceURL: URL? = nil) throws {
        let db = try database()
        let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURL)
        guard try storedSourceBinding(kind: "guide", sourceID: sourceID, database: db) == binding else { return }
        try db.transaction {
            try db.execute("DELETE FROM program_search WHERE source=?", [.text(sourceID)])
            try db.execute("DELETE FROM programs WHERE source=?", [.text(sourceID)])
            try db.execute("DELETE FROM guide_channels WHERE source=?", [.text(sourceID)])
            try db.execute("DELETE FROM documents WHERE kind='guide' AND source=?", [.text(sourceID)])
            try writeSourceBinding(nil, kind: "guide", sourceID: sourceID, database: db)
        }
    }

    /// XML parser calls the sink synchronously inside this actor's transaction.
    /// No programme array or million-element deduplication set crosses to the main actor.
    public func importGuide(
        data: Data, sourceID: String, channels: [LiveTVPrototypeChannel],
        provider: LiveTVGuideProvider?, now: Date,
        lookbackDays: Int = 1, lookaheadDays: Int = 7, sourceURL: URL? = nil
    ) throws -> LiveTVGuideImport {
        let db = try database()
        let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURL)
        let overrides = try mappingOverrides().filter { $0.value.guideSourceID == sourceID }
            .mapValues(\.guideChannelID)
        let settings = try guideSettings(
            provider: provider, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays,
            overrides: overrides
        )
        var result: LiveTVGuideImport?
        var insertedProgramCount = 0
        try db.transaction {
            try db.execute("DELETE FROM program_search WHERE source=?", [.text(sourceID)])
            try db.execute("DELETE FROM programs WHERE source=?", [.text(sourceID)])
            try db.execute("DELETE FROM guide_channels WHERE source=?", [.text(sourceID)])
            result = try LiveTVXMLTVParser(provider: provider).parseIndexed(
                data: data, channels: channels, now: now, overrides: overrides,
                lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
            ) { program in
                try db.execute(
                    "INSERT OR IGNORE INTO programs(source,id,channel,start,end,payload) VALUES(?,?,?,?,?,?)",
                    [.text(sourceID), .text(program.id), .text(program.channelID),
                     .real(program.start.timeIntervalSince1970), .real(program.end.timeIntervalSince1970),
                     .blob(try self.seal(program, binding: binding))]
                )
                if db.changes > 0 {
                    insertedProgramCount += 1
                    try db.execute(
                        "INSERT INTO program_search(source,id,title) VALUES(?,?,?)",
                        [.text(sourceID), .text(program.id), .text(program.title)]
                    )
                }
            }
            guard let parsed = result else { throw LiveTVCacheError.invalidRecord }
            let totalPrograms = try db.rows("SELECT count(*) FROM programs").first?.real(0) ?? 0
            guard totalPrograms <= 5_000_000 else { throw LiveTVCacheError.tooLarge }
            let summary = LiveTVGuideImport(
                programs: [], matchedChannelCount: parsed.matchedChannelCount, guideChannelCount: parsed.guideChannelCount,
                programCount: insertedProgramCount, coverageStart: parsed.coverageStart, coverageEnd: parsed.coverageEnd,
                matches: parsed.matches, guideChannels: parsed.guideChannels
            )
            result = summary
            for (id, names) in summary.guideChannels {
                let option = LiveTVGuideChannelOption(id: id, name: names.first ?? "Guide station")
                try db.execute(
                    "INSERT INTO guide_channels(source,id,name,display_id,payload) VALUES(?,?,?,?,?)",
                    [.text(sourceID), .text(LiveTVChannelIdentity(key: try key()).fingerprint(id)),
                     .text(names.first ?? ""), .text(option.displayID ?? ""), .blob(try seal(option, binding: binding))]
                )
            }
            try db.execute(
                "INSERT OR REPLACE INTO documents(kind,source,payload,generation,refreshed) VALUES('guide',?,?,?,?)",
                [.text(sourceID), .blob(try seal(GuideDocument(guide: summary, settings: settings), binding: binding)),
                 .text(UUID().uuidString), .real(now.timeIntervalSince1970)]
            )
            try writeSourceBinding(binding, kind: "guide", sourceID: sourceID, database: db)
        }
        guard let result else { throw LiveTVCacheError.invalidRecord }
        // A source may finish loading after sync already attempted its pending
        // mappings. Retry from the durable journal, not from a stale importer.
        if channels.contains(where: { pendingPortableGuideChannelIDs.contains($0.id) }) {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
        }
        return result
    }

    public func programs(
        sourceID: String, channelIDs: [String], range: DateInterval,
        limit: Int = LiveTVIndexedCache.maximumWindowPrograms, sourceURL: URL? = nil
    ) throws -> [LiveTVPrototypeProgram] {
        guard !channelIDs.isEmpty else { return [] }
        guard channelIDs.count <= Self.maximumWindowChannels,
              range.duration > 0, range.duration <= 8 * 86_400,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite
        else { throw LiveTVCacheError.invalidRange }
        let db = try database()
        let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURL)
        guard try storedSourceBinding(kind: "guide", sourceID: sourceID, database: db) == binding else { return [] }
        let placeholders = Array(repeating: "?", count: channelIDs.count).joined(separator: ",")
        let bindings: [LiveTVCacheValue] = [.text(sourceID)] + channelIDs.map { .text($0) }
            + [.real(range.end.timeIntervalSince1970), .real(range.start.timeIntervalSince1970),
               .integer(min(max(1, limit), Self.maximumWindowPrograms))]
        return try db.rows(
            "SELECT payload FROM programs WHERE source=? AND channel IN (\(placeholders)) AND start<? AND end>? ORDER BY start,id LIMIT ?",
            bindings
        ).map { try open($0.blob(0), as: LiveTVPrototypeProgram.self, binding: binding) }
    }

    public func searchPrograms(
        query: String, sourceIDs: Set<String>, range: DateInterval, limit: Int = 100,
        selectedSourceByChannel: [String: String]? = nil, allowedChannelIDs: Set<String>? = nil,
        sourceURLs: [String: URL]? = nil
    ) throws -> [LiveTVPrototypeProgram] {
        guard !sourceIDs.isEmpty, limit > 0, allowedChannelIDs?.isEmpty != true else { return [] }
        let tokens = LiveTVProgramSearchMatcher(query).tokens
        guard !tokens.isEmpty else { return [] }
        guard range.duration > 0, range.duration <= 32 * 86_400, sourceIDs.count <= 3_200,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              (allowedChannelIDs?.count ?? 0) <= LiveTVPlaylistParser.maximumEntries,
              (selectedSourceByChannel?.count ?? 0) <= LiveTVPlaylistParser.maximumEntries else {
            throw LiveTVCacheError.invalidRange
        }
        let match = tokens.map { "\"\($0.prefix(128))\"*" }.joined(separator: " AND ")
        let db = try database()
        var sources: [String] = []
        var sourceBindings: [String: String] = [:]
        for sourceID in sourceIDs.sorted() {
            if sourceURLs != nil, sourceURLs?[sourceID] == nil { continue }
            let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURLs?[sourceID])
            guard try storedSourceBinding(kind: "guide", sourceID: sourceID, database: db) == binding else { continue }
            sources.append(sourceID)
            sourceBindings[sourceID] = binding
        }
        guard !sources.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS search_scope(channel TEXT PRIMARY KEY,source TEXT)")
        try db.execute("DELETE FROM search_scope")
        if let selectedSourceByChannel {
            for (channel, source) in selectedSourceByChannel where allowedChannelIDs?.contains(channel) ?? true {
                try Task.checkCancellation()
                try db.execute("INSERT INTO search_scope(channel,source) VALUES(?,?)", [.text(channel), .text(source)])
            }
        }
        if selectedSourceByChannel == nil, let allowedChannelIDs {
            for channel in allowedChannelIDs {
                try Task.checkCancellation()
                try db.execute("INSERT INTO search_scope(channel,source) VALUES(?,?)", [.text(channel), .text("")])
            }
        }
        let scoped = selectedSourceByChannel != nil || allowedChannelIDs != nil
        let rows = try db.rows("""
            SELECT p.payload,p.source FROM program_search s JOIN programs p ON p.source=s.source AND p.id=s.id
            WHERE program_search MATCH ? AND p.source IN (\(placeholders)) AND p.start<? AND p.end>?
            \(scoped ? "AND EXISTS(SELECT 1 FROM search_scope a WHERE a.channel=p.channel AND (a.source=p.source OR a.source=''))" : "")
            ORDER BY p.start,p.id LIMIT ?
            """, [.text(match)] + sources.map { .text($0) } + [
                .real(range.end.timeIntervalSince1970), .real(range.start.timeIntervalSince1970),
                .integer(min(max(1, limit), 500))
            ])
        return try rows.map {
            try open($0.blob(0), as: LiveTVPrototypeProgram.self, binding: sourceBindings[$0.text(1)])
        }
    }

    public func guideChannels(
        sourceID: String, query: String = "", limit: Int = 100, sourceURL: URL? = nil
    ) throws -> [LiveTVGuideChannelOption] {
        let db = try database()
        let binding = try sourceBinding(kind: "guide", sourceID: sourceID, url: sourceURL)
        guard try storedSourceBinding(kind: "guide", sourceID: sourceID, database: db) == binding else { return [] }
        let rows = try db.rows(
            "SELECT payload FROM guide_channels WHERE source=? AND (name LIKE ? ESCAPE '\\' OR display_id LIKE ? ESCAPE '\\') ORDER BY name,id LIMIT ?",
            [.text(sourceID), .text("%" + escapedLike(query) + "%"), .text("%" + escapedLike(query) + "%"),
             .integer(min(max(1, limit), 500))]
        )
        return try rows.map { try open($0.blob(0), as: LiveTVGuideChannelOption.self, binding: binding) }
    }

    public func freshness(kind: String, sourceID: String) throws -> LiveTVCacheFreshness? {
        guard let row = try database().rows(
            "SELECT generation,refreshed FROM documents WHERE kind=? AND source=?", [.text(kind), .text(sourceID)]
        ).first else { return nil }
        return try LiveTVCacheFreshness(generation: row.text(0), refreshedAt: Date(timeIntervalSince1970: row.real(1)), expiresAt: nil)
    }

    public func mappingOverrides() throws -> [String: LiveTVGuideMappingOverride] {
        let records: [MappingRecord] = try readPartitioned("mappings")
        guard Set(records.map(\.channelID)).count == records.count else { throw LiveTVCacheError.invalidRecord }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.channelID, $0.mapping) })
    }

    public func setMapping(_ mapping: LiveTVGuideMappingOverride?, channelID: String) throws {
        try validateMapping(mapping, channelID: channelID)
        var mappings = try mappingOverrides()
        guard mappings[channelID] != mapping else { return }
        mappings[channelID] = mapping
        try writeMappings(mappings)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
    }

    private func validateMapping(_ mapping: LiveTVGuideMappingOverride?, channelID: String) throws {
        guard !channelID.isEmpty, channelID.utf8.count <= 256,
              mapping.map({ !$0.guideSourceID.isEmpty && $0.guideSourceID.utf8.count <= 180
                  && !$0.guideChannelID.isEmpty && $0.guideChannelID.utf8.count <= 4_096 }) ?? true else {
            throw LiveTVCacheError.invalidRecord
        }
    }

    private func writeMappings(_ mappings: [String: LiveTVGuideMappingOverride]) throws {
        guard mappings.count <= 100_000 else { throw LiveTVCacheError.tooLarge }
        try writePartitioned(mappings.sorted(by: { $0.key < $1.key }).map {
            MappingRecord(channelID: $0.key, mapping: $0.value)
        }, name: "mappings")
    }

    private func secureName(_ suffix: String) -> String { "liveTV.identity." + durableScope + "." + suffix }

    private func identityKey() throws -> SymmetricKey {
        if let identityEncryptionKey { return identityEncryptionKey }
        let result = try loadOrCreateKey(name: secureName("key"))
        identityEncryptionKey = result
        return result
    }

    private func key() throws -> SymmetricKey {
        if let encryptionKey { return encryptionKey }
        let result = try loadOrCreateKey(name: "liveTV.catalog." + scope + ".key")
        encryptionKey = result
        return result
    }

    private func loadOrCreateKey(name: String) throws -> SymmetricKey {
        let value: Data
        if let stored = try secureStore.readString(for: name) {
            guard let decoded = Data(base64Encoded: stored), decoded.count == 32 else {
                throw LiveTVCacheError.invalidRecord
            }
            value = decoded
        } else {
            value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try secureStore.setString(value.base64EncodedString(), for: name)
        }
        let result = SymmetricKey(data: value)
        return result
    }

    private func guideSettings(
        provider: LiveTVGuideProvider?, lookbackDays: Int, lookaheadDays: Int,
        overrides: [String: String]
    ) throws -> GuideSettings {
        guard (0...7).contains(lookbackDays), (1...28).contains(lookaheadDays) else {
            throw LiveTVCacheError.invalidRange
        }
        let entries = overrides.keys.sorted().map { [$0, overrides[$0] ?? ""] }
        let data = try catalogEncoder.encode(entries)
        return GuideSettings(
            version: 1, provider: provider?.rawValue, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays,
            mappingsDigest: LiveTVChannelIdentity(key: try identityKey()).fingerprint(
                String(decoding: data, as: UTF8.self)
            )
        )
    }

    private func sourceBinding(kind: String, sourceID: String, url: URL?) throws -> String? {
        guard let url else { return nil }
        var material = ["cache-source-v1", kind, sourceID, url.absoluteString]
        if kind == "playlist", url.scheme == "plozz-playlist" {
            guard let id = url.host.flatMap(UUID.init(uuidString:)) else { throw LiveTVCacheError.invalidRecord }
            let file = try importedPlaylistURL(id)
            if FileManager.default.fileExists(atPath: file.path) {
                let encrypted = try readBoundedFile(
                    file, maximumBytes: LiveTVPlaylistParser.maximumBytes * 2 + 65_536
                )
                material.append(LiveTVIdentityDigest.hex(SHA256.hash(data: encrypted)))
            } else {
                material.append("missing-imported-file")
            }
        }
        return LiveTVChannelIdentity(key: try identityKey()).fingerprint(
            material.joined(separator: "\u{1f}")
        )
    }

    private func storedSourceBinding(
        kind: String, sourceID: String, database: LiveTVCacheConnection
    ) throws -> String? {
        try database.rows(
            "SELECT value FROM meta WHERE key=?", [.text("binding:" + kind + ":" + sourceID)]
        ).first?.text(0)
    }

    private func writeSourceBinding(
        _ binding: String?, kind: String, sourceID: String, database: LiveTVCacheConnection
    ) throws {
        let name = "binding:" + kind + ":" + sourceID
        if let binding {
            try database.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [.text(name), .text(binding)])
        } else {
            try database.execute("DELETE FROM meta WHERE key=?", [.text(name)])
        }
    }

    private func seal<T: Encodable>(_ value: T, binding: String? = nil) throws -> Data {
        let authenticatedData = Data((scope + (binding.map { "\u{1f}" + $0 } ?? "")).utf8)
        guard let data = try AES.GCM.seal(catalogEncoder.encode(value), using: key(), authenticating: authenticatedData).combined else {
            throw LiveTVCacheError.invalidRecord
        }
        return data
    }

    private func open<T: Decodable>(_ data: Data, as type: T.Type, binding: String? = nil) throws -> T {
        let authenticatedData = Data((scope + (binding.map { "\u{1f}" + $0 } ?? "")).utf8)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(), authenticating: authenticatedData)
        return try catalogDecoder.decode(type, from: plaintext)
    }

    private struct Manifest: Codable { let generation: String; let count: Int }
    private struct MappingRecord: Codable { let channelID: String; let mapping: LiveTVGuideMappingOverride }
    private struct DiscoveredGuideRecord: Codable {
        let id: String
        let fingerprint: String
        let stableFingerprint: String?
    }
    private struct PortableIdentityRecord: Codable { let channelID: String; let hint: LiveTVPortableChannelIdentityHint }

    private func readPartitioned<T: Decodable>(_ name: String) throws -> [T] {
        guard let raw = try secureStore.readString(for: secureName(name)),
              let data = raw.data(using: .utf8) else { return [] }
        guard data.count <= 1_024 else { throw LiveTVCacheError.invalidRecord }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard (0...800).contains(manifest.count) else { throw LiveTVCacheError.invalidRecord }
        var result: [T] = []
        for index in 0..<manifest.count {
            guard let encoded = try secureStore.readString(for: secureName(name + "." + manifest.generation + ".\(index)")),
                  let data = encoded.data(using: .utf8) else { throw LiveTVCacheError.invalidRecord }
            guard data.count <= 2 * 1_024 * 1_024 else { throw LiveTVCacheError.tooLarge }
            result += try JSONDecoder().decode([T].self, from: data)
        }
        return result
    }

    private func writePartitioned<T: Encodable>(_ records: [T], name: String) throws {
        let oldValue = try secureStore.readString(for: secureName(name))
        let old = try oldValue.map { try JSONDecoder().decode(Manifest.self, from: Data($0.utf8)) }
        let chunks = try stride(from: 0, to: records.count, by: 128).map {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(Array(records[$0..<min(records.count, $0 + 128)])), as: UTF8.self)
        }
        if let old, old.count == chunks.count {
            var unchanged = true
            for index in chunks.indices {
                if try secureStore.readString(for: secureName(name + "." + old.generation + ".\(index)")) != chunks[index] {
                    unchanged = false
                    break
                }
            }
            if unchanged { return }
        }
        let generation = UUID().uuidString
        let count = chunks.count
        guard count <= 800, chunks.allSatisfy({ $0.utf8.count <= 2 * 1_024 * 1_024 }) else {
            throw LiveTVCacheError.tooLarge
        }
        for index in chunks.indices {
            try secureStore.setString(chunks[index], for: secureName(name + "." + generation + ".\(index)"))
        }
        let manifest = try JSONEncoder().encode(Manifest(generation: generation, count: count))
        try secureStore.setString(String(decoding: manifest, as: UTF8.self), for: secureName(name))
        // Commit manifest before pruning superseded records; a failed refresh
        // never points at a partial generation.
        if let old {
            for index in 0..<old.count {
                try secureStore.removeValue(for: secureName(name + "." + old.generation + ".\(index)"))
            }
        }
    }

    private func database() throws -> LiveTVCacheConnection {
        if let connection { return connection }
        _ = try key()
        let result = try LiveTVCacheConnection(url: url)
        if let savedScope = try result.rows("SELECT value FROM meta WHERE key='scope'").first?.text(0) {
            guard savedScope == scope else { throw LiveTVCacheError.authorizationScopeMismatch }
        } else {
            try result.execute("INSERT INTO meta(key,value) VALUES('scope',?)", [.text(scope)])
        }
        connection = result
        return result
    }

    private func escapedLike(_ value: String) -> String {
        String(value.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

private enum LiveTVCacheValue {
    case text(String), integer(Int), real(Double), blob(Data)
}

private struct LiveTVCacheRow {
    let values: [LiveTVCacheValue]
    func text(_ index: Int) throws -> String {
        guard values.indices.contains(index), case .text(let value) = values[index] else { throw LiveTVCacheError.invalidRecord }
        return value
    }
    func real(_ index: Int) throws -> Double {
        guard values.indices.contains(index), case .real(let value) = values[index] else { throw LiveTVCacheError.invalidRecord }
        return value
    }
    func blob(_ index: Int) throws -> Data {
        guard values.indices.contains(index), case .blob(let value) = values[index] else { throw LiveTVCacheError.invalidRecord }
        return value
    }
}

/// Follows the existing CatalogConnection ownership pattern without importing ProviderShare.
private final class LiveTVCacheConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var changes: Int32 { sqlite3_changes(handle) }

    init(url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty else { throw LiveTVCacheError.unavailable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw LiveTVCacheError.unavailable
        }
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA max_page_count=524288")
            let version = try rows("PRAGMA user_version").first?.real(0) ?? -1
            guard version >= 0, version <= 1 else { throw LiveTVCacheError.invalidRecord }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS channels(source TEXT NOT NULL,id TEXT NOT NULL,ordinal INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source,id))")
                try execute("CREATE INDEX IF NOT EXISTS channels_order ON channels(source,ordinal)")
                try execute("CREATE TABLE IF NOT EXISTS documents(kind TEXT NOT NULL,source TEXT NOT NULL,payload BLOB NOT NULL,generation TEXT NOT NULL,refreshed REAL NOT NULL,PRIMARY KEY(kind,source))")
                try execute("CREATE TABLE IF NOT EXISTS programs(source TEXT NOT NULL,id TEXT NOT NULL,channel TEXT NOT NULL,start REAL NOT NULL,end REAL NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source,id))")
                try execute("CREATE INDEX IF NOT EXISTS programs_range ON programs(source,channel,start,end)")
                try execute("CREATE TABLE IF NOT EXISTS guide_channels(source TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,display_id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source,id))")
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS program_search USING fts5(source UNINDEXED,id UNINDEXED,title,tokenize='unicode61')")
                try execute("PRAGMA user_version=1")
            }
        } catch {
            for statement in statements.values { sqlite3_finalize(statement) }
            statements.removeAll()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close(handle) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try Task.checkCancellation()
            try execute("COMMIT")
        } catch {
            guard sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw LiveTVCacheError.unavailable }
            throw error
        }
    }

    func execute(_ sql: String, _ bindings: [LiveTVCacheValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw LiveTVCacheError.unavailable }
    }

    func rows(_ sql: String, _ bindings: [LiveTVCacheValue] = []) throws -> [LiveTVCacheRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var result: [LiveTVCacheRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw LiveTVCacheError.unavailable }
            if result.count.isMultiple(of: 128) { try Task.checkCancellation() }
            var values: [LiveTVCacheValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_blob(statement, column), count > 0 else {
                        throw LiveTVCacheError.invalidRecord
                    }
                    values.append(.blob(Data(bytes: bytes, count: count)))
                case SQLITE_FLOAT, SQLITE_INTEGER:
                    values.append(.real(sqlite3_column_double(statement, column)))
                default:
                    guard let text = sqlite3_column_text(statement, column) else { throw LiveTVCacheError.invalidRecord }
                    values.append(.text(String(cString: text)))
                }
            }
            result.append(LiveTVCacheRow(values: values))
        }
        return result
    }

    private func prepare(_ sql: String, _ bindings: [LiveTVCacheValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let prepared = statements[sql] {
            statement = prepared
        } else {
            if statements.count >= 64 {
                for cached in statements.values { sqlite3_finalize(cached) }
                statements.removeAll(keepingCapacity: true)
            }
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw LiveTVCacheError.unavailable
            }
            statement = prepared
            statements[sql] = prepared
        }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch binding {
                case .text(let value): code = sqlite3_bind_text(statement, index, value, -1, Self.transient)
                case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
                case .real(let value): code = sqlite3_bind_double(statement, index, value)
                case .blob(let value):
                    code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
                }
                guard code == SQLITE_OK else { throw LiveTVCacheError.unavailable }
            }
            return statement
        } catch {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            throw error
        }
    }
}
#endif
