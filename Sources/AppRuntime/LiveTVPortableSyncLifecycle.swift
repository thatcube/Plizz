#if DEBUG
import CoreModels
import Foundation
import Observation

/// Owned by the shell, rather than an immortal NotificationCenter callback.
@MainActor
public final class LiveTVPortableSyncLifecycle {
    private let profiles: ProfilesModel
    private let defaults: UserDefaults
    private let onChange: @MainActor () -> Void
    private var lastSnapshot: LiveTVPortableChangeSnapshot
    private var observations: [ObservationLease] = []
    private var wasSignedOut = false
    private let observesLibraryRuntime: Bool
    private var libraryRuntime: LiveTVLibraryRuntime?
    private var libraryDefinitions: [LibraryChannelDefinition] = []

    public init(
        profiles: ProfilesModel, defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default,
        observesLibraryRuntime: Bool = false,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.profiles = profiles
        self.defaults = defaults
        self.onChange = onChange
        self.observesLibraryRuntime = observesLibraryRuntime
        lastSnapshot = LiveTVPortableChangeSnapshot(profiles: profiles, defaults: defaults)
        for name in [
            UserDefaults.didChangeNotification,
            .plozzLiveTVPortableStateDidChange,
            .plozzLiveTVPlaybackIdentityDidBecomeIdle
        ] {
            let token = notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.changed(defaultsOnly: name == UserDefaults.didChangeNotification) }
            }
            observations.append(ObservationLease(center: notifications, token: token))
        }
        observeProfiles()
        if observesLibraryRuntime { bindLibraryRuntime() }
    }

    public func accountStatusChanged(isSignedOut: Bool, accountTag: String? = nil, reset: () -> Void) {
        var shouldReset = isSignedOut && !wasSignedOut
        // The existing diagnostic account tag also fences a different account
        // first discovered after sync was disabled or the process was stopped.
        if let accountTag, !accountTag.isEmpty {
            let key = "com.plozz.liveTV.portableSync.accountTag"
            if let previous = defaults.string(forKey: key), previous != accountTag { shouldReset = true }
            if defaults.string(forKey: key) != accountTag { defaults.set(accountTag, forKey: key) }
        }
        if shouldReset { reset() }
        wasSignedOut = isSignedOut
    }

    private func changed(defaultsOnly: Bool) {
        let snapshot = LiveTVPortableChangeSnapshot(profiles: profiles, defaults: defaults)
        guard !defaultsOnly || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange()
    }

    private func observeProfiles() {
        withObservationTracking {
            _ = profiles.profiles
            _ = profiles.rootNamespaceOwnerID
            if observesLibraryRuntime { _ = profiles.activeProfileID }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.changed(defaultsOnly: true)
                self?.observeProfiles()
                if self?.observesLibraryRuntime == true { self?.bindLibraryRuntime() }
            }
        }
    }

    private func bindLibraryRuntime() {
        let runtime = LiveTVLibraryStorage.runtime(profileID: profiles.activeProfileID, profiles: profiles)
        guard libraryRuntime !== runtime else { return }
        libraryRuntime = runtime
        libraryDefinitions = runtime.service.definitions
        observeLibraryDefinitions()
    }

    private func observeLibraryDefinitions() {
        guard let runtime = libraryRuntime else { return }
        let definitions = withObservationTracking {
            runtime.service.definitions
        } onChange: { [weak self, weak runtime] in
            Task { @MainActor in
                guard let self, let runtime, self.libraryRuntime === runtime else { return }
                self.observeLibraryDefinitions()
            }
        }
        if definitions != libraryDefinitions {
            libraryDefinitions = definitions
            onChange()
        }
    }
}

private final class ObservationLease: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }
    deinit { center.removeObserver(token) }
}
#endif
