import CoreModels

/// Coordinates the bounded neighboring-season work chosen by the series view.
@MainActor
public enum SeasonPrewarmScheduler {
    public static func run(
        seasonIDs: [String],
        loadEpisodes: @escaping @MainActor @Sendable (String) async -> Void,
        warmArtwork: @escaping @MainActor @Sendable (String) async -> Void
    ) async {
        guard !seasonIDs.isEmpty, !Task.isCancelled else { return }
        let (ready, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingOldest(seasonIDs.count)
        )
        async let metadata: Void = loadMetadata(
            seasonIDs: seasonIDs, loadEpisodes: loadEpisodes, continuation: continuation
        )
        for await seasonID in ready {
            guard !Task.isCancelled else { return }
            await warmArtwork(seasonID)
        }
        await metadata
    }

    private static func loadMetadata(
        seasonIDs: [String],
        loadEpisodes: @MainActor @Sendable (String) async -> Void,
        continuation: AsyncStream<String>.Continuation
    ) async {
        defer { continuation.finish() }
        // Keep one speculative metadata request at a time, but never make it
        // wait for images. The artwork consumer remains serial and starts as
        // soon as the first neighboring list arrives.
        for seasonID in seasonIDs {
            guard !Task.isCancelled else { return }
            await loadEpisodes(seasonID)
            guard !Task.isCancelled else { return }
            if case .terminated = continuation.yield(seasonID) { return }
        }
    }
}

public enum SeasonArtworkPrewarmWindow {
    /// Cover the first viewport around the row's opening target, target first.
    /// Do not decode whole seasons and evict the thumbnails the viewer needs next.
    public static func episodes(
        _ episodes: [MediaItem], targetID: String?, limit: Int
    ) -> [MediaItem] {
        guard !episodes.isEmpty, limit > 0 else { return [] }
        let target = episodes.firstIndex { $0.id == targetID } ?? 0
        let start = min(target, max(0, episodes.count - limit))
        let end = min(episodes.count, start + limit)
        return Array(episodes[target..<end]) + Array(episodes[start..<target])
    }
}
