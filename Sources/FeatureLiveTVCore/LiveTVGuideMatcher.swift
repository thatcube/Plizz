#if DEBUG
import Foundation

public struct LiveTVGuideMatcher: Sendable {
    private let provider: LiveTVGuideProvider?
    private let aliasSet: LiveTVGuideAliasSet?

    public init(provider: LiveTVGuideProvider? = nil, aliasSet: LiveTVGuideAliasSet? = nil) {
        self.provider = provider
        self.aliasSet = aliasSet
    }

    public func match(
        channels: [LiveTVPrototypeChannel],
        guideChannels: [String: [String]]
    ) -> [String: [LiveTVPrototypeChannel]] {
        matching(channels: channels, guideChannels: guideChannels).channelsByGuideID
    }

    func matching(
        channels: [LiveTVPrototypeChannel],
        guideChannels: [String: [String]],
        overrides: [String: String] = [:]
    ) -> (channelsByGuideID: [String: [LiveTVPrototypeChannel]], assignments: [String: LiveTVGuideMatch]) {
        let identities = channels.reduce(into: [String: LiveTVStreamIdentity]()) {
            $0[$1.id] = LiveTVStreamIdentity(url: $1.streamURL)
        }
        let allChannels = channels
        let channels = channels.filter { channel in
            if overrides[channel.id] != nil { return true }
            let identity = identities[channel.id]
            if let provider, let actual = identity?.provider, provider != actual { return false }
            if provider != nil, let region = identity?.region, region != "us" { return false }
            return true
        }
        let playlistIDs = Dictionary(
            grouping: channels.compactMap { channel in
                channel.guideID.map { ($0, channel) }
            },
            by: \.0
        )
        var result: [String: [LiveTVPrototypeChannel]] = [:]
        var assignments: [String: LiveTVGuideMatch] = [:]
        for channel in allChannels {
            if let id = overrides[channel.id], guideChannels[id] != nil {
                result[id, default: []].append(channel)
                assignments[channel.id] = LiveTVGuideMatch(guideChannelID: id, method: .userConfirmed)
            }
        }
        for channel in channels where assignments[channel.id] == nil && overrides[channel.id] == nil {
            if let id = channel.guideID, guideChannels[id] != nil,
               shareOneIdentity(playlistIDs[id]?.map(\.1) ?? []) {
                result[id, default: []].append(channel)
                assignments[channel.id] = LiveTVGuideMatch(guideChannelID: id, method: .exactID)
            }
        }
        for channel in channels {
            guard assignments[channel.id] == nil, overrides[channel.id] == nil else { continue }
            let identity = identities[channel.id]
            if let provider, identity?.provider == provider, let id = identity?.nativeID,
               guideChannels[id] != nil {
                result[id, default: []].append(channel)
                assignments[channel.id] = LiveTVGuideMatch(guideChannelID: id, method: .nativeID)
            }
        }

        for guideID in guideChannels.keys {
            if let exact = playlistIDs[guideID] {
                guard shareOneIdentity(exact.map(\.1)) else { continue }
                let available = exact.map(\.1).filter { assignments[$0.id] == nil && overrides[$0.id] == nil }
                result[guideID, default: []].append(contentsOf: available)
                for channel in available {
                    assignments[channel.id] = LiveTVGuideMatch(guideChannelID: guideID, method: .exactID)
                }
                continue
            }
            if provider == nil, aliasSet == .iptvOrgToEPGShareUS2Version1, let aliasID = verifiedAliases.first(where: {
                $0.value == guideID
            })?.key,
               let aliases = playlistIDs[aliasID] {
                let available = aliases.map(\.1).filter {
                    assignments[$0.id] == nil && overrides[$0.id] == nil && identities[$0.id]?.provider == nil
                }
                result[guideID, default: []].append(contentsOf: available)
                for channel in available {
                    assignments[channel.id] = LiveTVGuideMatch(guideChannelID: guideID, method: .verifiedAlias)
                }
            }
        }

        let matchedIDs = Set(result.values.flatMap { $0.map(\.id) })
        let unmatched = channels.filter {
            let identity = identities[$0.id]
            return !matchedIDs.contains($0.id) && overrides[$0.id] == nil
                && identity?.nativeID == nil && identity?.provider == provider
        }
        let playlistNames = Dictionary(
            grouping: unmatched,
            by: { normalizedDisplayName($0.guideName ?? $0.name) }
        )
        var guideNames: [String: [(id: String, name: String)]] = [:]
        for (guideID, names) in guideChannels where result[guideID] == nil {
            for name in names {
                guideNames[normalizedDisplayName(name), default: []]
                    .append((guideID, name))
            }
        }

        var candidates: [String: [LiveTVPrototypeChannel]] = [:]
        for (normalized, playlistMatches) in playlistNames {
            guard !normalized.isEmpty, shareOneIdentity(playlistMatches),
                  let guideMatches = guideNames[normalized],
                  Set(guideMatches.map(\.id)).count == 1,
                  let guide = guideMatches.first,
                  playlistMatches.allSatisfy({ channel in
                      hasIndependentIdentityEvidence(channel: channel, guideID: guide.id, guideName: guide.name)
                          && sourceRegionsAreCompatible(channel.guideID, guide.id)
                          && affiliateCallSignsAreCompatible(
                              playlistID: channel.guideID, playlistName: channel.name,
                              guideID: guide.id, guideName: guide.name
                          )
                          && feedQualifiersAreCompatible(
                              playlistID: channel.guideID, playlistName: channel.name,
                              guideID: guide.id, guideName: guide.name
                          )
                  })
            else { continue }
            candidates[guide.id, default: []].append(contentsOf: playlistMatches)
        }
        for (guideID, channels) in candidates where shareOneIdentity(channels) {
            result[guideID] = channels.sorted { $0.id < $1.id }
            for channel in channels {
                assignments[channel.id] = LiveTVGuideMatch(
                    guideChannelID: guideID, method: provider == nil ? .displayName : .providerName
                )
            }
        }
        return (result.filter { !$0.value.isEmpty }, assignments)
    }

