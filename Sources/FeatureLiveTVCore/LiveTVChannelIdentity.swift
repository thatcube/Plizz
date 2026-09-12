#if DEBUG
import CoreModels
import CryptoKit
import Foundation

public struct LiveTVIdentityReview: Codable, Equatable, Identifiable, Sendable {
    public let channelID: String
    public let name: String
    public let candidateIDs: [String]
    public var id: String { channelID }
}

public struct LiveTVIdentityResolution: Sendable {
    public let playlist: LiveTVPlaylistImport
    public let migratedIDs: [String: String]
    public let reviews: [LiveTVIdentityReview]
}

/// Small identity records are durable, separate from evictable downloaded catalogs.
/// All locator evidence is keyed, never a URL, an unkeyed URL hash, or a display-name identity.
struct LiveTVChannelIdentityRecord: Codable, Sendable {
    var id: String
    var nativeKey: String?
    var exactLocatorKey: String?
    var endpointKey: String?
    var variantKey: String?
    var originalLegacyID: String? = nil
    var legacyIDs: Set<String>
    var requiresReview: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case id, nativeKey, exactLocatorKey, endpointKey, variantKey, originalLegacyID, legacyIDs
        case requiresReview
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(nativeKey, forKey: .nativeKey)
        try values.encodeIfPresent(exactLocatorKey, forKey: .exactLocatorKey)
        try values.encodeIfPresent(endpointKey, forKey: .endpointKey)
        try values.encodeIfPresent(variantKey, forKey: .variantKey)
        try values.encodeIfPresent(originalLegacyID, forKey: .originalLegacyID)
        try values.encode(legacyIDs.sorted(), forKey: .legacyIDs)
        try values.encodeIfPresent(requiresReview, forKey: .requiresReview)
    }
}

struct LiveTVChannelIdentity {
    let key: SymmetricKey

