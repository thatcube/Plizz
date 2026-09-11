#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVServerSetupView: View {
    let sources: LiveTVSourceManagementModel
    let choices: [LiveTVServerChoice]
    let connectServer: (() -> Void)?
    @State private var probe: LiveTVServerProbeModel
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    init(
        sources: LiveTVSourceManagementModel,
        choices: [LiveTVServerChoice],
        resolver: LiveTVServerProviderResolver?,
        connectServer: (() -> Void)? = nil
    ) {
        self.sources = sources
        self.choices = choices
        self.connectServer = connectServer
        _probe = State(initialValue: LiveTVServerProbeModel(resolver: resolver))
    }

    var body: some View {
        LiveTVSettingsPage(title: "Media server") {
            if choices.isEmpty {
                SettingsSectionGroup {
                    ContentUnavailableView(
                        "No connected Live TV servers",
                        systemImage: "server.rack",
                        description: Text("Connect a server and enable it for this profile.")
                    )
                    if let connectServer {
                        Button("Connect a server", systemImage: "plus", action: connectServer)
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    } else {
                        Text("Connect a server in Settings.")
                    }
                }
            } else {
                SettingsSectionGroup {
                    ForEach(choices) { choice in
                        Button {
                            saveFailed = false
                            probe.beginCheck(choice)
                        } label: {
                            SettingsRowLabel(icon: "server.rack", title: Text(choice.name)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(choice.kind.rawValue)
                                    if !choice.userName.isEmpty {
                                        Text(choice.userName).privacySensitive()
                                    }
                                }
                                .font(.caption)
                                .settingsRowSecondary()
                            } trailing: {
                                if sources.configuration.servers.contains(where: { $0.accountID == choice.id && $0.isEnabled }) {
                                    SettingsSelectionIndicator()
                                }
                            }
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                }
            }

            if let choice = probe.choice {
                SettingsSectionGroup(verbatim: choice.name) {
                    if probe.isChecking {
                        ProgressView("Checking Live TV")
                    } else if let failure = probe.failure {
                        Label {
                            Text(failure.userDescription)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    } else if let availability = probe.availability {
                        LiveTVServerAvailabilitySummary(availability: availability)
                    }
                    if saveFailed {
                        Text("Couldn't save the source. Try again.")
                    }
                    Button(action: {
                        if probe.isChecking {
                            probe.cancelCheck()
                        } else if probe.canAdd {
                            do {
                                try sources.addServer(probe.checkedChoice())
                                dismiss()
                            } catch {
                                saveFailed = true
                            }
                        } else {
                            saveFailed = false
                            probe.beginCheck(choice)
                        }
                    }) {
                        if probe.isChecking {
                            Text("Cancel check")
                        } else if probe.canAdd {
                            Text(probe.availability?.status == .unsupportedPlaybackMode ? "Add guide only" : "Add channels")
                        } else {
                            Text("Check again")
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }

            if !choices.isEmpty, let connectServer {
                SettingsSectionGroup {
                    Button("Connect another server", systemImage: "plus", action: connectServer)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
        }
        .task(id: probe.pendingRequest) {
            if let request = probe.pendingRequest { await probe.perform(request) }
        }
        .onDisappear { probe.cancelCheck() }
    }
}

struct LiveTVServerAvailabilitySummary: View {
    let availability: ServerLiveTVAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if availability.status != .available || !availability.hasChannels {
                Text(title).font(.headline)
            }
            if let detail {
                Text(detail).settingsRowSecondary()
            }
            if availability.hasChannels {
                Text("\(availability.channelCount) channels").font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: LocalizedStringResource {
        switch availability.status {
        case .available:
            availability.hasChannels ? "Ready" : "No channels returned"
        case .notConfigured: "Live TV not configured"
        case .noChannels: "No channels returned"
        case .permissionDenied: "Live TV access denied"
        case .subscriptionRequired: "Live TV subscription required"
        case .serviceUnavailable: "Live TV unavailable"
        case .unsupportedAPI: "Unsupported server"
        case .unsupportedPlaybackMode: "Guide only"
        }
    }

    private var detail: LocalizedStringResource? {
        switch availability.status {
        case .available:
            nil
        case .notConfigured:
            "Set up Live TV in the server's dashboard, then try again."
        case .noChannels:
            "Check the server's channels and this account's permissions."
        case .permissionDenied:
            "Ask the server administrator to enable Live TV for this account."
        case .subscriptionRequired:
            "Check the server's Live TV subscription, then try again."
        case .serviceUnavailable:
            "Check the server connection and try again."
        case .unsupportedAPI:
            "Try an IPTV playlist instead."
        case .unsupportedPlaybackMode:
            "Plozz can't play these channels yet."
        }
    }
}
#endif
