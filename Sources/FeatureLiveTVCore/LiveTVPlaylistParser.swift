#if DEBUG
import CryptoKit
import Foundation

public struct LiveTVPlaylistImport: Codable, Sendable {
    public let channels: [LiveTVPrototypeChannel]
    public let entryCount: Int
    public let skippedEntryCount: Int
    public let declaredGuideURLs: [URL]
    public let permitsPersistence: Bool
    public let originURL: URL?

    public init(
        channels: [LiveTVPrototypeChannel],
        entryCount: Int,
        skippedEntryCount: Int,
        declaredGuideURLs: [URL] = [],
        permitsPersistence: Bool = true, originURL: URL? = nil
    ) {
        self.channels = channels
        self.entryCount = entryCount
        self.skippedEntryCount = skippedEntryCount
        self.declaredGuideURLs = declaredGuideURLs
        self.permitsPersistence = permitsPersistence
        self.originURL = originURL
    }
}

public enum LiveTVSourceImportError: Error, Equatable, Sendable {
    case cancelled
    case downloadFailed
    case invalidResponse
    case responseTooLarge
    case invalidPlaylist
    case streamManifest
    case invalidGuide
    case guideTooLarge
    case cacheFailed
    case unsafeGuideOrigin
    case guideWithoutPlaylist
    case authenticationRequired, temporarilyUnavailable, tooManyRequests, redirectBlocked

    public var userDescription: LocalizedStringResource {
        switch self {
        case .cancelled:
            "The Live TV import was cancelled."
        case .downloadFailed:
            "Plozz couldn't download the Live TV source."
        case .invalidResponse:
            "The Live TV source returned an invalid response."
        case .responseTooLarge:
            "The Live TV playlist is too large to import safely."
        case .invalidPlaylist:
            "The Live TV playlist isn't a supported M3U file."
        case .streamManifest:
            "This link is a video stream, not a channel playlist. Use your provider's M3U channel-list link."
        case .invalidGuide:
            "The Live TV guide isn't a supported XMLTV file."
        case .guideTooLarge:
            "The Live TV guide is too large to import safely."
        case .cacheFailed:
            "Your saved Live TV catalog couldn't be updated. The previous catalog has been kept."
        case .unsafeGuideOrigin:
            "This playlist declares a guide on another origin. Add that guide address explicitly in Sources to allow it."
        case .guideWithoutPlaylist:
            "This address contains a programme guide, not playable channels. Add it to an existing playlist's guide sources."
        case .authenticationRequired:
            "This source rejected access. Check its address or credentials in Sources."
        case .temporarilyUnavailable:
            "This source is temporarily unavailable. Previously loaded channels and listings have been kept."
        case .tooManyRequests:
            "This source is limiting requests. Wait before refreshing again."
        case .redirectBlocked:
            "This source redirects outside its allowed origin. Add the destination address explicitly if you trust it."
        }
    }

    public var errorDescription: LocalizedStringResource {
        userDescription
    }
}

public struct LiveTVPlaylistParser: Sendable {
    public static let maximumBytes = 20 * 1_024 * 1_024
    public static let maximumEntries = 100_000
    public static let maximumLineBytes = 64 * 1_024
    private static let darkLogoURLs = Set(
        LiveTVPrototypeCatalog.channels.filter(\.logoNeedsDarkBackground).compactMap(\.logoURL)
    )

