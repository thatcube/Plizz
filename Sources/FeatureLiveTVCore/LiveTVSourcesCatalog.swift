#if DEBUG
import CoreModels
import Foundation
import Observation

public struct LiveTVSourcesCatalogAuthority: Equatable, Sendable {
    public let configuration: LiveTVSourcesConfiguration
    public let authorization: LiveTVSourceAuthorization

    public init(configuration: LiveTVSourcesConfiguration, authorization: LiveTVSourceAuthorization) {
        self.configuration = configuration
        self.authorization = authorization
    }
}

/// Retain once per Sources presentation/profile. Cache and transport are injected
/// shared instances; this controller creates neither a connection nor a network actor.
@MainActor
@Observable
public final class LiveTVSourcesCatalog {
    public enum Issue: Equatable {
        case configuration, authorization, catalog

        public var message: LocalizedStringResource {
            switch self {
            case .configuration: "Your saved Live TV sources couldn't be read."
            case .authorization: "Profile access changed. Reopen Sources to continue."
            case .catalog: "Channel and guide data couldn't be loaded. Retry to refresh it."
            }
        }
    }

    public let imports: LiveTVPrototypeImportModel
    public let catalog: LiveTVPrototypeModel
    public private(set) var isLoading = false
    public private(set) var issue: Issue?
    public var isCurrent: Bool { admission.isCurrent }
    public var profileID: String { admission.profileID }

    @ObservationIgnored private let admission: LiveTVSourcesCatalogAdmission
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequest = 0
    @ObservationIgnored private var activeRefresh = false

    /// `authority` must return nil while locked/inactive and must reflect current
    /// source configuration and local approvals, not a captured authorization snapshot.
    public init(
        profileID: String,
        cache: LiveTVIndexedCache,
        loader: any LiveTVSourceLoading,
        preferencesStore: any LiveTVPreferencesStoring,
        authority: @escaping @MainActor () throws -> LiveTVSourcesCatalogAuthority?,
        serverProviderResolver: @escaping LiveTVServerProviderResolver = { _ in nil },
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        let admission = LiveTVSourcesCatalogAdmission(profileID: profileID, authority: authority)
        self.admission = admission
        self.clock = clock
        catalog = LiveTVPrototypeModel(now: clock(), channels: [], preferencesStore: preferencesStore)
        imports = LiveTVPrototypeImportModel(
            loader: loader, serverProviderResolver: serverProviderResolver, cache: cache,
            catalogIsAuthorized: { admission.isClearing || admission.isCurrent }
        )
    }

    deinit { refreshTask?.cancel() }

    /// Cache-only hydration binds mapping/identity controls without opening network requests.
    public func restore() async { await load(refresh: false) }

    public func refresh() async { await load(refresh: true) }

    public func requestRefresh() {
        if refreshTask != nil, isLoading, isCurrent { return }
        refreshTask?.cancel()
        refreshRequest &+= 1
        let request = refreshRequest
        refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
            if self.refreshRequest == request { self.refreshTask = nil }
        }
    }

    /// Call synchronously on profile lock/switch or authority changes, before scheduling a reload.
    public func invalidate() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequest &+= 1
        revision &+= 1
        isLoading = false
        admission.snapshot = nil
        clearCatalog()
    }

    private func load(refresh: Bool) async {
        guard !Task.isCancelled else { return }
        let authority: LiveTVSourcesCatalogAuthority
        do {
            guard let current = try admission.authority(),
                  current.authorization.profileID == admission.profileID else {
                invalidate()
                issue = .authorization
                return
            }
            try current.configuration.validate()
            authority = current
        } catch {
            invalidate()
            issue = .configuration
            return
        }
        if isLoading, admission.snapshot == authority, activeRefresh || !refresh { return }
        if admission.snapshot != authority || isLoading {
            revision &+= 1
            guard clearCatalog() else {
                admission.snapshot = nil
                isLoading = false
                return
            }
        }
        admission.snapshot = authority
        revision &+= 1
        let request = revision
        isLoading = true
        activeRefresh = refresh
        issue = nil
        defer { if revision == request { isLoading = false } }
        do {
            catalog.synchronizeClock(to: clock())
            try imports.applyConfiguration(
                authority.authorization.filtering(authority.configuration), into: catalog
            )
            if refresh {
                await imports.reload(into: catalog)
            } else {
                await imports.restoreCachedCatalog(into: catalog, now: catalog.now)
            }
            guard revision == request else { return }
            guard !Task.isCancelled, admission.isCurrent else {
                let authorizationChanged = !admission.isCurrent
                invalidate()
                if authorizationChanged { issue = .authorization }
                return
            }
            if imports.cacheFailure != nil || imports.playlistFailure != nil || imports.guideFailure != nil
                || imports.serverSources.contains(where: { $0.failure != nil || $0.guideFailure != nil }) {
                issue = .catalog
            }
        } catch {
            guard revision == request else { return }
            let failure: Issue = admission.isCurrent ? .catalog : .authorization
            invalidate()
            issue = failure
        }
    }

    @discardableResult
    private func clearCatalog() -> Bool {
        admission.isClearing = true
        defer { admission.isClearing = false }
        do {
            try imports.applyConfiguration(.empty, into: catalog)
            return true
        } catch {
            issue = .catalog
            return false
        }
    }
}

@MainActor
@Observable
private final class LiveTVSourcesCatalogAdmission {
    let profileID: String
    let authority: @MainActor () throws -> LiveTVSourcesCatalogAuthority?
    var snapshot: LiveTVSourcesCatalogAuthority?
    var isClearing = false

    init(profileID: String, authority: @escaping @MainActor () throws -> LiveTVSourcesCatalogAuthority?) {
        self.profileID = profileID
        self.authority = authority
    }

    var isCurrent: Bool {
        guard let snapshot else { return false }
        do {
            guard let current = try authority(), current.authorization.profileID == profileID else { return false }
            return current == snapshot
        } catch {
            return false
        }
    }
}
#endif
