import Foundation

/// AVKit callback ordering is asynchronous; keep pending starts and stops owned.
public struct LivePictureInPictureLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, starting, active, stopping
    }

    public private(set) var state: State = .idle
    public var continuesPlayback: Bool { state != .idle }
    public init() {}

    @discardableResult
    public mutating func beginStart(isPossible: Bool) -> Bool {
        guard isPossible, state == .idle else { return false }
        state = .starting
        return true
    }

    @discardableResult
    public mutating func didStart() -> Bool {
        guard state == .starting else { return false }
        state = .active
        return true
    }

    @discardableResult
    public mutating func requestStop() -> Bool {
        guard continuesPlayback else { return false }
        state = .stopping
        return true
    }

    public mutating func finish() { state = .idle }

    public func shouldDetach(preservingPresentation: Bool, externalPlaybackActive: Bool = false) -> Bool {
        !preservingPresentation || !(continuesPlayback || externalPlaybackActive)
    }
}