    private let baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    public func parse(_ data: Data) throws -> LiveTVPlaylistImport {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else {
            throw LiveTVSourceImportError.responseTooLarge
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        return try parse(text)
    }

    public func parse(_ text: String) throws -> LiveTVPlaylistImport {
        guard text.utf8.count <= Self.maximumBytes else {
            throw LiveTVSourceImportError.responseTooLarge
        }
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let rawLines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        )
        guard let firstContentLine = rawLines.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), firstContentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("#EXTM3U")
        else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        guard !rawLines.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXT-X-")
        }) else {
            throw LiveTVSourceImportError.streamManifest
        }

        var channels: [LiveTVPrototypeChannel] = []
        var pending: PendingEntry?
        var entryCount = 0
        var skippedEntryCount = 0
        var fallbackNumber = 0
        var importedIDs = Set<String>()
        guard firstContentLine.utf8.count <= Self.maximumLineBytes else {
            throw LiveTVSourceImportError.responseTooLarge
        }
        let header = firstContentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerAttributes = parseAttributes(String(header.dropFirst("#EXTM3U".count)))
        var declaredGuideURLs: [URL] = []
        for key in ["url-tvg", "x-tvg-url"] {
            for address in (headerAttributes[key] ?? "").split(separator: ",") {
                if let url = supportedURL(
                    address.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL
                ), !declaredGuideURLs.contains(url) {
                    guard declaredGuideURLs.count < 32 else {
                        throw LiveTVSourceImportError.responseTooLarge
                    }
                    declaredGuideURLs.append(url)
                }
            }
        }

        for (index, rawLine) in rawLines.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard rawLine.utf8.count <= Self.maximumLineBytes else {
                if rawLine.hasPrefix("#EXTINF:") {
                    entryCount += 1
                    skippedEntryCount += 1
                    guard entryCount <= Self.maximumEntries else {
                        throw LiveTVSourceImportError.responseTooLarge
                    }
                }
                if pending != nil {
                    skippedEntryCount += 1
                    pending = nil
                }
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF:") {
                if pending != nil {
                    skippedEntryCount += 1
                }
                entryCount += 1
                guard entryCount <= Self.maximumEntries else {
                    throw LiveTVSourceImportError.responseTooLarge
                }
                pending = parseEXTINF(line)
                if pending == nil {
                    skippedEntryCount += 1
                }
                continue
            }

            if line.hasPrefix("#EXTVLCOPT:") {
                guard var entry = pending,
                      let header = parseVLCOption(line)
                else { continue }
                entry.headers[header.name] = header.value
                pending = entry
                continue
            }

            guard !line.hasPrefix("#"), let entry = pending else { continue }
            pending = nil
            guard let streamURL = supportedURL(line, relativeTo: baseURL) else {
                skippedEntryCount += 1
                continue
            }

            fallbackNumber += 1
            let number = validChannelNumber(entry.attributes["tvg-chno"])
                ?? fallbackNumber
            let tvgID = clean(entry.attributes["tvg-id"])
            let logoURL = clean(entry.attributes["tvg-logo"])
                .flatMap { supportedURL($0, relativeTo: baseURL) }
            let groups = categoryNames(from: entry.attributes["group-title"])
            let category = groups.first ?? "Other"
            let groupDescription = groups.isEmpty
                ? "Other"
                : groups.joined(separator: " • ")
            let guideName = clean(entry.attributes["tvg-name"])
            let digestInput = [
                tvgID ?? "",
                entry.name,
                streamURL.absoluteString,
            ].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(digestInput.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let channelID = "iptv-\(digest)"
            guard importedIDs.insert(channelID).inserted else {
                skippedEntryCount += 1
                continue
            }

            channels.append(
                LiveTVPrototypeChannel(
                    id: channelID,
                    number: number,
                    name: entry.name,
                    category: category,
                    symbol: symbol(for: groupDescription),
                    accent: accent(for: digest),
                    source: .iptv,
                    tagline: groupDescription,
                    logoURL: logoURL,
                    streamURL: streamURL,
                    logoNeedsDarkBackground: logoURL.map(Self.darkLogoURLs.contains) ?? false,
                    guideID: tvgID,
                    guideName: guideName,
                    httpHeaders: entry.headers,
                    language: clean(entry.attributes["tvg-language"]),
                    country: clean(entry.attributes["tvg-country"]), groups: groups
                )
            )
        }

        if pending != nil {
            skippedEntryCount += 1
        }
        guard entryCount > 0 else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        return LiveTVPlaylistImport(
            channels: channels,
            entryCount: entryCount,
            skippedEntryCount: skippedEntryCount,
            declaredGuideURLs: declaredGuideURLs, originURL: baseURL
        )
    }

    private struct PendingEntry {
        let name: String
        let attributes: [String: String]
        var headers: [String: String] = [:]
    }

    private func parseEXTINF(_ line: String) -> PendingEntry? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let payload = line[line.index(after: colon)...]
        guard let comma = firstUnquotedComma(in: payload) else { return nil }
        let metadata = payload[..<comma]
        let rawName = payload[payload.index(after: comma)...]
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 1_024 else { return nil }
        return PendingEntry(
            name: name,
            attributes: parseAttributes(String(metadata))
        )
    }

    private func firstUnquotedComma(in text: Substring) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if (character == "\"" || character == "'") && !escaped {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            }
            if character == "," && quote == nil {
                return index
            }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
        }
        return nil
    }

    private func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            let keyStart = index
            while index < text.endIndex,
                  text[index] != "=",
                  !text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard keyStart < index else { break }
            let key = text[keyStart..<index].lowercased()
            let keyEnd = index
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "=" else {
                // A bare duration/token must not consume the attribute after it.
                index = keyEnd
                continue
            }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var value = ""
            if text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                while index < text.endIndex, text[index] != quote {
                    if text[index] == "\\" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == quote || text[next] == "\\" {
                            index = next
                        }
                    }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            if value.count <= 8_192 {
                result[key] = value
            }
        }
        return result
    }

    private func parseVLCOption(_ line: String) -> (name: String, value: String)? {
        let prefix = "#EXTVLCOPT:"
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let keyStart = line.index(line.startIndex, offsetBy: prefix.count)
        let key = line[keyStart..<separator].lowercased()
        let value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4_096 else { return nil }
        switch key {
        case "http-referrer", "http-referer":
            guard let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host != nil,
                  url.user == nil,
                  url.password == nil
            else { return nil }
            return ("Referer", value)
        case "http-user-agent":
            guard !value.contains("\r"), !value.contains("\n") else { return nil }
            return ("User-Agent", value)
        default:
            return nil
        }
    }

    private func supportedURL(_ text: String, relativeTo baseURL: URL?) -> URL? {
        guard text.count <= 16_384,
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private func validChannelNumber(_ text: String?) -> Int? {
        guard let text, let number = Int(text), number > 0 else { return nil }
        return number
    }

    private func categoryNames(from value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.split(separator: ";").compactMap { component in
            let category = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty,
                  category.count <= 256,
                  seen.insert(category.lowercased()).inserted
            else { return nil }
            return category
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else { return nil }
        return cleaned
    }

    private func accent(for digest: String) -> Int {
        Int(digest.prefix(2), radix: 16).map { $0 % 6 } ?? 0
    }

    private func symbol(for group: String) -> String {
        let lower = group.lowercased()
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("music") { return "music.note" }
        if lower.contains("kids") || lower.contains("animation") {
            return "sparkles.tv.fill"
        }
        if lower.contains("relig") { return "building.columns.fill" }
        return "tv.fill"
    }
}
#endif
