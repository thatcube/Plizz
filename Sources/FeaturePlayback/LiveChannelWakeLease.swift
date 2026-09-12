#if canImport(UIKit)
import Foundation

@MainActor
final class LiveChannelWakeGroup {
    private var holders: Set<UUID> = []
    private let updateIdleTimer: @MainActor (Bool) -> Void

    init(updateIdleTimer: @escaping @MainActor (Bool) -> Void) {
        self.updateIdleTimer = updateIdleTimer
    }

    fileprivate func setAwake(_ awake: Bool, holder: UUID) {
        if awake { holders.insert(holder) }
        else { holders.remove(holder) }
        updateIdleTimer(!holders.isEmpty)
    }
}

@MainActor
final class LiveChannelWakeLease {
    private static let guardOwner = IdleSleepGuard()
    private static let sharedGroup = LiveChannelWakeGroup {
        LiveChannelWakeLease.guardOwner.keepAwake($0)
    }
    let group: LiveChannelWakeGroup
    private let id = UUID()

    init(group: LiveChannelWakeGroup? = nil) {
        self.group = group ?? Self.sharedGroup
    }

    func keepAwake(_ awake: Bool) {
        group.setAwake(awake, holder: id)
    }

    func allowSleep() { keepAwake(false) }

    deinit {
        let id = id
        let group = group
        Task { @MainActor in
            group.setAwake(false, holder: id)
        }
    }
}
#endif
