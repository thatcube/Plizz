import CoreFoundation
import Foundation
import Observation

/// Admission to the app is separate from server authentication and profile access.
/// Source availability, account selection within a profile, and profile setup
/// completion must not decide whether an explicitly standalone install can open.
public struct AppAdmissionContext: Equatable, Sendable {
    public let hasMediaAccounts: Bool
    public let explicitStandaloneChoice: Bool

    public init(
        hasMediaAccounts: Bool,
        explicitStandaloneChoice: Bool = false
    ) {
        self.hasMediaAccounts = hasMediaAccounts
        self.explicitStandaloneChoice = explicitStandaloneChoice
    }

    public var canEnterApp: Bool {
        hasMediaAccounts || explicitStandaloneChoice
    }
}

/// Shared startup selection policy. An explicit entry can temporarily expose
/// Live TV; a later launch respects the profile's configured destinations.
public enum AppAdmissionNavigation {
    public static func destinations<Destination: Equatable>(
        _ configured: [Destination],
        liveTV: Destination,
        includesExplicitEntry: Bool
    ) -> [Destination] {
        guard includesExplicitEntry, !configured.contains(liveTV) else { return configured }
        return [liveTV] + configured
    }

    public static func initialSelection<Destination: Equatable>(
        current: Destination,
        visible: [Destination],
        liveTV: Destination,
        fallback: Destination,
        admission: AppAdmissionContext,
        hasPendingLiveTVEntry: Bool
    ) -> Destination {
        if admission.explicitStandaloneChoice,
           hasPendingLiveTVEntry || (!admission.hasMediaAccounts && visible.contains(liveTV)) {
            return liveTV
        }
        return visible.contains(current) ? current : (visible.first ?? fallback)
    }
}

public protocol AppAdmissionStoring: Sendable {
    func loadStandaloneChoice() -> Bool
    func recordStandaloneChoice()
    func resetStandaloneChoiceForDebugging()
}

/// Non-secret, device-wide preference. Deliberately has no profile namespace and
/// is not transferred with server credentials or tied to a source registry.
public final class AppAdmissionStore: AppAdmissionStoring, @unchecked Sendable {
    static let standaloneChoiceKey = "com.plozz.appAdmission.standalonePlayback"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadStandaloneChoice() -> Bool {
        // UserDefaults.bool(forKey:) coerces strings and numbers. Only a real
        // persisted Boolean may opt an install into standalone admission.
        guard let value = defaults.object(forKey: Self.standaloneChoiceKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return value.boolValue
    }

    public func recordStandaloneChoice() {
        defaults.set(true, forKey: Self.standaloneChoiceKey)
    }

    public func resetStandaloneChoiceForDebugging() {
        defaults.removeObject(forKey: Self.standaloneChoiceKey)
    }
}

/// Retained once by each app shell, never rebuilt when the viewer changes.
@MainActor
@Observable
public final class AppAdmissionModel {
    public private(set) var explicitStandaloneChoice: Bool
    public private(set) var pendingLiveTVEntry = false
    private let store: any AppAdmissionStoring

    public init(store: any AppAdmissionStoring = AppAdmissionStore()) {
        self.store = store
        self.explicitStandaloneChoice = store.loadStandaloneChoice()
    }

    /// The caller supplies actual feature availability. A stored choice cannot
    /// admit a zero-account install into a build with no standalone destination.
    public func context(
        hasMediaAccounts: Bool,
        standalonePlaybackAvailable: Bool
    ) -> AppAdmissionContext {
        AppAdmissionContext(
            hasMediaAccounts: hasMediaAccounts,
            explicitStandaloneChoice: standalonePlaybackAvailable && explicitStandaloneChoice
        )
    }

    /// Queue navigation before publishing admission. Consumption belongs to the
    /// destination shell, after it has selected Live TV, not to profile setup.
    @discardableResult
    public func enterStandalonePlayback(isAvailable: Bool) -> Bool {
        guard isAvailable else { return false }
        guard !explicitStandaloneChoice else { return true }
        pendingLiveTVEntry = true
        return recordStandaloneChoice(isAvailable: isAvailable)
    }

    /// A successful, explicitly requested IPTV setup can retain admission
    /// without re-entering onboarding or stealing the current destination.
    @discardableResult
    public func recordStandaloneChoice(isAvailable: Bool) -> Bool {
        guard isAvailable else { return false }
        guard !explicitStandaloneChoice else { return true }
        store.recordStandaloneChoice()
        explicitStandaloneChoice = true
        return true
    }

    @discardableResult
    public func consumeLiveTVEntryIntent() -> Bool {
        guard pendingLiveTVEntry else { return false }
        pendingLiveTVEntry = false
        return true
    }

    /// Only the explicit "reset to first run" diagnostic action revokes this
    /// choice. Signing out, deleting sources, and switching profiles do not.
    public func resetForDebugging() {
        pendingLiveTVEntry = false
        store.resetStandaloneChoiceForDebugging()
        explicitStandaloneChoice = false
    }
}
