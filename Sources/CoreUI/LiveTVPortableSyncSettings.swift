import CoreModels
import SwiftUI

/// Place inside the existing Sync settings, using the same profile environment.
/// `isAvailable` describes real composition/storage availability, not sign-in guesses.
public struct LiveTVPortableSyncSettings: View {
    private let isAvailable: Bool?
    private let status: LocalizedStringResource?
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    public init(isAvailable: Bool? = nil, status: LocalizedStringResource? = nil) {
        self.isAvailable = isAvailable
        self.status = status
    }

    public var body: some View {
        if let profiles {
            LiveTVProfilePortableSyncSettings(
                profiles: profiles,
                isAvailable: isAvailable ?? LiveTVPortableSyncPresentation.shared.isAvailable(profiles: profiles),
                status: status ?? LiveTVPortableSyncPresentation.shared.summary(profileID: profiles.activeProfileID)
            )
            .id(profiles.activeProfileID)
        } else {
            Text("Live TV sync is unavailable.").settingsRowSecondary()
        }
    }
}

private struct LiveTVProfilePortableSyncSettings: View {
    let profiles: ProfilesModel
    let isAvailable: Bool
    let status: LocalizedStringResource?
    @AppStorage(SyncSetupFeatureFlag.storageKey) private var cloudEnabled = true
    @State private var enabled = false
    @State private var pendingValue: Bool?
    @State private var pendingContext: LiveTVSourceApprovalContext?
    @State private var pendingEpoch: String?
    @State private var error: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Sync Live TV", isOn: Binding(get: { enabled }, set: requestChange))
                .disabled(!isAvailable || !cloudEnabled)
                .accessibilityIdentifier("live-tv-portable-sync-enabled")
            if !cloudEnabled {
                Text("Turn on iCloud Sync to sync Live TV.").settingsRowSecondary()
            } else if !isAvailable {
                Text("Live TV sync is unavailable on this device.").settingsRowSecondary()
            } else if !enabled {
                Text("Live TV settings stay on this device.").settingsRowSecondary()
            } else {
                if let status { Text(status).settingsRowSecondary() }
                Text("Channel settings and library schedules sync. Playlist addresses, imported files and parental approvals stay on this device.")
                    .settingsRowSecondary()
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task { enabled = preference.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange).receive(on: DispatchQueue.main)) { _ in
            enabled = preference.isEnabled
            if pendingEpoch != nil, pendingEpoch != LiveTVPortableSyncPreferenceStore.storageEpoch() {
                pendingValue = nil
                pendingContext = nil
                pendingEpoch = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingValue != nil },
            set: { if !$0 { pendingValue = nil; pendingContext = nil } }
        )) {
            PINEntryScaffold(
                title: KidsProfileCopy.parentalPINEnter,
                name: Text(KidsProfileCopy.parentalPIN),
                errorMessage: error,
                onSubmit: approveChange,
                onCancel: { pendingValue = nil; pendingContext = nil }
            ) {
                PINBadge {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                }
            }
        }
    }

    private var preference: LiveTVPortableSyncPreferenceStore {
        LiveTVPortableSyncPreferenceStore(
            profileID: profiles.activeProfileID,
            namespace: profiles.activeProfileID == profiles.rootNamespaceOwnerID ? nil : profiles.activeProfileID
        )
    }

    private var context: LiveTVSourceApprovalContext {
        LiveTVSourceApprovalContext(
            profile: profiles.activeProfile, parentalPIN: profiles.parentalPIN,
            activeAccountIDs: profiles.activeAccountIDs(for: profiles.activeProfileID, fallback: [])
        )
    }

    private func requestChange(_ value: Bool) {
        error = nil
        if profiles.activeProfile.isKids {
            guard profiles.parentalPIN != nil else {
                error = "Set a Parental PIN in Profiles before changing Live TV sync."
                return
            }
            pendingContext = context
            pendingEpoch = LiveTVPortableSyncPreferenceStore.storageEpoch()
            pendingValue = value
        } else {
            preference.isEnabled = value
            enabled = preference.isEnabled
            if value && !enabled { error = "Live TV sync is unavailable on this device." }
        }
    }

    private func approveChange(_ pin: String) {
        guard let pendingValue, pendingContext == context, isAvailable, cloudEnabled,
              pendingEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch() else {
            error = "This profile changed. Reopen Sync settings and try again."
            return
        }
        guard profiles.matchesParentalPIN(pin) else {
            error = ProfileLockCopy.incorrectPIN
            return
        }
        preference.isEnabled = pendingValue
        enabled = preference.isEnabled
        self.pendingValue = nil
        pendingContext = nil
        pendingEpoch = nil
        error = pendingValue && !enabled ? "Live TV sync is unavailable on this device." : nil
    }
}
