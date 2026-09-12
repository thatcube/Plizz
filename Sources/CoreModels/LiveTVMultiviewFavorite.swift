import Foundation

public enum LiveTVMultiviewLayout: String, Codable, CaseIterable, Sendable {
    case sideBySide
    case mainAndStack
    case corner

    public var title: LocalizedStringResource {
        switch self {
        case .sideBySide: "Grid"
        case .mainAndStack: "Main and stack"
        case .corner: "Corner"
        }
    }
}

public enum LiveTVMultiviewCorner: String, Codable, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    public var title: LocalizedStringResource {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }
}

public enum LiveTVMultiviewInsetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var fraction: Double {
        switch self {
        case .small: 0.25
        case .medium: 0.32
        case .large: 0.40
        }
    }

    public var title: LocalizedStringResource {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// A profile-local composition, not a playback session. Channel IDs are in
/// display order, with the main picture first; no URLs, credentials or leases.
public struct LiveTVMultiviewFavorite: Codable, Equatable, Identifiable, Sendable {
    public static let maximumChannelCount = 4
    public let id: String
    public let name: String
    public let channelIDs: [String]
    public let layout: LiveTVMultiviewLayout
    public let corner: LiveTVMultiviewCorner
    public let insetSize: LiveTVMultiviewInsetSize

    public init(
        id: String = UUID().uuidString, name: String, channelIDs: [String],
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner = .bottomTrailing,
        insetSize: LiveTVMultiviewInsetSize = .medium
    ) {
        self.id = id
        self.name = name
        self.channelIDs = channelIDs
        self.layout = layout
        self.corner = corner
        self.insetSize = insetSize
    }

    public var isValid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...Self.maximumChannelCount).contains(channelIDs.count)
            && channelIDs.allSatisfy { !$0.isEmpty }
            && Set(channelIDs).count == channelIDs.count
    }

    public func migratingChannelIDs(_ migration: [String: String]) -> Self {
        var seen: Set<String> = []
        let ids = channelIDs.map { migration[$0] ?? $0 }.filter { seen.insert($0).inserted }
        return Self(id: id, name: name, channelIDs: ids, layout: layout, corner: corner, insetSize: insetSize)
    }
}
