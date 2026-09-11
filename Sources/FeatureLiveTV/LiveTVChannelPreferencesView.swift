#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Shared by the channel context menu and profile settings; never edits a server library item.
public struct LiveTVChannelPreferencesView: View {
    private let model: LiveTVPrototypeModel
    private let channelID: String
    @State private var name: String
    @State private var category: String
    @State private var language: String
    @State private var country: String
    @State private var failed = false

    public init(model: LiveTVPrototypeModel, channelID: String) {
        self.model = model
        self.channelID = channelID
        let value = model.channelOverrides[channelID]
        _name = State(initialValue: value?.name ?? "")
        _category = State(initialValue: value?.category ?? "")
        _language = State(initialValue: value?.language ?? "")
        _country = State(initialValue: value?.country ?? "")
    }

    public var body: some View {
        LiveTVSettingsPage(title: "Channel preferences") {
            SettingsSectionGroup("Custom metadata") {
                TextField("Name", text: $name)
                TextField("Category", text: $category)
                TextField("Language", text: $language)
                TextField("Country", text: $country)
                Button("Save metadata") {
                    failed = !model.setMetadataOverride(.init(
                        name: optional(name), category: optional(category),
                        language: optional(language), country: optional(country)
                    ), channelID: channelID)
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                Button("Use source metadata") {
                    failed = !model.setMetadataOverride(nil, channelID: channelID)
                    if !failed { name = ""; category = ""; language = ""; country = "" }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            } footer: {
                Text("Blank fields use source metadata. These changes are personal labels, not programme information.")
            }
            if model.favoriteIDs.contains(channelID) {
                SettingsSectionGroup("Favorite order") {
                    Button("Move earlier") { move(-1) }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .disabled(model.favoriteOrder.first == channelID)
                    Button("Move later") { move(1) }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .disabled(model.favoriteOrder.last == channelID)
                }
            }
            if failed {
                SettingsSectionGroup { Text("Channel preferences couldn't be saved. Please retry.") }
            }
        }
    }

    private func optional(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func move(_ offset: Int) {
        var order = model.favoriteOrder
        guard let index = order.firstIndex(of: channelID), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        failed = !model.setFavoriteOrder(order)
    }
}

public struct LiveTVUnavailableFavoritesView: View {
    private let model: LiveTVPrototypeModel
    private let imports: LiveTVPrototypeImportModel?
    private let openSources: () -> Void

    public init(
        model: LiveTVPrototypeModel, imports: LiveTVPrototypeImportModel? = nil, openSources: @escaping () -> Void
    ) {
        self.model = model
        self.imports = imports
        self.openSources = openSources
    }

    public var body: some View {
        LiveTVSettingsPage(title: "Unavailable favorites") {
            SettingsSectionGroup {
                ForEach(model.unavailableFavorites) { channel in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(channel.name)
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        if let imports, imports.supportsDurableCatalog {
                            NavigationLink("Link to an imported channel") {
                                LiveTVFavoriteRecoveryPicker(imports: imports, model: model, previousID: channel.id)
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                        Button("Remove favorite") { model.toggleFavorite(channel.id) }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                }
                Button("Review sources", action: openSources)
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            } footer: {
                Text("Favorites stay saved while their source is unavailable or disabled. A similar name never replaces a saved channel.")
            }
        }
    }
}

private struct LiveTVFavoriteRecoveryPicker: View {
    let imports: LiveTVPrototypeImportModel
    let model: LiveTVPrototypeModel
    let previousID: String
    @State private var query = ""
    @State private var selectedID: String?
    @State private var failed = false
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LiveTVSettingsPage(title: "Restore favorite") {
            SettingsSectionGroup {
                TextField("Find the same channel", text: $query)
                    .autocorrectionDisabled()
                ForEach(Array(model.unhiddenCatalogChannels.lazy.filter {
                    $0.source == .iptv
                        && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
                }.prefix(200))) { channel in
                    Button {
                        selectedID = channel.id
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(channel.name)
                            if let country = channel.country {
                                Text(country).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .disabled(saving)
                }
                if failed { Text("This favorite couldn't be restored. Its saved identity has been kept.") }
            }
        }
        .confirmationDialog("Confirm this is the same station and feed?", isPresented: Binding(
            get: { selectedID != nil }, set: { if !$0 { selectedID = nil } }
        ), titleVisibility: .visible) {
            if let channelID = selectedID {
                Button("Restore favorite") {
                    selectedID = nil
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try await imports.recoverUnavailableFavorite(previousID: previousID, channelID: channelID)
                            dismiss()
                        } catch { failed = true }
                    }
                }
            }
        } message: {
            Text("A similar name is not enough. Confirm the regional feed before transferring saved channel preferences.")
        }
    }
}
#endif
