#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import Observation

/// One Settings presentation owns its admission and importer; transports and
/// durable catalogs are shared with Live TV, never the playback model itself.
@MainActor
@Observable
public final class LiveTVSourcesRuntime {
    public let store: any LiveTVSourcesStoring
    public let catalog: LiveTVSourcesCatalog
    public let scanBinding: LiveTVScanCatalogBinding
    private var admissionRevision = 0
    @ObservationIgnored private let admission: LiveTVSourcesRuntimeAdmission

    public var authorityID: String? { admission.currentIdentity }
    public var isCurrent: Bool {
        _ = admissionRevision
        return catalog.isCurrent
    }

    public init(
        profileID: String,
        store: any LiveTVSourcesStoring,
        approvals: LiveTVSourceApprovalStore,
        cache: LiveTVIndexedCache,
        loader: any LiveTVSourceLoading,
        preferencesStore: any LiveTVPreferencesStoring,
        scanCoordinator: LiveTVChannelScanCoordinator,
        context: @escaping @MainActor () -> LiveTVSourceApprovalContext?,
        accountAuthorizationID: @escaping @MainActor () -> String,
        serverProviderResolver: @escaping LiveTVServerProviderResolver = { _ in nil }
    ) {
        self.store = store
        let admission = LiveTVSourcesRuntimeAdmission(
            profileID: profileID, store: store, approvals: approvals,
            context: context, accountAuthorizationID: accountAuthorizationID
        )
        self.admission = admission
        let catalog = LiveTVSourcesCatalog(
            profileID: profileID, cache: cache, loader: loader,
            preferencesStore: preferencesStore, authority: admission.authority,
            serverProviderResolver: { accountID in
                guard admission.isCurrent else { return nil }
                return serverProviderResolver(accountID)
            }
        )
        self.catalog = catalog
        let binding = LiveTVScanCatalogBinding(
            profileID: profileID, model: catalog.catalog, coordinator: scanCoordinator,
            authorization: { configuration in
                guard let authority = try admission.authority(),
                      configuration == authority.authorization.filtering(authority.configuration) else {
                    throw LiveTVChannelScanError.sourceUnavailable
                }
                return authority.authorization
            }
        )
        scanBinding = binding
        catalog.imports.beforeCatalogPublication = { [weak catalog, weak binding] configuration, channels in
            guard let catalog, catalog.isCurrent else {
                binding?.deactivate()
                return
            }
            binding?.updateCatalog(configuration, channels: channels)
            binding?.setActive(true)
        }
        catalog.imports.beforeSourceRefresh = { [weak binding] in binding?.invalidate($0) }
    }

    isolated deinit {
        scanBinding.deactivate()
        catalog.invalidate()
    }

    /// Stop the old generation before admitting the new profile/account context.
    /// Reappearing after a child editor does not replace a current importer.
    public func activate() {
        let identity = admission.currentIdentity
        guard !admission.isActive || identity != admission.acceptedIdentity else { return }
        invalidate()
        admission.isActive = true
        admission.acceptedIdentity = identity
        admissionRevision &+= 1
    }

    public func restore() async {
        activate()
        await catalog.restore()
    }

    public func invalidate() {
        admission.isActive = false
        admission.acceptedIdentity = nil
        scanBinding.deactivate()
        catalog.invalidate()
        admissionRevision &+= 1
    }
}

@MainActor
private final class LiveTVSourcesRuntimeAdmission {
    let profileID: String
    let store: any LiveTVSourcesStoring
    let approvals: LiveTVSourceApprovalStore
    let context: @MainActor () -> LiveTVSourceApprovalContext?
    let accountAuthorizationID: @MainActor () -> String
    var isActive = false
    var acceptedIdentity: String?

    init(
        profileID: String, store: any LiveTVSourcesStoring,
        approvals: LiveTVSourceApprovalStore,
        context: @escaping @MainActor () -> LiveTVSourceApprovalContext?,
        accountAuthorizationID: @escaping @MainActor () -> String
    ) {
        self.profileID = profileID
        self.store = store
        self.approvals = approvals
        self.context = context
        self.accountAuthorizationID = accountAuthorizationID
    }

    var currentIdentity: String? {
        guard let context = context(), context.profileID == profileID else { return nil }
        return context.identity + "|" + accountAuthorizationID()
    }

    var isCurrent: Bool {
        isActive && acceptedIdentity != nil && acceptedIdentity == currentIdentity
    }

    func authority() throws -> LiveTVSourcesCatalogAuthority? {
        guard isCurrent, let context = context(), context.profileID == profileID else { return nil }
        let configuration = try store.load()
        try configuration.validate()
        let authorization = try approvals.authorization(context: context, configuration: configuration)
        return LiveTVSourcesCatalogAuthority(configuration: configuration, authorization: authorization)
    }
}
#endif