    private func shareOneIdentity(_ channels: [LiveTVPrototypeChannel]) -> Bool {
        guard !channels.isEmpty else { return false }
        guard channels.count != 1 else { return true }
        guard let guideID = channels.first?.guideID, !guideID.isEmpty else { return false }
        func variantName(_ channel: LiveTVPrototypeChannel) -> String {
            normalizedDisplayName(channel.guideName ?? channel.name).replacingOccurrences(
                of: #"\s+(?:uhd|fhd|hd|sd)$"#, with: "", options: .regularExpression
            )
        }
        guard let first = channels.first else { return false }
        return channels.allSatisfy {
            $0.guideID == guideID && variantName($0) == variantName(first)
                && $0.country == first.country
        }
    }

    private func hasIndependentIdentityEvidence(
        channel: LiveTVPrototypeChannel, guideID: String, guideName: String
    ) -> Bool {
        if let callSign = affiliateCallSign(in: channel.guideID ?? ""),
           callSign == affiliateCallSign(in: guideID) { return true }
        if let region = sourceRegion(in: channel.guideID),
           region == sourceRegion(in: guideID),
           let playlistID = channel.guideID {
            func station(_ value: String) -> String {
                value.replacingOccurrences(
                    of: #"\.[A-Za-z]{2}(?:\d+)?(?:@.*)?$"#, with: "", options: .regularExpression
                ).lowercased().filter { $0.isLetter || $0.isNumber }
            }
            return !station(playlistID).isEmpty && station(playlistID) == station(guideID)
        }
        return false
    }

