#if DEBUG && canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct LiveTVLibraryRuntimeView<Content: View>: View {
    private let profileID: String
    private let profiles: ProfilesModel
    private let accounts: AccountsProvidersModel?
    private let content: (LiveTVLibraryRuntime) -> Content

    public init(
        profileID: String,
        profiles: ProfilesModel,
        accounts: AccountsProvidersModel?,
        @ViewBuilder content: @escaping (LiveTVLibraryRuntime) -> Content
    ) {
        self.profileID = profileID
        self.profiles = profiles
        self.accounts = accounts
        self.content = content
    }

    public var body: some View {
        LiveTVLibraryRuntimeHost(
            runtime: LiveTVLibraryStorage.runtime(profileID: profileID, profiles: profiles),
            accounts: accounts,
            content: content
        )
        .id(Scope(
            profileID: profileID,
            namespace: LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profiles),
            profiles: ObjectIdentifier(profiles)
        ))
    }

    private struct Scope: Hashable {
        let profileID: String
        let namespace: String?
        let profiles: ObjectIdentifier
    }
}

private struct LiveTVLibraryRuntimeHost<Content: View>: View {
    @State private var runtime: LiveTVLibraryRuntime
    @State private var pendingPortableChanges = false
    private let accounts: AccountsProvidersModel?
    private let content: (LiveTVLibraryRuntime) -> Content

    init(
        runtime: LiveTVLibraryRuntime,
        accounts: AccountsProvidersModel?,
        @ViewBuilder content: @escaping (LiveTVLibraryRuntime) -> Content
    ) {
        _runtime = State(initialValue: runtime)
        self.accounts = accounts
        self.content = content
    }

    var body: some View {
        content(runtime)
            .task(id: Request(authorization: accounts?.liveTVAuthorizationID ?? "", reload: runtime.refreshRequest)) {
                await runtime.refresh(accounts: accounts)
            }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply)) { notification in
                guard notification.object as? String == runtime.profileID else { return }
                if LiveTVPlaybackIdentityHold.isHeld(profileID: runtime.profileID) {
                    pendingPortableChanges = true
                } else {
                    runtime.applyPortableChanges()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPlaybackIdentityDidBecomeIdle)) { notification in
                guard notification.object as? String == runtime.profileID, pendingPortableChanges,
                      !LiveTVPlaybackIdentityHold.isHeld(profileID: runtime.profileID) else { return }
                pendingPortableChanges = false
                runtime.applyPortableChanges()
            }
    }

    private struct Request: Hashable {
        let authorization: String
        let reload: Int
    }
}
#endif
