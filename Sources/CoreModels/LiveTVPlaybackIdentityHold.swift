import Foundation

/// Portable catalog IDs may change only after every player in that profile has
/// released its preparation. A hold never owns or extends a playback session.
@MainActor
public final class LiveTVPlaybackIdentityHold {
    private static var holders: [UUID: WeakHolder] = [:]
    private let id = UUID()
    private let profileID: String
    private var isHolding = false

    public init(profileID: String) {
        self.profileID = profileID
    }

    public static func isHeld(profileID: String) -> Bool {
        holders = holders.filter { $0.value.value != nil }
        return holders.values.contains { $0.value?.profileID == profileID && $0.value?.isHolding == true }
    }

    public func update(_ active: Bool) {
        guard isHolding != active else { return }
        isHolding = active
        if active {
            Self.holders[id] = WeakHolder(self)
        } else {
            Self.holders[id] = nil
            NotificationCenter.default.post(name: .plozzLiveTVPlaybackIdentityDidBecomeIdle, object: profileID)
        }
    }

    deinit {
        guard isHolding else { return }
        let id = id
        let profileID = profileID
        Task { @MainActor in
            Self.holders[id] = nil
            NotificationCenter.default.post(name: .plozzLiveTVPlaybackIdentityDidBecomeIdle, object: profileID)
        }
    }

    private final class WeakHolder {
        weak var value: LiveTVPlaybackIdentityHold?
        init(_ value: LiveTVPlaybackIdentityHold) { self.value = value }
    }
}

extension Notification.Name {
    public static let plozzLiveTVPlaybackIdentityDidBecomeIdle =
        Notification.Name("com.plozz.liveTV.playbackIdentityDidBecomeIdle")
    public static let plozzLiveTVPortableStateDidApply =
        Notification.Name("com.plozz.liveTV.portableStateDidApply")
}
