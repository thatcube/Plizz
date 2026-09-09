import Foundation

public struct PlaybackControlsInactivity: Equatable, Sendable {
    public static let defaultGrace: TimeInterval = 4
    public private(set) var lastInteractionAt: TimeInterval?

    public init() {}

    public mutating func recordInteraction(at time: TimeInterval) {
        lastInteractionAt = max(lastInteractionAt ?? time, time)
    }

    public func remainingDelay(
        startedAt: TimeInterval,
        now: TimeInterval,
        grace: TimeInterval = PlaybackControlsInactivity.defaultGrace
    ) -> TimeInterval {
        max(0, max(startedAt, lastInteractionAt ?? startedAt) + grace - now)
    }
}
