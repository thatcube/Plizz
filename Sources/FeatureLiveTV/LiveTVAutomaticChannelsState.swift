#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI

public struct LiveTVAutomaticChannelsState {
    public let enabled: Bool
    public let isWorking: Bool
    public let issue: LibraryChannelError?
    public let channelCount: Int
    public let skippedItemCount: Int
    public let unavailableSources: [LibraryChannelSourceFailure]
    public let preparation: LibraryChannelPreparationProgress?
    public let setEnabled: @MainActor (Bool) async -> Void
    public let retry: @MainActor () -> Void

    public init(
        enabled: Bool, isWorking: Bool, issue: LibraryChannelError?,
        channelCount: Int, skippedItemCount: Int,
        setEnabled: @escaping @MainActor (Bool) async -> Void,
        retry: @escaping @MainActor () -> Void,
        unavailableSources: [LibraryChannelSourceFailure] = [],
        preparation: LibraryChannelPreparationProgress? = nil
    ) {
        self.enabled = enabled
        self.isWorking = isWorking
        self.issue = issue
        self.channelCount = channelCount
        self.skippedItemCount = skippedItemCount
        self.setEnabled = setEnabled
        self.retry = retry
        self.unavailableSources = unavailableSources
        self.preparation = preparation
    }

    var needsEmptyState: Bool { enabled || isWorking || issue != nil }

    var status: LiveTVAutomaticChannelsStatus {
        if isWorking { return .preparing }
        if let issue { return .failed(issue) }
        if !enabled { return .disabled }
        return channelCount > 0 ? .ready : .empty
    }
}

enum LiveTVAutomaticChannelsStatus: Equatable {
    case disabled, preparing, ready, empty, failed(LibraryChannelError)

    var title: LocalizedStringResource {
        switch self {
        case .disabled: "Your library, on TV"
        case .preparing: "Preparing Plozz channels"
        case .ready: "Your automatic lineup"
        case .empty: "No Plozz channels yet"
        case .failed: "Plozz channels need attention"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .disabled:
            "Turn this profile's authorized Plex, Jellyfin or Emby library into themed channels with automatic guides. No channel setup needed."
        case .preparing:
            "Finding movies and episodes in this profile's authorized libraries and building their guides."
        case .ready:
            "Your lineup updates automatically as your authorized library changes. Find these channels in the guide, search and favorites."
        case .empty, .failed(.emptyCatalog):
            "No eligible movies or episodes are available yet. Plozz channels need an authorized Plex, Jellyfin or Emby library with playable titles and known durations."
        case .failed(.sourceUnavailable):
            "Your saved server libraries couldn't be loaded. Check the connection details below and retry. You don't need to add the same account again."
        case .failed(.catalogChanged):
            "Your library changed while the lineup was being prepared. Retry to use the latest movies and episodes."
        case .failed(let issue):
            issue.message
        }
    }
}

@MainActor
@Observable
final class LiveTVAutomaticChannelsAction {
    private(set) var isUpdating = false

    func setEnabled(
        _ enabled: Bool, state: LiveTVAutomaticChannelsState,
        canManage: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, canManage(), !isUpdating,
              !state.isWorking || !enabled, enabled != state.enabled else { return }
        isUpdating = true
        defer { isUpdating = false }
        await state.setEnabled(enabled)
    }

    func retry(state: LiveTVAutomaticChannelsState, canManage: @MainActor () -> Bool) {
        guard canManage(), !isUpdating, !state.isWorking, state.enabled || state.issue != nil else { return }
        state.retry()
    }
}

struct LiveTVAutomaticChannelsSection: View {
    let state: LiveTVAutomaticChannelsState
    let canManage: @MainActor () -> Bool
    @State private var action = LiveTVAutomaticChannelsAction()
    @State private var update: Task<Void, Never>?

    var body: some View {
        SettingsSectionGroup("Automatic lineup") {
            Toggle(isOn: Binding(
                get: { state.enabled },
                set: { enabled in
                    update = Task {
                        await action.setEnabled(enabled, state: state, canManage: canManage)
                    }
                }
            )) {
                Text("Enable Plozz channels")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(action.isUpdating || (state.isWorking && !state.enabled))
            .accessibilityIdentifier("live-tv-automatic-enabled")
            LiveTVAutomaticChannelsStatusView(state: state)
            if (state.enabled || state.issue != nil), !state.isWorking {
                Button {
                    action.retry(state: state, canManage: canManage)
                } label: {
                    if state.status == .ready {
                        SettingsRowLabel(icon: nil, title: "Refresh Plozz channels")
                    } else {
                        SettingsRowLabel(icon: nil, title: "Retry Plozz channels")
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(action.isUpdating)
                .accessibilityIdentifier("live-tv-automatic-retry")
            }
        } footer: {
            Text("Uses all libraries this profile is allowed to access. No public channels are added. IPTV playlists do not need a media server. Custom channels below are optional and keep their own schedules.")
        }
        .onDisappear { update?.cancel(); update = nil }
    }
}

struct LiveTVAutomaticChannelsStatusView: View {
    let state: LiveTVAutomaticChannelsState

    var body: some View {
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
            if state.isWorking {
                if let preparation = state.preparation {
                    LiveTVPreparationProgressView(progress: preparation)
                } else {
                    ProgressView("Preparing Plozz channels")
                        .accessibilityIdentifier("live-tv-automatic-progress")
                }
            } else {
                Text(state.status.title).font(.headline)
                Text(state.status.detail).settingsRowSecondary()
            }
            if state.enabled, state.channelCount > 0 {
                Text("\(state.channelCount) automatic channels")
            }
            if state.skippedItemCount > 0 {
                Text("\(state.skippedItemCount) library items couldn't be scheduled because their duration or metadata is unavailable.")
                    .settingsRowSecondary()
            }
            if !state.unavailableSources.isEmpty {
                Text(state.channelCount > 0
                    ? "Channels from available libraries are ready. Some servers still need attention."
                    : "These saved connections couldn't load their libraries.")
                    .settingsRowSecondary()
                ForEach(state.unavailableSources) { source in
                    VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xSmall) {
                        Text(source.serverName).font(.headline)
                        Text(source.reason.message).settingsRowSecondary()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct LiveTVAutomaticChannelsEmptyView: View {
    let state: LiveTVAutomaticChannelsState
    let manage: () -> Void

    var body: some View {
        ContentUnavailableView {
            if state.status == .ready {
                Label("Preparing your guide", systemImage: "calendar")
            } else {
                Label {
                    Text(state.status.title)
                } icon: {
                    Image(systemName: "calendar")
                }
            }
        } description: {
            if state.isWorking, let preparation = state.preparation {
                LiveTVPreparationProgressView(progress: preparation)
                    .frame(maxWidth: 680, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.top, PlozzTheme.Spacing.medium)
            } else if state.status == .ready {
                Text("Your Plozz channels are enabled. Their programmes will appear here when the guide is ready.")
            } else {
                Text(state.status.detail)
            }
        } actions: {
            if state.isWorking, state.preparation == nil {
                ProgressView().accessibilityLabel("Preparing Plozz channels")
            }
            Button(action: manage) {
                Text("Manage Plozz channels")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, PlozzTheme.Spacing.large)
                    .padding(.vertical, PlozzTheme.Spacing.medium)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-automatic-manage")
        }
    }
}
#endif
