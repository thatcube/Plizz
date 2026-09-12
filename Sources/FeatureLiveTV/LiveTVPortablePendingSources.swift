#if DEBUG
import CoreModels
import CoreUI
import SwiftUI

/// Sources-page section for peer descriptors that cannot be transferred safely.
/// Entering the address locally keeps the portable source ID, so its saved
/// channel preferences are not detached by a second, newly minted source.
public struct LiveTVPortablePendingSources: View {
    private let directory: URL
    private let sourceStore: any LiveTVSourcesStoring
    private let onChange: () -> Void
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?
    @State private var pending: [String: LiveTVPortableSource] = [:]
    @State private var localFiles: [String: LiveTVPortableSource] = [:]
    @State private var unavailable = false

    public init(
        directory: URL, sourceStore: any LiveTVSourcesStoring,
        onChange: @escaping () -> Void = {}
    ) {
        self.directory = directory
        self.sourceStore = sourceStore
        self.onChange = onChange
    }

    public var body: some View {
        if let profiles {
            VStack(spacing: 0) {
                if unavailable || !pending.isEmpty || !localFiles.isEmpty {
                    SettingsSectionGroup {
                        if unavailable {
                            Text("Synced sources are unavailable.").settingsRowSecondary()
                        }
                        ForEach(pending.keys.sorted(), id: \.self) { sourceID in
                            if let source = pending[sourceID] {
                                NavigationLink {
                                    LiveTVPortablePlaylistSetup(
                                        sourceID: sourceID, descriptor: source, profiles: profiles,
                                        sourceStore: sourceStore, directory: directory
                                    ) {
                                        reload(profileID: profiles.activeProfileID)
                                        onChange()
                                    }
                                } label: {
                                    SettingsRowLabel(icon: "icloud.and.arrow.down", title: "Set up IPTV source", trailing: {
                                        Text(source.name).settingsRowSecondary()
                                    })
                                }
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                                .accessibilityIdentifier("live-tv-setup-synced-source-\(sourceID)")
                            }
                        }
                        if !pending.isEmpty {
                            Text("Playlist addresses stay on each device. Enter the address here to use this source.")
                                .settingsRowSecondary()
                        }
                        ForEach(localFiles.keys.sorted(), id: \.self) { sourceID in
                            if let source = localFiles[sourceID] {
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text("This playlist file is stored on another device.")
                                        .settingsRowSecondary()
                                }
                            }
                        }
                    }
                }
            }
            .task(id: profiles.activeProfileID) { reload(profileID: profiles.activeProfileID) }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange).receive(on: DispatchQueue.main)) { _ in
                reload(profileID: profiles.activeProfileID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply).receive(on: DispatchQueue.main)) { notification in
                guard notification.object as? String == profiles.activeProfileID else { return }
                reload(profileID: profiles.activeProfileID)
            }
        }
    }

    private func reload(profileID: String) {
        do {
            let adapter = LiveTVPortableSyncAdapter(
                directory: directory, profileID: profileID,
                namespace: profileID == profiles?.rootNamespaceOwnerID ? nil : profileID
            )
            let report = adapter.isEnabled ? try adapter.pending(sourceStore: sourceStore) : LiveTVPortableImport()
            pending = report.pendingPlaylists
            localFiles = report.localFileSources
            unavailable = false
        } catch {
            pending = [:]
            localFiles = [:]
            unavailable = true
        }
    }
}

private struct LiveTVPortablePlaylistSetup: View {
    let sourceID: String
    let descriptor: LiveTVPortableSource
    let profiles: ProfilesModel
    let sourceStore: any LiveTVSourcesStoring
    let directory: URL
    let onChange: () -> Void
    @State private var access: LiveTVSourceManagementAccess
    @Environment(\.dismiss) private var dismiss
    private let profileID: String

    init(
        sourceID: String, descriptor: LiveTVPortableSource, profiles: ProfilesModel,
        sourceStore: any LiveTVSourcesStoring, directory: URL, onChange: @escaping () -> Void
    ) {
        self.sourceID = sourceID
        self.descriptor = descriptor
        self.profiles = profiles
        self.sourceStore = sourceStore
        self.directory = directory
        self.onChange = onChange
        profileID = profiles.activeProfileID
        _access = State(initialValue: LiveTVSourceManagementAccess(profiles: profiles))
    }

    var body: some View {
        if access.canManage {
            LiveTVPlaylistEditor(name: descriptor.name) { input in
                guard access.canManage, profiles.activeProfileID == profileID else {
                    throw LiveTVSourceApprovalError.staleAuthority
                }
                let adapter = LiveTVPortableSyncAdapter(
                    directory: directory, profileID: profileID,
                    namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
                )
                guard adapter.isEnabled,
                      try adapter.pending(sourceStore: sourceStore).pendingPlaylists[sourceID] == descriptor else {
                    throw LiveTVSourcesStoreError.saveFailed
                }
                var configuration = try sourceStore.load()
                guard !configuration.playlists.contains(where: { $0.id == sourceID }),
                      !configuration.servers.contains(where: { $0.id == sourceID }) else {
                    throw LiveTVSourcesStoreError.saveFailed
                }
                configuration.playlists.append(LiveTVPlaylistSource(
                    id: sourceID, name: input.name, playlistURL: input.playlistURL,
                    guideURLs: input.guideURLs, isEnabled: descriptor.isEnabled,
                    discoversPlaylistGuides: descriptor.discoversPlaylistGuides ?? true,
                    guideLookbackDays: descriptor.guideLookbackDays ?? 1,
                    guideLookaheadDays: descriptor.guideLookaheadDays ?? 7
                ))
                // Explicit setup preserves paused state and never manufactures a
                // parental approval. The source-level approval action remains visible.
                try sourceStore.save(configuration)
                onChange()
            }
        } else {
            PINEntryScaffold(
                title: KidsProfileCopy.parentalPINEnter,
                name: Text(KidsProfileCopy.parentalPIN),
                errorMessage: access.errorMessage,
                onSubmit: { access.unlock($0) },
                onCancel: { dismiss() }
            ) {
                PINBadge {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                }
            }
        }
    }
}
#endif
