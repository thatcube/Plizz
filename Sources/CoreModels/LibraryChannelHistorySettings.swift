import Foundation
import Observation

/// Independent from ordinary library playback. A new authorization token on
/// every opt-in stops pending channel writes and prevents retroactive coverage.
@MainActor
@Observable
public final class LibraryChannelHistorySettings {
    private static let baseKey = "com.plozz.liveTV.libraryChannelHistory"
    private static var instances: [String: LibraryChannelHistorySettings] = [:]

    public private(set) var isEnabled: Bool
    public private(set) var authorizationID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var observation: LibraryChannelHistoryDefaultsObservation?

    public static func shared(namespace: String? = nil) -> LibraryChannelHistorySettings {
        let key = SettingsKey.scoped(baseKey, namespace: namespace)
        if let settings = instances[key] { return settings }
        let settings = LibraryChannelHistorySettings(namespace: namespace)
        instances[key] = settings
        return settings
    }

    /// Use `shared(namespace:)` in application code so every consumer sees the same grant.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
        isEnabled = defaults.bool(forKey: key)
        authorizationID = isEnabled ? UUID() : nil
        observation = LibraryChannelHistoryDefaultsObservation { [weak self] in self?.reload() }
    }

    public func setEnabled(_ enabled: Bool) {
        reload()
        guard enabled != isEnabled else { return }
        apply(enabled)
        defaults.set(enabled, forKey: key)
    }

    public func reload() {
        apply(defaults.bool(forKey: key))
    }

    private func apply(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        authorizationID = enabled ? UUID() : nil
    }
}

private final class LibraryChannelHistoryDefaultsObservation {
    private let token: any NSObjectProtocol

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        // A different UserDefaults instance can write the same persistent domain.
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
