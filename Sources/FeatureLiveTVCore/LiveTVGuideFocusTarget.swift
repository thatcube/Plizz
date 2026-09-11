#if DEBUG
import Foundation

public enum LiveTVGuideFocusTarget: Hashable, Sendable {
    case channel(String, section: LiveTVGuideSection = .channels)
    case channelContent(String, slotID: String? = nil, section: LiveTVGuideSection = .channels)
    case program(channelID: String, programID: String, section: LiveTVGuideSection = .channels)

    public var channelID: String {
        switch self {
        case .channel(let id, _), .channelContent(let id, _, _), .program(let id, _, _): id
        }
    }

    public var rowID: LiveTVGuideRowID {
        switch self {
        case .channel(let id, let section), .channelContent(let id, _, let section), .program(let id, _, let section):
            LiveTVGuideRowID(channelID: id, section: section)
        }
    }

    @MainActor
    public static func defaultContent(
        in model: LiveTVPrototypeModel, row: LiveTVGuideRowID, from start: Date, hours: Int = 6
    ) -> Self {
        let programs = model.programs(for: row.channelID, from: start, hours: hours)
        guard !programs.isEmpty else { return .channelContent(row.channelID, section: row.section) }
        let slots = LiveTVGuideTimeline.slots(
            programs: programs, from: start, to: start.addingTimeInterval(Double(hours) * 3_600)
        )
        let slot = slots.first { $0.start <= model.now && model.now < $0.end } ?? slots.first
        if let program = slot?.program {
            return .program(channelID: row.channelID, programID: program.id, section: row.section)
        }
        return .channelContent(row.channelID, slotID: slot?.id, section: row.section)
    }

    @MainActor
    public func isAvailable(in model: LiveTVPrototypeModel, from start: Date, hours: Int = 6) -> Bool {
        guard model.guideEntry(for: rowID) != nil else { return false }
        if case .channel = self { return true }
        let programs = model.programs(for: channelID, from: start, hours: hours)
        if case .channelContent(_, nil, _) = self { return programs.isEmpty }
        let slots = LiveTVGuideTimeline.slots(
            programs: programs, from: start, to: start.addingTimeInterval(Double(hours) * 3_600)
        )
        switch self {
        case .channel: return true
        case .channelContent(_, let slotID, _):
            return slots.contains { $0.program == nil && $0.id == slotID }
        case .program(_, let programID, _):
            return slots.contains { $0.program?.id == programID }
        }
    }

    public static func rowAfterHiding(
        _ row: LiveTVGuideRowID, in rows: [LiveTVGuideChannel]
    ) -> LiveTVGuideRowID? {
        guard let index = rows.firstIndex(where: { $0.id == row }) else {
            return rows.first { $0.channel.id != row.channelID }?.id
        }
        return rows.dropFirst(index + 1).first { $0.channel.id != row.channelID }?.id
            ?? rows.prefix(index).last { $0.channel.id != row.channelID }?.id
    }

    @MainActor
    public static func returningToPlayback(
        in model: LiveTVPrototypeModel, selectedChannelID: String?,
        originRow: LiveTVGuideRowID? = nil, from start: Date? = nil, hours: Int = 6
    ) -> Self? {
        let candidates = [model.playingChannelID, selectedChannelID, model.guideChannels.first?.channel.id]
        guard let id = candidates.compactMap({ $0 }).first(where: { id in
            model.visibleChannels.contains { $0.id == id }
        }), let row = model.guideRow(for: id, preferring: originRow?.section) else { return nil }
        let currentStart = Date(timeIntervalSince1970: floor(model.now.timeIntervalSince1970 / 1_800) * 1_800)
        let requestedStart = start ?? currentStart
        let includesNow = requestedStart <= model.now
            && model.now < requestedStart.addingTimeInterval(Double(hours) * 3_600)
        return defaultContent(in: model, row: row, from: includesNow ? requestedStart : currentStart, hours: hours)
    }
}
#endif
