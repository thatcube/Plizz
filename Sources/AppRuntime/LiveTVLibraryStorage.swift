#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import Foundation

@MainActor
public enum LiveTVLibraryStorage {
    public static let snapshots = LibraryChannelSnapshotStore()
    private static var stores: [StoreKey: LibraryChannelDefinitionStore] = [:]
    private static var runtimes: [RuntimeKey: WeakRuntime] = [:]

    public static func runtime(profileID: String, profiles: ProfilesModel) -> LiveTVLibraryRuntime {
        let key = RuntimeKey(
            profileID: profileID,
            namespace: preferencesNamespace(profileID: profileID, profiles: profiles),
            profiles: ObjectIdentifier(profiles)
        )
        if let runtime = runtimes[key]?.value { return runtime }
        runtimes = runtimes.filter { $0.value.value != nil }
        let runtime = LiveTVLibraryRuntime(profileID: profileID, profiles: profiles)
        runtimes[key] = WeakRuntime(runtime)
        return runtime
    }

    public static func definitions(profileID: String, namespace: String?) -> LibraryChannelDefinitionStore {
        let key = StoreKey(profileID: profileID, namespace: namespace)
        if let existing = stores[key] { return existing }
        let store = LibraryChannelDefinitionStore(
            secureStore: LiveTVSourceStorage.catalogSecrets(),
            namespace: namespace
        )
        stores[key] = store
        return store
    }

    static func preferencesNamespace(profileID: String, profiles: ProfilesModel) -> String? {
        profileID == profiles.rootNamespaceOwnerID ? nil : profileID
    }

    private struct StoreKey: Hashable {
        let profileID: String
        let namespace: String?
    }

    private struct RuntimeKey: Hashable {
        let profileID: String
        let namespace: String?
        let profiles: ObjectIdentifier
    }

    private final class WeakRuntime {
        weak var value: LiveTVLibraryRuntime?
        init(_ value: LiveTVLibraryRuntime) { self.value = value }
    }
}
#endif
