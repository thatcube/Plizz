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