    static func portableNativeID(for channel: LiveTVPrototypeChannel) -> String? {
        let identity = LiveTVStreamIdentity(url: channel.streamURL)
        if let native = identity.nativeID, let provider = identity.provider {
            return "provider:" + provider.rawValue + ":" + native
        }
        guard let native = channel.guideID, isSafeNativeID(native) else { return nil }
        return "tvg:" + Data(native.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func nativeEvidence(for portable: String) -> String? {
        if portable.hasPrefix("provider:") { return portable }
        if portable.hasPrefix("tvg:") {
            var encoded = String(portable.dropFirst(4)).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded), let native = String(data: data, encoding: .utf8),
                  isSafeNativeID(native) else { return nil }
            return "native:" + native
        }
        return isSafeNativeID(portable) ? "native:" + portable : nil
    }

    private static func isSafeNativeID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:@+"))
        return !value.isEmpty && value.utf8.count <= 256
            && !(value.contains(":") && value.contains("@"))
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    func fingerprint(_ value: String) -> String {
        LiveTVIdentityDigest.hex(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
    }

    func reconcile(
        _ playlist: LiveTVPlaylistImport, sourceID: String,
        records: inout [LiveTVChannelIdentityRecord],
        preferredIDsByNativeKey: [String: [String]] = [:]
    ) throws -> LiveTVIdentityResolution {
        let evidence = playlist.channels.map { channel -> (native: String?, exact: String?, endpoint: String?, variant: String?) in
            let providerIdentity = LiveTVStreamIdentity(url: channel.streamURL)
            let native: String?
            if let id = providerIdentity.nativeID, let provider = providerIdentity.provider {
                native = fingerprint("provider:" + provider.rawValue + ":" + id)
            } else {
                native = channel.guideID.flatMap { $0.isEmpty ? nil : fingerprint("native:" + $0) }
            }
            let exact = channel.streamURL.map { fingerprint("url:" + $0.absoluteString) }
            var components = channel.streamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) }
            let rotatingCredentials: Set<String> = [
                "token", "access_token", "authorization", "auth", "expires", "expiry", "exp",
                "signature", "sig", "policy", "key-pair-id", "hdnts", "hdnea", "jwt"
            ]
            let retainedQuery = components?.queryItems?.filter { !rotatingCredentials.contains($0.name.lowercased()) }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components?.queryItems = retainedQuery?.isEmpty == true ? nil : retainedQuery
            components?.fragment = nil
            let endpoint = components?.url.map { fingerprint("endpoint:" + $0.absoluteString) }
            let variant = channel.streamURL.map {
                fingerprint("variant:" + [$0.absoluteString, channel.guideName ?? channel.name,
                    channel.country ?? "", channel.language ?? ""].joined(separator: "\u{1f}"))
            }
            return (native, exact, endpoint, variant)
        }
        let nativeCounts = Dictionary(grouping: evidence.compactMap(\.native), by: { $0 }).mapValues(\.count)
        let endpointCounts = Dictionary(grouping: evidence.compactMap(\.endpoint), by: { $0 }).mapValues(\.count)
        let nativeRecords = Dictionary(grouping: records.indices.compactMap { index in
            records[index].nativeKey.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
        let exactRecords = Dictionary(grouping: records.indices.compactMap { index in
            records[index].exactLocatorKey.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
        let endpointRecords = Dictionary(grouping: records.indices.compactMap { index in
            records[index].endpointKey.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
        let variantRecords = Dictionary(grouping: records.indices.compactMap { index in
            records[index].variantKey.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
        var ownerByID: [String: Int] = [:]
        for index in records.indices {
            guard ownerByID.updateValue(index, forKey: records[index].id) == nil else {
                throw LiveTVCacheError.invalidRecord
            }
        }
        var used = Set<String>()
        var channels: [LiveTVPrototypeChannel] = []
        var migrated: [String: String] = [:]
        var reviews: [LiveTVIdentityReview] = []
        let scopedLegacy = LiveTVConfiguredSources.scope(playlist, to: sourceID)
        for (index, channel) in playlist.channels.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let value = evidence[index]
            let natives = value.native.flatMap { nativeRecords[$0] } ?? []
            let exacts = value.exact.flatMap { exactRecords[$0] } ?? []
            let endpoints = value.endpoint.flatMap { endpointRecords[$0] } ?? []
            let variants = value.variant.flatMap { variantRecords[$0] } ?? []
            var selected: Int?
            if let native = value.native, nativeCounts[native] == 1, natives.count == 1 {
                selected = natives.first
            } else if exacts.count == 1,
                      value.native == nil || records[exacts[0]].nativeKey == nil
                        || value.native == records[exacts[0]].nativeKey {
                selected = exacts.first
            } else if variants.count == 1,
                      value.native == nil || records[variants[0]].nativeKey == nil
                        || value.native == records[variants[0]].nativeKey {
                selected = variants.first
            } else if value.native == nil, let endpoint = value.endpoint,
                      endpointCounts[endpoint] == 1, endpoints.count == 1,
                      records[endpoints[0]].nativeKey == nil {
                // A path-only rotation is deliberately NOT guessed. Only query token rotation
                // on a unique, previously known endpoint can retain a no-ID channel.
                selected = endpoints.first
            }
            if let selectedIndex = selected, used.contains(records[selectedIndex].id) { selected = nil }
            let id: String
            if let selected {
                if let native = value.native, nativeCounts[native] == 1, natives.count == 1,
                   let preferred = preferredIDsByNativeKey[native], !preferred.isEmpty {
                    guard preferred.allSatisfy({ ownerByID[$0] == nil || ownerByID[$0] == selected }) else {
                        throw LiveTVCacheError.invalidRecord
                    }
                    let oldID = records[selected].id
                    records[selected].id = ([oldID] + preferred).min() ?? oldID
                    records[selected].legacyIDs.formUnion(preferred + [oldID])
                    for alias in preferred { ownerByID[alias] = selected }
                }
                id = records[selected].id
                records[selected].nativeKey = value.native
                records[selected].exactLocatorKey = value.exact
                records[selected].endpointKey = value.endpoint
                records[selected].variantKey = value.variant
                records[selected].legacyIDs.insert(scopedLegacy.channels[index].id)
                if records[selected].legacyIDs.count > 64 {
                    let original = records[selected].originalLegacyID
                    records[selected].legacyIDs = Set(records[selected].legacyIDs.sorted().prefix(63))
                    if let original { records[selected].legacyIDs.insert(original) }
                }
                if records[selected].requiresReview == true {
                    let candidates = Array(Set((Array(natives.prefix(32)) + Array(endpoints.prefix(32)))
                        .map { records[$0].id }).sorted().prefix(32))
                    reviews.append(LiveTVIdentityReview(channelID: id, name: channel.name, candidateIDs: candidates))
                }
            } else {
                let preferred = value.native.flatMap { nativeCounts[$0] == 1 ? preferredIDsByNativeKey[$0] : nil } ?? []
                guard preferred.allSatisfy({ ownerByID[$0] == nil }) else {
                    throw LiveTVCacheError.invalidRecord
                }
                id = preferred.min() ?? ("channel-" + UUID().uuidString.lowercased())
                ownerByID[id] = records.count
                for alias in preferred { ownerByID[alias] = records.count }
                records.append(LiveTVChannelIdentityRecord(
                    id: id, nativeKey: value.native, exactLocatorKey: value.exact,
                    endpointKey: value.endpoint, variantKey: value.variant,
                    originalLegacyID: scopedLegacy.channels[index].id,
                    legacyIDs: Set(preferred + [scopedLegacy.channels[index].id])
                ))
                let candidates = Array(Set((Array(natives.prefix(32)) + Array(endpoints.prefix(32)))
                    .map { records[$0].id }).sorted().prefix(32))
                if !candidates.isEmpty || value.native.map({ nativeCounts[$0, default: 0] > 1 }) == true {
                    records[records.count - 1].requiresReview = true
                    reviews.append(LiveTVIdentityReview(channelID: id, name: channel.name, candidateIDs: candidates))
                }
            }
            used.insert(id)
            migrated[scopedLegacy.channels[index].id] = id
            if sourceID == "free-us" { migrated[channel.id] = id }
            channels.append(channel.replacingIdentity(id: id, sourceID: sourceID))
        }
        for record in records where used.contains(record.id) {
            for old in record.legacyIDs { migrated[old] = record.id }
        }
        return LiveTVIdentityResolution(
            playlist: LiveTVPlaylistImport(
                channels: channels, entryCount: playlist.entryCount, skippedEntryCount: playlist.skippedEntryCount,
                declaredGuideURLs: playlist.declaredGuideURLs, permitsPersistence: playlist.permitsPersistence,
                originURL: playlist.originURL
            ),
            migratedIDs: migrated, reviews: reviews.map {
                LiveTVIdentityReview(
                    channelID: $0.channelID, name: $0.name,
                    candidateIDs: $0.candidateIDs.filter { !used.contains($0) }
                )
            }
        )
    }
}

enum LiveTVIdentityDigest {
    static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension LiveTVPrototypeChannel {
    func replacingIdentity(id: String, sourceID: String?) -> Self {
        Self(
            id: id, number: number, name: name, category: category, symbol: symbol, accent: accent,
            source: source, tagline: tagline, logoURL: logoURL, streamURL: streamURL,
            logoNeedsDarkBackground: logoNeedsDarkBackground, guideID: guideID, guideName: guideName,
            httpHeaders: httpHeaders, playlistSourceID: sourceID, language: language, country: country, groups: groups
        )
    }
}
#endif
