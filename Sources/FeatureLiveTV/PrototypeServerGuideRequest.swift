#if DEBUG
import FeatureLiveTVCore
import Foundation

struct PrototypeServerGuideRequest: Equatable {
    struct Channel: Equatable {
        let id: String
        let reference: LiveTVServerChannelReference
    }

    static let rowLimit = 12
    let channels: [Channel]
    let from: Date
    let to: Date

    init?(
        rows: [LiveTVGuideRowID],
        anchor: LiveTVGuideRowID?,
        references: [String: LiveTVServerChannelReference],
        from: Date,
        to: Date
    ) {
        let channels = Self.nearbyChannelIDs(rows: rows, anchor: anchor, limit: Self.rowLimit)
            .compactMap { id -> Channel? in
                guard let reference = references[id] else { return nil }
                return Channel(id: id, reference: reference)
            }
        guard !channels.isEmpty else { return nil }
        self.channels = channels
        self.from = from
        self.to = to
    }

    static func nearbyChannelIDs(
        rows: [LiveTVGuideRowID], anchor: LiveTVGuideRowID?, limit: Int
    ) -> [String] {
        guard !rows.isEmpty, limit > 0 else { return [] }
        let center = anchor.flatMap { anchor in
            rows.firstIndex(of: anchor) ?? rows.firstIndex { $0.channelID == anchor.channelID }
        } ?? 0
        let lower = max(0, min(center - 3, rows.count - limit))
        let upper = min(rows.count, lower + limit)
        var seen = Set<String>()
        return rows[lower..<upper].compactMap { row in
            seen.insert(row.channelID).inserted ? row.channelID : nil
        }
    }
}
#endif