    public func normalizedDisplayName(_ input: String) -> String {
        let folded = input.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s*\[(?:not 24/7|geo-blocked|offline)\]\s*$"#,
                with: "", options: .regularExpression
            )
        let suffixPattern = #"\s*\((?:2160p|1080p|720p|576p|480p|360p|240p|UHD|FHD|HD|SD)\)\s*$"#
        let range = NSRange(folded.startIndex..., in: folded)
        let stripped: String
        if let expression = try? NSRegularExpression(
            pattern: suffixPattern,
            options: [.caseInsensitive]
        ) {
            stripped = expression.stringByReplacingMatches(
                in: folded, range: range, withTemplate: ""
            )
        } else {
            stripped = folded
        }
        return stripped.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private let verifiedAliases: [String: String] = [
        "DareToDreamNetwork.us@SD": "3ABN.Dare.to.Dream.Network.us2",
        "3ABNEnglish.us@SD": "3ABN.us2",
        "3ABNKids.us@SD": "3ABN.Kids.Network.us2",
        "3ABNLatino.us@SD": "3ABN.Latino.Network.us2",
        "3ABNPraiseHimMusicNetwork.us@SD": "3ABN.Praise.Him.Music.us2",
        "3ABNProclaimNetwork.us@SD": "3ABN.Proclaim.Network.us2",
    ]

    private func sourceRegionsAreCompatible(_ playlistID: String?, _ guideID: String) -> Bool {
        guard let playlistRegion = sourceRegion(in: playlistID),
              let guideRegion = sourceRegion(in: guideID)
        else { return true }
        return playlistRegion == guideRegion
    }

    private func sourceRegion(in identifier: String?) -> String? {
        guard let identifier else { return nil }
        let pattern = #"\.([A-Za-z]{2})(?:\d+)?(?:@|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: identifier,
                range: NSRange(identifier.startIndex..., in: identifier)
              ),
              let range = Range(match.range(at: 1), in: identifier)
        else { return nil }
        return identifier[range].lowercased()
    }

    private func feedQualifiersAreCompatible(
        playlistID: String?,
        playlistName: String,
        guideID: String,
        guideName: String
    ) -> Bool {
        if let playlistID,
           feedQualifiers(in: playlistID) != feedQualifiers(in: guideID) {
            return false
        }
        let playlist = feedQualifiers(in: "\(playlistID ?? "") \(playlistName)")
        let guide = feedQualifiers(in: "\(guideID) \(guideName)")
        return playlist == guide
    }

    private func feedQualifiers(in text: String) -> Set<String> {
        let lower = text.lowercased()
        let words = ["east", "west", "pacific", "mountain", "central", "alaska", "hawaii"]
        var result = Set(words.filter { word in
            lower.range(
                of: #"(?<![a-z])\#(word)(?![a-z])"#,
                options: .regularExpression
            ) != nil
        })
        for offset in 1...3 where lower.contains("+\(offset)") {
            result.insert("+\(offset)")
        }
        return result
    }

    private func affiliateCallSignsAreCompatible(
        playlistID: String?,
        playlistName: String,
        guideID: String,
        guideName: String
    ) -> Bool {
        let playlist = affiliateCallSign(in: "\(playlistID ?? "") \(playlistName)")
        let guide = affiliateCallSign(in: "\(guideID) \(guideName)")
        switch (playlist, guide) {
        case (nil, nil):
            return true
        case let (playlist?, guide?):
            return playlist == guide
        default:
            return false
        }
    }

    private func affiliateCallSign(in text: String) -> String? {
        let upper = text.uppercased()
        let pattern = #"(?<![A-Z])([KW][A-Z]{3})(?![A-Z])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: upper,
                range: NSRange(upper.startIndex..., in: upper)
              ),
              let range = Range(match.range(at: 1), in: upper)
        else { return nil }
        return String(upper[range])
    }
}

/// Opt-in, versioned aliases for one verified playlist/guide pair. Generic user
/// playlists never inherit aliases merely because a station name resembles one.
public enum LiveTVGuideAliasSet: Equatable, Sendable {
    case iptvOrgToEPGShareUS2Version1
}
#endif
