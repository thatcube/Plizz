#if DEBUG
import Foundation

public enum LiveTVGuideProvider: String, Codable, Sendable {
    case pluto, samsung, plex
}

public struct LiveTVGuideSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let provider: LiveTVGuideProvider?

    public init(id: String, name: String, url: URL, provider: LiveTVGuideProvider? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.provider = provider
    }

    static let us2 = LiveTVGuideSource(
        id: "us2", name: "EPGShare US2",
        url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz")!
    )
    // Recognition metadata for explicitly supplied guides, never a source selection.
    static let recognizedSources: [LiveTVGuideSource] = [
        LiveTVGuideSource(
            id: "pluto-us", name: "Pluto TV US", url: URL(string: "https://i.mjh.nz/PlutoTV/us.xml.gz")!,
            provider: .pluto
        ),
        LiveTVGuideSource(
            id: "samsung-us", name: "Samsung TV Plus US",
            url: URL(string: "https://i.mjh.nz/SamsungTVPlus/us.xml.gz")!, provider: .samsung
        ),
        LiveTVGuideSource(
            id: "plex-us", name: "Plex US", url: URL(string: "https://i.mjh.nz/Plex/us.xml.gz")!,
            provider: .plex
        ),
        .us2,
        LiveTVGuideSource(
            id: "plex-share", name: "EPGShare Plex",
            url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_PLEX1.xml.gz")!, provider: .plex
        )
    ]

    public static func provider(for url: URL) -> LiveTVGuideProvider? {
        recognizedSources.first { $0.url == url }?.provider
    }
}

public enum LiveTVGuideMatchMethod: Int, Codable, Comparable, Sendable {
    case displayName, providerName, verifiedAlias, nativeID, exactID, userConfirmed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LiveTVGuideMatch: Codable, Equatable, Sendable {
    public let guideChannelID: String
    public let method: LiveTVGuideMatchMethod

    public init(guideChannelID: String, method: LiveTVGuideMatchMethod) {
        self.guideChannelID = guideChannelID
        self.method = method
    }
}

struct LiveTVStreamIdentity {
    let provider: LiveTVGuideProvider?
    let nativeID: String?
    let region: String?

    init(url: URL?) {
        let host = url?.host?.lowercased() ?? ""
        let path = url?.path ?? ""
        if host == "jmp2.uk", let id = Self.capture(#"^/plu-([a-fA-F0-9]{24})\.m3u8$"#, in: path) {
            provider = .pluto
            nativeID = id.lowercased()
            region = nil
        } else if host == "pluto.tv" || host.hasSuffix(".pluto.tv") {
            provider = .pluto
            nativeID = Self.capture(#"/channel/([a-fA-F0-9]{24})(?:/|$)"#, in: path)?.lowercased()
            region = nil
        } else {
            let locator = "\(host)\(path)".lowercased()
            let knownDistributor = host.hasSuffix(".amagi.tv") || host.hasSuffix(".wurl.tv")
                || host.hasSuffix(".frequency.stream") || host == "plex.tv" || host.hasSuffix(".plex.tv")
            if knownDistributor, locator.contains("samsung") {
                provider = .samsung
                nativeID = nil
                let code = Self.capture(#"samsung[-_]?([a-z]{2})(?:[^a-z]|$)"#, in: locator)
                    ?? Self.capture(#"[-.]([a-z]{2})\.samsung\.wurl\.tv"#, in: host)
                region = code == "uk" ? "gb" : code
            } else if knownDistributor, locator.range(of: #"(^|[^a-z])plex([^a-z]|$)"#, options: .regularExpression) != nil {
                provider = .plex
                nativeID = nil
                region = Self.capture(#"plex[-_]([a-z]{2})(?:[^a-z]|$)"#, in: locator)
            } else {
                provider = nil
                nativeID = nil
                region = nil
            }
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
#endif
