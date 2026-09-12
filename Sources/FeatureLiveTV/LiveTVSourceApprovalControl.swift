#if DEBUG
import CoreModels
import CoreUI
import Observation
import SwiftUI

/// Source-level control for the existing Sources page. Intentionally absent for
/// unrestricted profiles; a grant covers the entire source, never one channel.
public struct LiveTVSourceApprovalControl: View {
    let source: LiveTVPlaylistSource
    let sourceStore: any LiveTVSourcesStoring
    var onChange: () -> Void = {}
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    public init(
        source: LiveTVPlaylistSource, sourceStore: any LiveTVSourcesStoring,
        onChange: @escaping () -> Void = {}
    ) {
        self.source = source
        self.sourceStore = sourceStore
        self.onChange = onChange
    }

    public var body: some View {
        if let profiles, profiles.activeProfile.isKids {
            LiveTVProfileSourceApprovalControl(
                source: source, sourceStore: sourceStore, profiles: profiles, onChange: onChange
            )
            .id(profiles.activeProfileID)
        }
    }
}

private struct LiveTVProfileSourceApprovalControl: View {
    let source: LiveTVPlaylistSource
    let onChange: () -> Void
    @State private var model: LiveTVSourceApprovalModel
    @State private var showsPIN = false

    init(
        source: LiveTVPlaylistSource, sourceStore: any LiveTVSourcesStoring,
        profiles: ProfilesModel, onChange: @escaping () -> Void
    ) {
        self.source = source
        self.onChange = onChange
        _model = State(initialValue: LiveTVSourceApprovalModel(
            profiles: profiles, sourceStore: sourceStore
        ))
    }

    var body: some View {
        VStack(alignment: .leading) {
            switch model.status(source: source) {
            case .approved:
                Button {
                    model.revoke(source: source)
                    onChange()
                } label: {
                    SettingsRowLabel(icon: "lock.open", title: "Revoke source approval")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-revoke-source-\(source.id)")
                Text("All channels in this source are approved for this profile.")
                    .settingsRowSecondary()
            case .needsApproval:
                Button {
                    model.beginApproval(source: source)
                    showsPIN = true
                } label: {
                    SettingsRowLabel(icon: "lock", title: "Approve this source")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-approve-source-\(source.id)")
                Text("One Parental PIN approval allows all channels in this source.")
                    .settingsRowSecondary()
            case .parentalPINRequired:
                Text("Set a Parental PIN in Profiles before approving this source.")
                    .settingsRowSecondary()
            case .disabled:
                Text("Source paused").settingsRowSecondary()
            case .unrestricted:
                EmptyView()
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showsPIN, onDismiss: { model.cancelApproval() }) {
            PINEntryScaffold(
                title: KidsProfileCopy.parentalPINEnter,
                name: Text(KidsProfileCopy.parentalPIN),
                errorMessage: model.error,
                onSubmit: {
                    if model.approve(pin: $0) {
                        showsPIN = false
                        onChange()
                    }
                },
                onCancel: { showsPIN = false }
            ) {
                PINBadge {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange).receive(on: DispatchQueue.main)) { _ in
            model.refresh()
        }
    }
}

@MainActor
@Observable
final class LiveTVSourceApprovalModel {
    private struct Pending {
        let source: LiveTVPlaylistSource
        let context: LiveTVSourceApprovalContext
    }

    @ObservationIgnored private let profiles: ProfilesModel
    @ObservationIgnored private let sourceStore: any LiveTVSourcesStoring
    @ObservationIgnored private let approvalStore: LiveTVSourceApprovalStore
    private let profileID: String
    private var pending: Pending?
    private var revision = 0
    private(set) var error: LocalizedStringResource?

    init(
        profiles: ProfilesModel, sourceStore: any LiveTVSourcesStoring,
        defaults: UserDefaults = .standard
    ) {
        self.profiles = profiles
        self.sourceStore = sourceStore
        profileID = profiles.activeProfileID
        approvalStore = LiveTVSourceApprovalStore(
            defaults: defaults, profileID: profiles.activeProfileID,
            namespace: profiles.activeProfileID == profiles.rootNamespaceOwnerID ? nil : profiles.activeProfileID
        )
    }

    func status(source: LiveTVPlaylistSource) -> LiveTVSourceApprovalStatus {
        _ = revision
        guard profiles.activeProfileID == profileID else { return .needsApproval }
        return (try? approvalStore.status(source: source, context: context)) ?? .needsApproval
    }

    func beginApproval(source: LiveTVPlaylistSource) {
        pending = Pending(source: source, context: context)
        error = nil
    }

    func cancelApproval() { pending = nil }
    func refresh() { revision &+= 1 }

    func approve(pin: String) -> Bool {
        guard let pending, profiles.activeProfileID == profileID, pending.context == context else {
            error = "This profile changed. Reopen the source and try again."
            return false
        }
        guard profiles.matchesParentalPIN(pin), let permit = context.authorize(parentalPIN: pin) else {
            error = ProfileLockCopy.incorrectPIN
            return false
        }
        do {
            let latest = try sourceStore.load()
            guard latest.playlists.first(where: { $0.id == pending.source.id }) == pending.source else {
                error = "This source changed. Reopen it before approving."
                return false
            }
            try approvalStore.approve(source: pending.source, context: context, permit: permit)
            self.pending = nil
            error = nil
            refresh()
            return true
        } catch {
            self.error = "Source approval couldn't be saved. Access remains restricted."
            return false
        }
    }

    func revoke(source: LiveTVPlaylistSource) {
        guard profiles.activeProfileID == profileID else { return }
        do {
            try approvalStore.revoke(sourceID: source.id)
            error = nil
            refresh()
        } catch {
            self.error = "Source approval couldn't be changed. Try again."
        }
    }

    private var context: LiveTVSourceApprovalContext {
        LiveTVSourceApprovalContext(
            profile: profiles.activeProfile,
            parentalPIN: profiles.parentalPIN,
            activeAccountIDs: profiles.activeAccountIDs(for: profileID, fallback: [])
        )
    }
}
#endif
