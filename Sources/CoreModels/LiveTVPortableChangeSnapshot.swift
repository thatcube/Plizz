import Foundation

/// Compare only Live TV preference inputs when UserDefaults broadcasts a change.
/// Cloud ledgers, playback position and unrelated settings must not start a
/// publish → defaults notification → publish feedback loop.
public struct LiveTVPortableChangeSnapshot: Equatable {
    private let preferences: [String: LiveTVPreferences]
    private let consent: [String: Bool]
    private let epoch: String

    @MainActor
    public init(profiles: ProfilesModel, defaults: UserDefaults = .standard) {
        var preferences: [String: LiveTVPreferences] = [:]
        var consent: [String: Bool] = [:]
        for profile in profiles.profiles {
            let namespace = profile.id == profiles.rootNamespaceOwnerID ? nil : profile.id
            if let saved = try? LiveTVPreferencesStore(defaults: defaults, namespace: namespace).load() {
                preferences[profile.id] = LiveTVPreferences(
                    favoriteIDs: saved.favoriteIDs, hiddenChannels: saved.hiddenChannels,
                    favoriteOrder: saved.favoriteOrder, favoriteChannels: saved.favoriteChannels,
                    channelOverrides: saved.channelOverrides
                )
            }
            consent[profile.id] = LiveTVPortableSyncPreferenceStore(
                defaults: defaults, profileID: profile.id, namespace: namespace
            ).isEnabled
        }
        self.preferences = preferences
        self.consent = consent
        epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
    }
}
