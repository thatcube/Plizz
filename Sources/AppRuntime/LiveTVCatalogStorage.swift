#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import Foundation

@MainActor
public enum LiveTVCatalogStorage {
    private static var caches: [String: LiveTVIndexedCache] = [:]
    private static var loaders: [LoaderScope: LiveTVSourceLoader] = [:]

    public static func loader(profileID: String, namespace: String?) -> LiveTVSourceLoader {
        let scope = LoaderScope(profileID: profileID, namespace: namespace)
        if let existing = loaders[scope] { return existing }
        let loader = LiveTVSourceLoader()
        loaders[scope] = loader
        return loader
    }

    private struct LoaderScope: Hashable {
        let profileID: String
        let namespace: String?
    }

    public static func existingCache(profileID: String) -> LiveTVIndexedCache? {
        caches[profileID]
    }

    public static func cache(profileID: String) throws -> LiveTVIndexedCache {
        if let existing = caches[profileID] { return existing }
        // This cache contains profile-owned IPTV, not media-server account data.
        let scope = "iptv-profile-v1"
        let cache = LiveTVIndexedCache(
            url: try LiveTVIndexedCache.defaultURL(namespace: profileID, authorizationScope: scope),
            namespace: profileID, authorizationScope: scope,
            secureStore: LiveTVSourceStorage.catalogSecrets()
        )
        caches[profileID] = cache
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: profileID)
        return cache
    }
}
#endif
