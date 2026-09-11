#if DEBUG
import Foundation

public enum LiveTVGuideSection: String, Hashable, Sendable {
    case recent, favorites, channels
}

public struct LiveTVGuideRowID: Hashable, Sendable {
    public let channelID: String
    public let section: LiveTVGuideSection

    public init(channelID: String, section: LiveTVGuideSection = .channels) {
        self.channelID = channelID
        self.section = section
    }
}

public struct LiveTVGuideChannel: Identifiable, Equatable, Sendable {
    public let channel: LiveTVPrototypeChannel
    public let section: LiveTVGuideSection
    public let startsSection: Bool
    public var id: LiveTVGuideRowID { LiveTVGuideRowID(channelID: channel.id, section: section) }
}

/// Keep transport order stable while successful watching reorders Recents.
public struct LiveTVChannelSequence {
    private let ids: [String]

    public init(channels: [LiveTVPrototypeChannel]) {
        var seen = Set<String>()
        ids = channels.map(\.id).filter { seen.insert($0).inserted }
    }

    public func neighbor(
        of channelID: String?, offset: Int, visibleChannels: [LiveTVPrototypeChannel]
    ) -> String? {
        let visible = Set(visibleChannels.map(\.id))
        let available = ids.filter { visible.contains($0) }
        guard let channelID, let index = available.firstIndex(of: channelID) else { return nil }
        let step = offset % available.count
        return available[(index + step + available.count) % available.count]
    }
}
#endif
