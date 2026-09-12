import Foundation

struct JellyfinLiveTVInfo: Decodable, Sendable {
    struct Service: Decodable, Sendable {
        let Status: String?
    }
    let IsEnabled: Bool?
    let EnabledUsers: [String]?
    let Services: [Service]?
}

struct JellyfinLiveTVPage: Decodable, Sendable {
    let Items: [JellyfinLiveTVItem]
    let TotalRecordCount: Int?
}

struct JellyfinLiveTVItem: Decodable, Sendable {
    let Id: String?
    let Name: String?
    let ChannelId: String?
    let ChannelNumber: String?
    let ChannelType: String?
    let ImageTags: [String: String]?
    let CurrentProgram: JellyfinLiveTVProgrammeDTO?
    let StartDate: String?
    let EndDate: String?
    let Overview: String?
    let EpisodeTitle: String?
    let Genres: [String]?
}

struct JellyfinLiveTVProgrammeDTO: Decodable, Sendable {
    let Id: String?
    let Name: String?
    let ChannelId: String?
    let StartDate: String?
    let EndDate: String?
    let Overview: String?
    let EpisodeTitle: String?
    let Genres: [String]?
}

struct JellyfinLiveTVPlaybackResponse: Decodable, Sendable {
    let MediaSources: [JellyfinLiveTVMediaSource]?
    let PlaySessionId: String?
    let ErrorCode: String?
}

struct JellyfinLiveTVOpenResponse: Decodable, Sendable {
    let MediaSource: JellyfinLiveTVMediaSource
}

struct JellyfinLiveTVMediaSource: Decodable, Sendable {
    struct Stream: Decodable, Sendable {
        let `Type`: String?
    }
    let Id: String?
    let Container: String?
    let TranscodingUrl: String?
    let TranscodingSubProtocol: String?
    let SupportsDirectPlay: Bool?
    let SupportsDirectStream: Bool?
    let RequiresOpening: Bool?
    let OpenToken: String?
    let LiveStreamId: String?
    let MediaStreams: [Stream]?
}

enum JellyfinLiveTVOpenItemID: Encodable, Sendable {
    case string(String)
    case integer(Int64)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }
}

struct JellyfinLiveTVOpenBody: Encodable {
    let OpenToken: String
    let UserId: String
    let ItemId: JellyfinLiveTVOpenItemID
    let PlaySessionId: String?
    let MaxStreamingBitrate: Int
    let DeviceProfile: JellyfinCapabilityProfile
    let EnableDirectPlay = true
    let EnableDirectStream = true
}

struct JellyfinLiveTVProgressBody: Encodable, Sendable {
    let ItemId: String
    let MediaSourceId: String?
    let LiveStreamId: String?
    let PlaySessionId: String?
    let PositionTicks: Int64
    let IsPaused: Bool
    let CanSeek = false
}
