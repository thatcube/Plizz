#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVGuideMappingView: View {
    let imports: LiveTVPrototypeImportModel
    let sourceID: String
    let authorize: () throws -> Void
    @State private var query = ""

    var body: some View {
        LiveTVSettingsPage(title: "Guide mapping") {
            SettingsSectionGroup {
                TextField("Find channel", text: $query)
                    .autocorrectionDisabled()
                ForEach(imports.mappingChannels(playlistSourceID: sourceID, query: query)) { channel in
                    NavigationLink {
                        LiveTVChannelGuideMappingView(
                            imports: imports, channelID: channel.id, channelName: channel.name,
                            sourceID: sourceID, authorize: authorize
                        )
                    } label: {
                        SettingsRowLabel(icon: "calendar", title: Text(channel.name), trailing: {
                            if imports.mappingOverrides[channel.id] != nil {
                                Text("Manual").settingsRowSecondary()
                            } else {
                                Text("Automatic").settingsRowSecondary()
                            }
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            } footer: {
                Text("Corrections stay in place when guides refresh. Showing up to 200 matching channels.")
            }
        }
    }
}

private struct LiveTVChannelGuideMappingView: View {
    let imports: LiveTVPrototypeImportModel
    let channelID: String
    let channelName: String
    let sourceID: String
    let authorize: () throws -> Void
    @State private var failed = false
    @State private var saving = false

    var body: some View {
        LiveTVSettingsPage(title: "Guide mapping") {
            SettingsSectionGroup(verbatim: channelName) {
                Button("Use automatic matching") {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try authorize()
                            try await imports.setGuideMapping(channelID: channelID, guideSourceID: nil, guideChannelID: nil)
                            failed = false
                        } catch { failed = true }
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(saving)
                ForEach(imports.guideSources.filter {
                    $0.playlistSourceID == sourceID && imports.enabledSourceIDs.contains($0.id)
                }) { guide in
                    NavigationLink {
                        LiveTVGuideStationPicker(
                            imports: imports, channelID: channelID, guideSourceID: guide.id, authorize: authorize
                        )
                    } label: {
                        SettingsRowLabel(icon: "list.bullet", title: Text(guide.source.name))
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                if failed { Text("Guide mapping couldn't be updated. Reload Sources to check the saved correction.") }
            }
        }
    }
}

private struct LiveTVGuideStationPicker: View {
    let imports: LiveTVPrototypeImportModel
    let channelID: String
    let guideSourceID: String
    let authorize: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var channels: [LiveTVGuideChannelOption] = []
    @State private var failed = false
    @State private var saving = false
    @State private var completedRequest: LiveTVGuideStationRequest?

    var body: some View {
        let request = LiveTVGuideStationRequest(query: query, revision: imports.catalogRevision)
        LiveTVSettingsPage(title: "Choose guide station") {
            SettingsSectionGroup {
                TextField("Find guide station", text: $query)
                    .autocorrectionDisabled()
                ForEach(completedRequest == request && imports.enabledSourceIDs.contains(guideSourceID) ? channels : []) { channel in
                    Button {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                try authorize()
                                try await imports.setGuideMapping(
                                    channelID: channelID, guideSourceID: guideSourceID, guideChannelID: channel.id
                                )
                                dismiss()
                            } catch { failed = true }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(channel.name)
                            if let identifier = channel.displayID {
                                Text(identifier).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .disabled(saving)
                }
                if failed { Text("Guide stations or your correction couldn't be saved. Please retry.") }
            } footer: {
                Text("Showing up to 100 matching stations. Confirm the station and regional feed before choosing.")
            }
        }
        .task(id: request) {
            channels = []
            completedRequest = nil
            do {
                guard imports.enabledSourceIDs.contains(guideSourceID) else { return }
                try await Task.sleep(for: .milliseconds(200))
                let values = try await imports.guideChannelOptions(sourceID: guideSourceID, query: request.query)
                try Task.checkCancellation()
                guard imports.catalogRevision == request.revision else { return }
                channels = values
                completedRequest = request
                failed = false
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}

private struct LiveTVGuideStationRequest: Hashable {
    let query: String
    let revision: Int
}
#endif
