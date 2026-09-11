import Foundation

/// Recursive queries are paginated at the server. Series metadata may be queried
/// to inherit genres/ratings, but only concrete episodes and movies are scheduled.
public protocol LibraryChannelCatalogProviding: MediaProvider {
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage
}

/// This path does not open an ordinary watch-reporting session. Providers must
/// refuse any transport whose lifecycle cannot be separated from library state.
public protocol LibraryChannelPlaybackProviding: MediaProvider {
    func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest
    func recordLibraryChannelCompletion(itemID: String) async throws
}

/// Actual, unique media intervals, not the greatest source position. Initial
/// seeks, jumps and stalls cannot contribute coverage. Retained only per tune.
public struct LibraryChannelWatchCoverage: Equatable, Sendable {
    public private(set) var intervals: [ClosedRange<Double>] = []
    private var lastPosition: Double?
    private var lastInstant: TimeInterval?
    public let duration: Double
    public let completionFraction: Double

    public init(duration: Double, completionFraction: Double = 0.9) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.completionFraction = min(1, max(0.5, completionFraction))
    }

    public var secondsWatched: Double {
        intervals.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }
    public var watchedPercent: Double { duration > 0 ? min(100, secondsWatched / duration * 100) : 0 }
    public var isComplete: Bool { duration > 0 && secondsWatched >= duration * completionFraction }

    public mutating func discontinuity() {
        lastPosition = nil
        lastInstant = nil
    }

    /// `instant` is monotonic uptime, not wall clock. Call at least every 2s.
    public mutating func sample(position: Double, instant: TimeInterval, isPlaying: Bool) {
        guard position.isFinite, instant.isFinite, isPlaying,
              position >= 0, position <= duration else {
            discontinuity()
            return
        }
        defer { lastPosition = position; lastInstant = instant }
        guard let previous = lastPosition, let previousInstant = lastInstant else { return }
        let elapsed = instant - previousInstant
        let advanced = position - previous
        guard elapsed > 0, elapsed <= 5, advanced > 0,
              advanced <= elapsed + 0.5, advanced >= elapsed * 0.5 else { return }
        var pending = previous...position
        var merged: [ClosedRange<Double>] = []
        for interval in intervals {
            if interval.upperBound < pending.lowerBound {
                merged.append(interval)
            } else if pending.upperBound < interval.lowerBound {
                merged.append(pending)
                pending = interval
            } else {
                pending = min(pending.lowerBound, interval.lowerBound)...max(pending.upperBound, interval.upperBound)
            }
        }
        merged.append(pending)
        // Pathological repeated scrubbing must not create unbounded state.
        if merged.count <= 4_096 { intervals = merged }
    }
}
