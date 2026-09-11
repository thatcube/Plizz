import Foundation

/// A stable playlist identity. Addresses can contain credentials and belong only in secure storage.
public struct LiveTVPlaylistSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var playlistURL: URL
    public var guideURLs: [URL] {
        didSet {
            let oldIDs = guideSourceIDs
            guideSourceIDs = guideURLs.enumerated().map { index, url in
                if let previous = oldValue.firstIndex(of: url), oldIDs.indices.contains(previous) {
                    return oldIDs[previous]
                }
                if oldValue.count == guideURLs.count, oldIDs.indices.contains(index),
                   !guideURLs.contains(oldValue[index]),
                   Self.guideURLsShareIdentity(url, oldValue[index]) { return oldIDs[index] }
                return UUID().uuidString
            }
        }
    }
    public var guideSourceIDs: [String]
    public var discoversPlaylistGuides: Bool
    public var guideLookbackDays: Int
    public var guideLookaheadDays: Int
    public var isEnabled: Bool
    public var importedPlaylistID: UUID? {
        guard playlistURL.scheme == "plozz-playlist", playlistURL.user == nil,
              playlistURL.password == nil, playlistURL.port == nil,
              playlistURL.query == nil, playlistURL.fragment == nil,
              playlistURL.path.isEmpty, let host = playlistURL.host,
              let uuid = UUID(uuidString: host), uuid.uuidString.lowercased() == id.lowercased() else { return nil }
        return uuid
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        playlistURL: URL,
        guideURLs: [URL] = [],
        isEnabled: Bool = true,
        guideSourceIDs: [String]? = nil,
        discoversPlaylistGuides: Bool = true,
        guideLookbackDays: Int = 1, guideLookaheadDays: Int = 7
    ) {
        self.id = id
        self.name = name
        self.playlistURL = playlistURL
        self.guideURLs = guideURLs
        self.isEnabled = isEnabled
        self.guideSourceIDs = guideSourceIDs ?? guideURLs.indices.map { "\(id).guide.\($0)" }
        self.discoversPlaylistGuides = discoversPlaylistGuides
        self.guideLookbackDays = guideLookbackDays
        self.guideLookaheadDays = guideLookaheadDays
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, playlistURL, guideURLs, isEnabled, guideSourceIDs
        case discoversPlaylistGuides, guideLookbackDays, guideLookaheadDays
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        playlistURL = try values.decode(URL.self, forKey: .playlistURL)
        guideURLs = try values.decodeIfPresent([URL].self, forKey: .guideURLs) ?? []
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let sourceID = id
        let sourceGuideURLs = guideURLs
        guideSourceIDs = try values.decodeIfPresent([String].self, forKey: .guideSourceIDs)
            ?? sourceGuideURLs.indices.map { "\(sourceID).guide.\($0)" }
        discoversPlaylistGuides = try values.decodeIfPresent(Bool.self, forKey: .discoversPlaylistGuides) ?? true
        guideLookbackDays = try values.decodeIfPresent(Int.self, forKey: .guideLookbackDays) ?? 1
        guideLookaheadDays = try values.decodeIfPresent(Int.self, forKey: .guideLookaheadDays) ?? 7
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
              }) else { throw LiveTVSourcesValidationError.invalidSourceID }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 512 else { throw LiveTVSourcesValidationError.invalidName }
        guard Self.isSupportedURL(playlistURL) || importedPlaylistID != nil else {
            throw LiveTVSourcesValidationError.invalidPlaylistURL
        }
        guard guideURLs.count <= 32, Set(guideURLs).count == guideURLs.count,
              guideSourceIDs.count == guideURLs.count, Set(guideSourceIDs).count == guideSourceIDs.count,
              guideSourceIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 180
                  && $0.unicodeScalars.allSatisfy {
                      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
                  }
              }), (0...7).contains(guideLookbackDays), (1...28).contains(guideLookaheadDays) else {
            throw LiveTVSourcesValidationError.invalidGuideSources
        }
        guard guideURLs.allSatisfy(Self.isSupportedURL) else {
            throw LiveTVSourcesValidationError.invalidGuideURL
        }
    }

    public static func isSupportedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    public static func sourceURL(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isSupportedURL(url) else { return nil }
        return url
    }

    public static func guideURLsShareIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        func stableAddress(_ url: URL) -> URL? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            let credentials: Set<String> = [
                "token", "access_token", "auth", "authorization", "expires", "expiry", "exp",
                "signature", "sig", "policy", "key-pair-id", "hdnts", "hdnea", "jwt"
            ]
            let query = components.queryItems?.filter { !credentials.contains($0.name.lowercased()) }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components.queryItems = query?.isEmpty == true ? nil : query
            components.fragment = nil
            return components.url
        }
        guard let first = stableAddress(lhs), let second = stableAddress(rhs) else { return false }
        return first == second
    }
}

