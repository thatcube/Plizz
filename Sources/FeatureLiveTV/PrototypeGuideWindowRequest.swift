#if DEBUG
import FeatureLiveTVCore
import Foundation

struct PrototypeGuideWindowRequest: Equatable {
    private struct SourceRevision: Equatable {
        let id: String
        let phase: LiveTVImportPhase
        let refreshedAt: Date?
        let programCount: Int
    }

    static let rowLimit = 48
    let channelIDs: [String]
    let range: DateInterval
    private let sources: [SourceRevision]
    private let mappings: [String: LiveTVGuideMappingOverride]

    init?(
        rows: [LiveTVGuideRowID], anchor: LiveTVGuideRowID?,
        from: Date, to: Date, sources: [LiveTVGuideSourceStatus],
        enabledSourceIDs: Set<String>, mappings: [String: LiveTVGuideMappingOverride]
    ) {
        let channels = PrototypeServerGuideRequest.nearbyChannelIDs(
            rows: rows, anchor: anchor, limit: Self.rowLimit
        )
        let enabled = sources.filter { enabledSourceIDs.contains($0.id) }
        guard !channels.isEmpty, !enabled.isEmpty, from < to else { return nil }
        channelIDs = channels
        range = DateInterval(start: from, end: to)
        self.sources = enabled.map {
            SourceRevision(id: $0.id, phase: $0.phase, refreshedAt: $0.lastRefresh, programCount: $0.programCount)
        }
        let ids = Set(channels)
        self.mappings = mappings.filter { ids.contains($0.key) }
    }
}
#endif
