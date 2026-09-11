import CoreModels

public enum LiveTVSourceStorage {
    /// Inject into the indexed catalog from the app composition layer.
    /// Only keys, identity associations and mapping overrides belong here.
    public static func catalogSecrets() -> any SecureStoring {
        KeychainStore(service: "com.plozz.liveTV.catalog")
    }

    public static func store(namespace: String? = nil) -> LiveTVSourcesStore {
        LiveTVSourcesStore(
            secureStore: KeychainStore(service: "com.plozz.liveTV.sources"),
            namespace: namespace
        )
    }

    public static func approvalAwareStore(
        profileID: String, namespace: String?
    ) -> LiveTVApprovalAwareSourcesStore {
        LiveTVApprovalAwareSourcesStore(
            underlying: store(namespace: namespace),
            approvals: LiveTVSourceApprovalStore(profileID: profileID, namespace: namespace)
        )
    }
}