public struct LiveTVServerSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var accountID: String
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString, name: String, accountID: String, isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, accountID, isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        accountID = try values.decode(String.self, forKey: .accountID)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
              }) else { throw LiveTVSourcesValidationError.invalidSourceID }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 512 else { throw LiveTVSourcesValidationError.invalidName }
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveTVSourcesValidationError.invalidAccountReference
        }
    }
}

public struct LiveTVSourcesConfiguration: Codable, Equatable, Sendable {
    public static let empty = LiveTVSourcesConfiguration()
    public var playlists: [LiveTVPlaylistSource]
    public var servers: [LiveTVServerSource]

    public init(playlists: [LiveTVPlaylistSource] = [], servers: [LiveTVServerSource] = []) {
        self.playlists = playlists
        self.servers = servers
    }

    private enum CodingKeys: String, CodingKey {
        case version, playlists, servers
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw LiveTVSourcesStoreError.unsupportedVersion }
        playlists = try values.decode([LiveTVPlaylistSource].self, forKey: .playlists)
        servers = try values.decodeIfPresent([LiveTVServerSource].self, forKey: .servers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(playlists, forKey: .playlists)
        try values.encode(servers, forKey: .servers)
    }

    public func validate() throws {
        let ids = playlists.map(\.id) + servers.map(\.id)
        guard ids.count <= 100 else { throw LiveTVSourcesValidationError.tooManySources }
        guard Set(ids).count == ids.count else {
            throw LiveTVSourcesValidationError.duplicateSourceID
        }
        let importedIDs = playlists.compactMap(\.importedPlaylistID)
        guard Set(importedIDs).count == importedIDs.count else {
            throw LiveTVSourcesValidationError.duplicateSourceID
        }
        let guideIDs = playlists.flatMap(\.guideSourceIDs)
        guard Set(guideIDs).count == guideIDs.count else {
            throw LiveTVSourcesValidationError.invalidGuideSources
        }
        for source in playlists { try source.validate() }
        for source in servers { try source.validate() }
    }
}

public enum LiveTVSourcesValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidSourceID, duplicateSourceID, invalidName, invalidPlaylistURL
    case invalidGuideURL, invalidGuideSources, tooManySources, invalidAccountReference

    public var errorDescription: String? {
        switch self {
        case .invalidSourceID, .duplicateSourceID: "Each Live TV source needs a unique source identifier."
        case .invalidName: "Enter a name for this Live TV source."
        case .invalidPlaylistURL: "Enter an HTTP or HTTPS playlist address without a username or password in the host."
        case .invalidGuideURL: "Enter an HTTP or HTTPS guide address without a username or password in the host."
        case .invalidGuideSources: "Use up to 32 different guide addresses for each playlist."
        case .tooManySources: "Use up to 100 Live TV sources."
        case .invalidAccountReference: "Choose an account for this Live TV server."
        }
    }
}
