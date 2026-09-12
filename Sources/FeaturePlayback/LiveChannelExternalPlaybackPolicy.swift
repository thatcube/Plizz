#if os(iOS)
import AVFoundation
import Foundation

/// Applies pane eligibility to the real retained player, including later adapter updates.
@MainActor
public final class LiveChannelExternalPlaybackPolicy {
    public var isAllowed: Bool {
        didSet { apply() }
    }

    private weak var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []

    public init(isAllowed: Bool = true) {
        self.isAllowed = isAllowed
    }

    public func bind(_ player: AVPlayer?) {
        guard self.player !== player else {
            apply()
            return
        }
        observations.removeAll()
        self.player = player
        if let player {
            observations = [
                player.observe(\.allowsExternalPlayback, options: [.new]) { [weak self] player, _ in
                    Self.reapply(self, to: player)
                },
                player.observe(\.usesExternalPlaybackWhileExternalScreenIsActive, options: [.new]) { [weak self] player, _ in
                    Self.reapply(self, to: player)
                }
            ]
        }
        apply()
    }

    private nonisolated static func reapply(_ policy: LiveChannelExternalPlaybackPolicy?, to player: AVPlayer) {
        let update = { @MainActor [weak policy, weak player] in
            guard let policy, let player, policy.player === player else { return }
            policy.apply()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { update() }
        } else {
            Task { @MainActor in update() }
        }
    }

    private func apply() {
        guard let player else { return }
        if player.allowsExternalPlayback != isAllowed {
            player.allowsExternalPlayback = isAllowed
        }
        if player.usesExternalPlaybackWhileExternalScreenIsActive != isAllowed {
            player.usesExternalPlaybackWhileExternalScreenIsActive = isAllowed
        }
    }
}
#endif
