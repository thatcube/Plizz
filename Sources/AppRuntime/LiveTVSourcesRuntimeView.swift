#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import SwiftUI
import UIKit

public struct LiveTVSourcesRuntimeView<Content: View>: View {
    private let profileID: String
    private let namespace: String?
    private let profiles: ProfilesModel
    private let accounts: AccountsProvidersModel
    private let cache: LiveTVIndexedCache
    private let isPresented: Bool
    private let isProfileAuthorized: @MainActor () -> Bool
    private let content: (LiveTVSourcesRuntime) -> Content

    public init(
        profileID: String,
        namespace: String?,
        profiles: ProfilesModel,
        accounts: AccountsProvidersModel,
        cache: LiveTVIndexedCache,
        isPresented: Bool = true,
        isProfileAuthorized: @escaping @MainActor () -> Bool = { true },
        @ViewBuilder content: @escaping (LiveTVSourcesRuntime) -> Content
    ) {
        self.profileID = profileID
        self.namespace = namespace
        self.profiles = profiles
        self.accounts = accounts
        self.cache = cache
        self.isPresented = isPresented
        self.isProfileAuthorized = isProfileAuthorized
        self.content = content
    }

    public var body: some View {
        LiveTVSourcesRuntimeHost(
            profileID: profileID, namespace: namespace, profiles: profiles,
            accounts: accounts, cache: cache, isPresented: isPresented,
            isProfileAuthorized: isProfileAuthorized, content: content
        )
        .id(Scope(
            profileID: profileID, namespace: namespace,
            profiles: ObjectIdentifier(profiles), accounts: ObjectIdentifier(accounts),
            lockRevision: profiles.activeProfile.effectiveLockRevision
        ))
    }

    private struct Scope: Hashable {
        let profileID: String
        let namespace: String?
        let profiles: ObjectIdentifier
        let accounts: ObjectIdentifier
        let lockRevision: ProfileLockRevision?
    }
}

private struct LiveTVSourcesRuntimeHost<Content: View>: View {
    let profileID: String
    let namespace: String?
    let profiles: ProfilesModel
    let accounts: AccountsProvidersModel
    let cache: LiveTVIndexedCache
    let isPresented: Bool
    let isProfileAuthorized: @MainActor () -> Bool
    let content: (LiveTVSourcesRuntime) -> Content
    @State private var runtime: LiveTVSourcesRuntime?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let runtime {
                content(runtime)
                    .background(LiveTVSourcesLifetime(runtime: runtime).frame(width: 0, height: 0))
                    .onChange(of: runtime.scanBinding.coordinator.scanHiddenChannelIDs) { _, _ in
                        runtime.scanBinding.synchronizeVisibility()
                    }
                    .onChange(of: runtime.authorityID) { _, _ in
                        runtime.invalidate()
                    }
                    .task(id: AdmissionRequest(
                        identity: runtime.authorityID,
                        isPresented: isPresented,
                        isSceneActive: scenePhase == .active
                    )) {
                        guard isPresented, scenePhase == .active else {
                            runtime.invalidate()
                            return
                        }
                        await runtime.restore()
                    }
            } else {
                ProgressView("Loading sources")
            }
        }
        .task {
            guard runtime == nil else { return }
            let expectedLock = profiles.activeProfile.effectiveLockRevision
            let instance = LiveTVSourcesRuntime(
                profileID: profileID,
                store: LiveTVSourceStorage.approvalAwareStore(profileID: profileID, namespace: namespace),
                approvals: LiveTVSourceApprovalStore(profileID: profileID, namespace: namespace),
                cache: cache,
                loader: LiveTVCatalogStorage.loader(profileID: profileID, namespace: namespace),
                preferencesStore: LiveTVPreferencesStore(namespace: namespace),
                scanCoordinator: LiveTVChannelScanCoordinator(
                    store: LiveTVChannelHealthStore(namespace: profileID)
                ),
                context: { [profiles, accounts, profileID, namespace, isProfileAuthorized, expectedLock] in
                    guard isProfileAuthorized(),
                          profiles.activeProfileID == profileID,
                          profiles.activeNamespace == namespace,
                          profiles.activeProfile.effectiveLockRevision == expectedLock,
                          LiveTVLibraryStorage.preferencesNamespace(
                            profileID: profileID, profiles: profiles
                          ) == namespace,
                          !profiles.activeProfile.awaitsIdentity(amongAccounts: accounts.activeAccountIDs)
                    else { return nil }
                    return LiveTVSourceApprovalContext(profiles: profiles)
                },
                accountAuthorizationID: { [accounts] in accounts.liveTVAuthorizationID },
                serverProviderResolver: { [accounts] id in accounts.liveTVProviderResolver()(id) }
            )
            if isPresented, scenePhase == .active { instance.activate() }
            runtime = instance
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { runtime?.invalidate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { runtime?.invalidate() }
        }
    }

    private struct AdmissionRequest: Hashable {
        let identity: String?
        let isPresented: Bool
        let isSceneActive: Bool
    }
}

/// Navigation pushes only hide the owner; dismantling removes its presentation.
/// Do not use onDisappear here: source/guide editors must retain their importer.
private struct LiveTVSourcesLifetime: UIViewRepresentable {
    let runtime: LiveTVSourcesRuntime

    func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.runtime?.invalidate()
    }

    final class Coordinator {
        weak var runtime: LiveTVSourcesRuntime?
        init(runtime: LiveTVSourcesRuntime) { self.runtime = runtime }
    }
}
#endif
