import Foundation
import CoreModels

struct PlexLiveTVScalar: Decodable, Sendable {
    let string: String

    var integer: Int? { Int(string) }
    var number: Double? { Double(string).flatMap { $0.isFinite ? $0 : nil } }
    var boolean: Bool? {
        switch string.lowercased() {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { string = text }
        else if let integer = try? value.decode(Int64.self) { string = String(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { string = String(number) }
        else if let flag = try? value.decode(Bool.self) { string = flag ? "1" : "0" }
        else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected scalar")
        }
    }
}

struct PlexLiveTVResponse: Decodable, Sendable {
    let MediaContainer: PlexLiveTVContainer
}

struct PlexLiveTVContainer: Decodable, Sendable {
    let size: PlexLiveTVScalar?
    let totalSize: PlexLiveTVScalar?
    let MediaProvider: [PlexLiveTVMediaProviderDTO]?
    let DVR: [PlexLiveTVDVRDTO]?
    let Dvr: [PlexLiveTVDVRDTO]?
    let Channel: [PlexLiveTVChannelDTO]?
    let Metadata: [PlexLiveTVProgrammeDTO]?
    let allowTuners: PlexLiveTVScalar?
}

struct PlexLiveTVMediaProviderDTO: Decodable, Sendable {
    struct FeatureDTO: Decodable, Sendable {
        let type: String?
        let key: String?
    }
    let identifier: String?
    let parentID: PlexLiveTVScalar?
    let providerIdentifier: String?
    let protocols: String?
    let Feature: [FeatureDTO]?
}

struct PlexLiveTVDVRDTO: Decodable, Sendable {
    let key: PlexLiveTVScalar?
    let uuid: String?
    let lineup: String?
}

struct PlexLiveTVChannelDTO: Decodable, Sendable {
    let id: PlexLiveTVScalar?
    let gridKey: String?
    let vcn: PlexLiveTVScalar?
    let title: String?
    let callSign: String?
    let thumb: String?
}

struct PlexLiveTVProgrammeDTO: Decodable, Sendable {
    struct GenreDTO: Decodable, Sendable {
        let tag: String?
    }
    let ratingKey: PlexLiveTVScalar?
    let key: String?
    let guid: String?
    let title: String?
    let grandparentTitle: String?
    let summary: String?
    let thumb: String?
    let Genre: [GenreDTO]?
    let Media: [PlexLiveTVAiringDTO]?
}

struct PlexLiveTVAiringDTO: Decodable, Sendable {
    let beginsAt: PlexLiveTVScalar?
    let endsAt: PlexLiveTVScalar?
    let duration: PlexLiveTVScalar?
    let channelIdentifier: PlexLiveTVScalar?
    let gridKey: String?
    let `protocol`: String?
}

/// PMS uses both object and array forms under MediaGrabOperation. Only the
/// documented media branches are traversed; unrelated response keys cannot
/// inject a session or a playlist into playback.
struct PlexLiveTVPlaybackDocument: Sendable {
    let sessionPath: String?
    let ratingKey: String?
    let directPlaylist: String?
    let decisionCode: Int?
    let status: Int?

    init(data: Data) throws {
        guard data.count <= 2_097_152,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw AppError.invalidResponse
        }
        var paths: Set<String> = []
        var mediaUUIDs: Set<String> = []
        var ratings: Set<String> = []
        var playlists: Set<String> = []
        func scalar(_ value: Any?) -> String? {
            if let value = value as? String { return value }
            return (value as? NSNumber)?.stringValue
        }
        func visit(_ value: Any, branch: String, depth: Int) throws {
            guard depth < 12 else { throw AppError.invalidResponse }
            if let array = value as? [Any] {
                guard array.count <= 100 else { throw AppError.invalidResponse }
                for node in array { try visit(node, branch: branch, depth: depth + 1) }
            } else if let node = value as? [String: Any] {
                if let key = node["key"] as? String, Self.validSessionPath(key) {
                    paths.insert(key)
                    if let rating = scalar(node["ratingKey"]),
                       !rating.isEmpty, rating.utf8.allSatisfy({ (48...57).contains($0) }) {
                        ratings.insert(rating)
                    }
                }
                if branch == "Media", let uuid = node["uuid"] as? String,
                   Self.validHandle(uuid) {
                    mediaUUIDs.insert(uuid)
                }
                if branch == "Part", node["decision"] as? String == "directplay",
                   let key = node["key"] as? String {
                    playlists.insert(key)
                }
                for child in ["Metadata", "Video", "MediaGrabOperation", "Media", "Part"] {
                    if let childValue = node[child] {
                        try visit(childValue, branch: child, depth: depth + 1)
                    }
                }
            }
        }
        try visit(container, branch: "MediaContainer", depth: 0)
        guard paths.count <= 1, ratings.count <= 1, playlists.count <= 1 else {
            throw AppError.invalidResponse
        }
        if let path = paths.first {
            sessionPath = path
        } else if mediaUUIDs.count == 1, let uuid = mediaUUIDs.first {
            sessionPath = "/livetv/sessions/\(uuid)"
        } else {
            sessionPath = nil
        }
        ratingKey = ratings.first
        directPlaylist = playlists.first
        decisionCode = scalar(container["mdeDecisionCode"]).flatMap(Int.init)
            ?? scalar(container["generalDecisionCode"]).flatMap(Int.init)
        status = scalar(container["status"]).flatMap(Int.init)
    }

    static func validHandle(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 95].contains($0)
        }
    }

    static func validSessionPath(_ value: String) -> Bool {
        let prefix = "/livetv/sessions/"
        return value.hasPrefix(prefix) && validHandle(String(value.dropFirst(prefix.count)))
    }
}
