/// Optional fast path for providers that can resolve one show's current episode
/// without loading the user's entire Continue Watching feed.
public protocol SeriesResumeProviding: Sendable {
    /// Fresh, server-owned resume or next-up episode for this exact series.
    /// IDs belong to this provider/account. Returns nil when there is no target;
    /// throws when the server cannot answer.
    func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem?
}

/// Optional lightweight batch lookup for Home's cross-server episode identity.
public protocol SeriesIdentityProviding: Sendable {
    /// External IDs keyed by the requested provider-local series IDs. Results
    /// must not include unrelated items or substitute episode IDs for show IDs.
    func seriesProviderIDs(for seriesIDs: [String]) async throws -> [String: [String: String]]
}
