#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVSetupWelcome: View {
    let addPlaylist: () -> Void
    let useServer: () -> Void
    var issue: LocalizedStringResource? = nil
    var serverStatuses: [LiveTVServerEnrollmentStatus] = []
    var createChannel: (() -> Void)?
    var retryLibrary: (() -> Void)?
    var automaticChannels: LiveTVAutomaticChannelsState? = nil
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let inset = geometry.size.width >= 900 ? PlozzTheme.Spacing.xxxLarge : PlozzTheme.Spacing.large
            let contentWidth = min(
                PlozzTheme.Metrics.settingsContentMaxWidth, geometry.size.width - inset * 2)
            let choiceCount = createChannel == nil ? 2 : 3
            let fitsRow = contentWidth >= CGFloat(choiceCount) * 320
                + CGFloat(choiceCount - 1) * PlozzTheme.Spacing.large
                && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xLarge) {
                    LiveTVSetupIntroduction()
                    let layout = fitsRow
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: PlozzTheme.Spacing.large))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: PlozzTheme.Spacing.large))
                    layout {
                        LiveTVSetupChoice(
                            title: "IPTV playlist",
                            detail: "Add channels with an M3U or M3U8 playlist URL.",
                            actionTitle: "Add playlist",
                            symbol: "list.bullet.rectangle",
                            action: addPlaylist
                        )
                        .accessibilityIdentifier("live-tv-setup-playlist")
                        LiveTVSetupChoice(
                            title: "Media server",
                            detail: LocalizedStringResource(
                                "liveTV.setup.server.detail",
                                defaultValue: "Watch Live TV from Jellyfin or Emby. Plex supports guide browsing only.",
                                comment: "Media-server setup choice. Plex Live TV currently supplies guide listings, not live playback; this is separate from generated channels using a Plex media library."
                            ),
                            actionTitle: "Choose server",
                            symbol: "server.rack",
                            action: useServer
                        )
                        .accessibilityIdentifier("live-tv-setup-server")
                        if let createChannel {
                            LiveTVSetupChoice(
                                title: "Plozz channels",
                                detail: "Your authorized library becomes themed channels with automatic guides.",
                                actionTitle: automaticChannels?.enabled == true
                                    ? "Manage channels" : "Enable channels",
                                symbol: "calendar",
                                action: createChannel
                            )
                            .accessibilityIdentifier("live-tv-setup-library")
                            .accessibilityLabel(automaticChannels?.enabled == true
                                ? Text("Manage Plozz channels") : Text("Enable Plozz channels"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let automaticChannels, automaticChannels.needsEmptyState {
                        LiveTVAutomaticChannelsStatusView(state: automaticChannels)
                    }
                    if let issue {
                        Label {
                            Text(issue)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        if let retryLibrary {
                            Button("Retry Plozz channels", action: retryLibrary)
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                    }
                    ForEach(serverStatuses) { status in
                        LiveTVEnrollmentStatusRow(status: status)
                    }
                }
                .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
                .padding(inset)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .background(palette.settingsBackground)
        .foregroundStyle(palette.primaryText)
        .accessibilityIdentifier("live-tv-source-welcome")
    }
}

private struct LiveTVEnrollmentStatusRow: View {
    let status: LiveTVServerEnrollmentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.choice.name).font(.headline)
            if status.phase == .loading {
                ProgressView("Checking Live TV access...")
            } else if let failure = status.failure {
                Text(failure.userDescription).settingsRowSecondary()
            } else if let availability = status.availability {
                LiveTVServerAvailabilitySummary(availability: availability)
            }
        }
    }
}

private struct LiveTVSetupIntroduction: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.medium) {
            Label("Live TV", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(palette.secondaryText)
            Text("Add your channels")
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose a source to start watching. You can add more later.")
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LiveTVSetupChoice: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    let symbol: String
    let action: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.large) {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .font(.title2.weight(.medium))
                    .frame(width: PlozzTheme.Spacing.xxLarge, height: PlozzTheme.Spacing.xxLarge)
                    .frame(width: 64, height: 64)
                    .background(palette.fillSubtle, in: RoundedRectangle(
                        cornerRadius: PlozzTheme.Spacing.medium, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: PlozzTheme.Spacing.small) {
                    Text(actionTitle)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.forward")
                        .font(.callout.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .padding(.top, PlozzTheme.Spacing.medium)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.separator)
                        .frame(height: 1)
                }
            }
            .foregroundStyle(palette.primaryText)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(PlozzTheme.Spacing.large)
        }
        .buttonStyle(SettingsCardButtonStyle())
        .accessibilityLabel(actionTitle)
        .accessibilityHint(detail)
    }
}

#endif
