#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import Foundation

extension LiveTVPortableSyncBridge {
    public static func storageDirectory() -> URL? {
        for location in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let base = try? FileManager.default.url(
                for: location, in: .userDomainMask, appropriateFor: nil, create: true
            ) {
                let directory = base.appendingPathComponent("PlozzSync/LiveTV", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return directory
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    public static func makeRuntime(profiles: ProfilesModel, directory: URL) -> LiveTVPortableSyncBridge {
        let sources: @MainActor (String) -> any LiveTVSourcesStoring = { profileID in
            let namespace = profileID == profiles.rootNamespaceOwnerID ? nil : profileID
            return LiveTVSourceStorage.approvalAwareStore(
                profileID: profileID, namespace: namespace
            )
        }
        return LiveTVPortableSyncBridge(
            profiles: profiles, directory: directory, sourceStore: sources,
            definitions: { profileID in
                LiveTVLibraryStorage.definitions(
                    profileID: profileID,
                    namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
                )
            },
            snapshots: LiveTVLibraryStorage.snapshots,
            guideCache: { LiveTVCatalogStorage.existingCache(profileID: $0) },
            captureIdentityHints: { profileID in
                guard let cache = LiveTVCatalogStorage.existingCache(profileID: profileID) else { return nil }
                let store = sources(profileID)
                let configuration = try (store as? any LiveTVPortableSourcesStoring)?.loadSyncConfiguration()
                    ?? store.load()
                let preferences = try LiveTVPreferencesStore(
                    namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
                ).load()
                let mappings = try await cache.mappingOverrides()
                let channelIDs = preferences.favoriteIDs.union(preferences.hiddenChannelIDs)
                    .union(preferences.channelOverrides.keys).union(mappings.keys)
                return try await cache.portableSyncIdentityHints(
                    configuration: configuration, channelIDs: channelIDs
                )
            },
            applyIdentityHints: { profileID, hints in
                guard !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
                      let cache = LiveTVCatalogStorage.existingCache(profileID: profileID) else { return false }
                try await cache.applyPortableIdentityHints(hints)
                return true
            }
        )
    }
}
#endif
