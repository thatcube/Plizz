#if DEBUG
import CoreModels
import Foundation

public struct LiveTVPortableGuideMappingExport: Sendable {
    public let mappings: [String: LiveTVPortableGuideMapping]
    /// Missing local metadata is not a user-authored mapping removal.
    public let unresolvedChannelIDs: Set<String>
}

extension LiveTVIndexedCache {
    public func portableSyncGuideMappings(
        configuration: LiveTVSourcesConfiguration
    ) throws -> LiveTVPortableGuideMappingExport {
        let overrides = try mappingOverrides()
        guard !overrides.isEmpty else {
            return .init(mappings: [:], unresolvedChannelIDs: [])
        }
        let catalog = try portableGuideCatalog(configuration: configuration)
        var mappings: [String: LiveTVPortableGuideMapping] = [:]
        for (channelID, override) in overrides {
            guard let owners = catalog[channelID], owners.count == 1 else { continue }
            let candidates = owners[0].guides.filter { $0.localID == override.guideSourceID }
            guard candidates.count == 1,
                  candidates[0].stationIDs.contains(override.guideChannelID),
                  owners[0].guides.filter({ $0.portableID == candidates[0].portableID }).count == 1 else { continue }
            let mapping = LiveTVPortableGuideMapping(
                guideSourceID: candidates[0].portableID, guideChannelID: override.guideChannelID
            )
            guard mapping.isSafe else { continue }
            mappings[channelID] = mapping
        }
        return .init(mappings: mappings, unresolvedChannelIDs: Set(overrides.keys).subtracting(mappings.keys))
    }

    /// Only identity hints associated with user-authored state leave this actor.
    /// Cached payloads from a previous endpoint cannot assert current identity.
    public func portableSyncIdentityHints(
        configuration: LiveTVSourcesConfiguration, channelIDs: Set<String>
    ) throws -> [String: LiveTVPortableChannelIdentityHint] {
        guard !channelIDs.isEmpty else { return [:] }
        var result: [String: LiveTVPortableChannelIdentityHint] = [:]
        for source in configuration.playlists {
            try Task.checkCancellation()
            guard let cached = try playlist(source: source) else { continue }
            let currentNativeIDs: Set<String>?
            if let documentID = source.importedPlaylistID {
                guard let imported = try? importedPlaylist(id: documentID) else { continue }
                let counts = Dictionary(grouping: imported.channels.compactMap {
                    LiveTVChannelIdentity.portableNativeID(for: $0)
                }, by: { $0 }).mapValues(\.count)
                currentNativeIDs = Set(counts.filter { $0.value == 1 }.keys)
            } else {
                currentNativeIDs = nil
            }
            let candidates = cached.channels.compactMap { channel -> (String, String)? in
                guard channel.id.hasPrefix("channel-"),
                      UUID(uuidString: String(channel.id.dropFirst("channel-".count))) != nil,
                      let native = LiveTVChannelIdentity.portableNativeID(for: channel) else { return nil }
                return (channel.id, native)
            }
            let counts = Dictionary(grouping: candidates, by: \.1).mapValues(\.count)
            for (channelID, nativeID) in candidates
            where channelIDs.contains(channelID) && counts[nativeID] == 1 {
                guard currentNativeIDs?.contains(nativeID) ?? true else { continue }
                let hint = LiveTVPortableChannelIdentityHint(sourceID: source.id, nativeID: nativeID)
                guard hint.isSafe else { continue }
                result[channelID] = hint
            }
        }
        return result
    }
}
#endif
