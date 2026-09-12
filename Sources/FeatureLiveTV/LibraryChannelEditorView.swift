#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI

public struct LibraryChannelEditorView: View {
    @State private var model: LibraryChannelEditorModel
    private let prepareLibraries: (@MainActor () async throws -> Void)?

    public init(
        service: LibraryChannelService, editingChannelID: UUID? = nil,
        prepareLibraries: (@MainActor () async throws -> Void)? = nil,
        canManage: @escaping @MainActor () -> Bool = { true }
    ) {
        _model = State(initialValue: LibraryChannelEditorModel(
            service: service, editingChannelID: editingChannelID, canManage: canManage))
        self.prepareLibraries = prepareLibraries
    }

    public var body: some View {
        if model.isAutomaticChannel {
            ContentUnavailableView(
                "Automatic channel",
                systemImage: "calendar",
                description: Text("Plozz manages this channel's schedule. Use the Plozz channels switch to control your automatic lineup.")
            )
        } else {
            LibraryChannelEditorContent(model: model, prepareLibraries: prepareLibraries)
        }
    }
}

private struct LibraryChannelEditorContent: View {
    @Bindable var model: LibraryChannelEditorModel
    let prepareLibraries: (@MainActor () async throws -> Void)?
    @State private var action: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LiveTVSettingsPage(title: model.editingChannelID == nil ? "Create custom channel" : "Edit custom channel") {
            LibraryChannelRecipeFields(recipe: $model.recipe, genres: $model.genres)
                .disabled(model.isWorking)
            LibraryChannelLibraryFields(
                choices: model.service.libraryChoices, selection: $model.recipe.libraries
            )
            .disabled(model.isWorking)
            LibraryChannelRuleFields(
                includes: $model.includeTitles, excludes: $model.excludeTitles,
                genres: $model.genres, ratings: $model.ratings,
                includeUnrated: $model.recipe.includeUnrated, timeZoneID: $model.recipe.timeZoneID,
                seed: $model.seed
            )
            .disabled(model.isWorking)
            if let preview = model.currentPreview {
                LibraryChannelPreviewSection(preview: preview, timeZoneID: model.recipe.timeZoneID)
            }
            SettingsSectionGroup {
                if model.isWorking { ProgressView() }
                if let issue = model.issue { Text(issue.message).foregroundStyle(.secondary) }
                Button {
                    action = Task {
                        if model.currentPreview == nil { await model.preview() }
                        else if await model.save() { dismiss() }
                    }
                } label: {
                    if model.currentPreview == nil {
                        Label("Preview schedule", systemImage: "calendar")
                    } else {
                        Label("Save channel", systemImage: "checkmark")
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(model.isWorking)
                .accessibilityIdentifier("library-channel-preview-save")
            } footer: {
                Text("Schedules are local to this device until shared with their catalog snapshot. Changes begin after already published programmes.")
            }
        }
        .task { await model.load(prepareLibraries: prepareLibraries) }
        .onDisappear { action?.cancel(); action = nil }
    }
}

private struct LibraryChannelRecipeFields: View {
    @Binding var recipe: LibraryChannelRecipe
    @Binding var genres: String
    var body: some View {
        SettingsSectionGroup("Channel") {
            TextField("Channel name", text: $recipe.name)
            Picker("Icon", selection: $recipe.symbol) {
                Label("TV", systemImage: "tv").tag("tv")
                Label("Movies", systemImage: "film").tag("film")
                Label("Comedy", systemImage: "theatermasks").tag("theatermasks")
                Label("Favorites", systemImage: "star").tag("star")
            }
            Picker("Order", selection: $recipe.ordering) {
                ForEach(LibraryChannelOrdering.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            Toggle("Movies", isOn: $recipe.includesMovies)
            Toggle("Episodes", isOn: $recipe.includesEpisodes)
                .disabled(recipe.ordering == .movies)
            Button("Comedy preset") {
                genres = "Comedy"
                recipe.ordering = .roundRobin
                recipe.includesEpisodes = true
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        }
    }
}

private struct LibraryChannelLibraryFields: View {
    let choices: [LibraryChannelLibraryChoice]
    @Binding var selection: [LibraryChannelLibrary]
    var body: some View {
        SettingsSectionGroup("Source libraries") {
            if choices.isEmpty {
                Text("No accessible Plex, Jellyfin or Emby libraries.")
            }
            ForEach(choices) { choice in
                Button {
                    if selection.contains(choice.reference) { selection.removeAll { $0 == choice.reference } }
                    else { selection.append(choice.reference) }
                } label: {
                    HStack {
                        Image(systemName: selection.contains(choice.reference) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(choice.name)
                            Text(choice.serverName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityAddTraits(selection.contains(choice.reference) ? .isSelected : [])
            }
        }
    }
}

private struct LibraryChannelRuleFields: View {
    @Binding var includes: String
    @Binding var excludes: String
    @Binding var genres: String
    @Binding var ratings: String
    @Binding var includeUnrated: Bool
    @Binding var timeZoneID: String
    @Binding var seed: String
    var body: some View {
        SettingsSectionGroup("Rules") {
            TextField("Include movie or show titles", text: $includes)
            TextField("Exclude movie or show titles", text: $excludes)
            TextField("Genres", text: $genres)
            TextField("Allowed ratings", text: $ratings)
            Toggle("Include unrated titles", isOn: $includeUnrated)
            TextField("Scheduling timezone", text: $timeZoneID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Schedule seed", text: $seed)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        } footer: {
            Text("Separate entries with semicolons. An included show schedules its real episodes in order. Empty title, genre and rating fields allow all accessible matches.")
        }
    }
}

private struct LibraryChannelPreviewSection: View {
    let preview: LibraryChannelPreview
    let timeZoneID: String
    var body: some View {
        SettingsSectionGroup("Schedule preview") {
            Text("\(preview.matchingCount) matching items")
            Text(preview.effectiveAt, format: Date.FormatStyle(
                date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: timeZoneID) ?? .gmt
            ))
            .font(.caption)
            if preview.snapshot.ineligibleDurationCount > 0 {
                Text("\(preview.snapshot.ineligibleDurationCount) matching items excluded because their duration is missing or invalid.")
            }
            ForEach(preview.slots) { slot in
                HStack(alignment: .top) {
                    Text(slot.start, format: Date.FormatStyle(
                        date: .omitted, time: .shortened, timeZone: TimeZone(identifier: timeZoneID) ?? .gmt
                    ))
                    VStack(alignment: .leading) {
                        Text(slot.item.seriesTitle ?? slot.item.title)
                        if slot.item.seriesTitle != nil {
                            Text(slot.item.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

@MainActor
@Observable
final class LibraryChannelEditorModel {
    let service: LibraryChannelService
    let editingChannelID: UUID?
    var recipe: LibraryChannelRecipe
    var includeTitles: String
    var excludeTitles: String
    var genres: String
    var ratings: String
    var seed: String
    private(set) var isWorking = false
    private(set) var issue: LibraryChannelError?
    private var reviewed: LibraryChannelPreview?
    private let canManage: @MainActor () -> Bool

    init(
        service: LibraryChannelService, editingChannelID: UUID?,
        canManage: @escaping @MainActor () -> Bool = { true }
    ) {
        self.service = service
        self.editingChannelID = editingChannelID
        self.canManage = canManage
        let recipe = service.definitions.first { $0.id == editingChannelID }?.revisions.last?.recipe
            ?? LibraryChannelRecipe()
        self.recipe = recipe
        includeTitles = recipe.includeTitles.joined(separator: "; ")
        excludeTitles = recipe.excludeTitles.joined(separator: "; ")
        genres = recipe.genres.joined(separator: "; ")
        ratings = recipe.allowedRatings.joined(separator: "; ")
        seed = String(recipe.seed)
    }

    var currentPreview: LibraryChannelPreview? {
        guard canManage(), !isAutomaticChannel, UInt64(seed) != nil, let reviewed, reviewed.recipe == input,
              reviewed.authorizationGeneration == service.generation else { return nil }
        return reviewed
    }

    var isAutomaticChannel: Bool {
        service.definitions.first { $0.id == editingChannelID }?.isAutomatic == true
    }

    private var input: LibraryChannelRecipe {
        var value = recipe
        value.includeTitles = Self.entries(includeTitles)
        value.excludeTitles = Self.entries(excludeTitles)
        value.genres = Self.entries(genres)
        value.allowedRatings = Self.entries(ratings)
        value.seed = UInt64(seed) ?? recipe.seed
        return value
    }

    func load(prepareLibraries: (@MainActor () async throws -> Void)? = nil) async {
        guard canManage() else { issue = .authorizationChanged; return }
        guard !isAutomaticChannel else { issue = .invalidRecipe; return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let prepareLibraries {
                try await prepareLibraries()
            } else {
                if !service.isLoaded { try await service.load() }
                try await service.loadLibraries()
            }
        } catch { issue = (error as? LibraryChannelError) ?? .sourceUnavailable }
    }

    func preview() async {
        guard !isWorking else { return }
        guard canManage() else { issue = .authorizationChanged; return }
        guard !isAutomaticChannel else { issue = .invalidRecipe; return }
        guard UInt64(seed) != nil else { issue = .invalidRecipe; return }
        isWorking = true
        issue = nil
        defer { isWorking = false }
        do { reviewed = try await service.preview(recipe: input, editingChannelID: editingChannelID) }
        catch is CancellationError {}
        catch { issue = (error as? LibraryChannelError) ?? .sourceUnavailable }
    }

    func save() async -> Bool {
        guard canManage() else { issue = .authorizationChanged; return false }
        guard !isAutomaticChannel else { issue = .invalidRecipe; return false }
        guard !isWorking, let preview = currentPreview else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.publish(preview, editingChannelID: editingChannelID)
            return true
        } catch {
            issue = (error as? LibraryChannelError) ?? .storageFailed
            return false
        }
    }

    private static func entries(_ text: String) -> [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct LibraryChannelManagementView: View {
    public let service: LibraryChannelService
    public let history: LibraryChannelHistorySettings
    private let prepareLibraries: (@MainActor () async throws -> Void)?
    private let automaticChannels: LiveTVAutomaticChannelsState?

    public init(
        service: LibraryChannelService, history: LibraryChannelHistorySettings,
        prepareLibraries: (@MainActor () async throws -> Void)? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil
    ) {
        self.service = service
        self.history = history
        self.prepareLibraries = prepareLibraries
        self.automaticChannels = automaticChannels
    }

    public var body: some View {
        LiveTVLibraryChannelAccessGate { canManage in
            LibraryChannelManagementContent(
                service: service, history: history, prepareLibraries: prepareLibraries,
                automaticChannels: automaticChannels, canManage: canManage)
        }
    }
}

private struct LibraryChannelManagementContent: View {
    let service: LibraryChannelService
    let history: LibraryChannelHistorySettings
    let prepareLibraries: (@MainActor () async throws -> Void)?
    let automaticChannels: LiveTVAutomaticChannelsState?
    let canManage: @MainActor () -> Bool
    @State private var issue: LibraryChannelError?

    var body: some View {
        LiveTVSettingsPage(title: "Plozz channels") {
            if let automaticChannels {
                LiveTVAutomaticChannelsSection(state: automaticChannels, canManage: canManage)
            }
            let lineup = LibraryChannelManagementLineup(definitions: service.visibleDefinitions)
            LibraryChannelAutomaticLineupView(channels: lineup.automatic)
            LibraryChannelCustomSection(
                service: service, channels: lineup.custom, prepareLibraries: prepareLibraries,
                canManage: canManage, reportIssue: { issue = $0 })
            SettingsSectionGroup("Watch history") {
                Toggle(isOn: Binding(
                    get: { history.isEnabled },
                    set: {
                        guard canManage() else { issue = .authorizationChanged; return }
                        history.setEnabled($0)
                    }
                )) {
                    Text("Update library watch history from Plozz channels")
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Off leaves library progress and trackers untouched. On records completion only after you watch 90% of a programme, not from where you joined. Channel playback uses original files; server transcoding is unavailable when it cannot preserve this policy.")
            }
            if let issue = issue ?? service.issue { Text(issue.message) }
        }
        #if os(tvOS)
        .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
        #elseif os(iOS)
        .toggleStyle(SettingsTouchSwitchToggleStyle())
        #endif
        .task {
            guard canManage(), automaticChannels == nil else { return }
            do { if !service.isLoaded { try await service.load() } }
            catch { issue = (error as? LibraryChannelError) ?? .storageFailed }
        }
    }
}

struct LibraryChannelManagementLineup {
    let automatic: [LibraryChannelDefinition]
    let custom: [LibraryChannelDefinition]

    init(definitions: [LibraryChannelDefinition]) {
        automatic = definitions.filter(\.isAutomatic)
        custom = definitions.filter { !$0.isAutomatic }
    }
}

private struct LibraryChannelAutomaticLineupView: View {
    let channels: [LibraryChannelDefinition]

    var body: some View {
        if !channels.isEmpty {
            SettingsSectionGroup("Generated channels") {
                ForEach(channels) { channel in
                    Label {
                        Text(channel.revisions.last?.recipe.name ?? "")
                    } icon: {
                        Image(systemName: channel.revisions.last?.recipe.symbol ?? "tv")
                    }
                    .accessibilityIdentifier("live-tv-generated-channel-\(channel.id.uuidString)")
                }
            } footer: {
                Text("Plozz creates and updates these schedules automatically. Use the guide to watch, search or favorite a channel.")
            }
        }
    }
}

private struct LibraryChannelCustomSection: View {
    let service: LibraryChannelService
    let channels: [LibraryChannelDefinition]
    let prepareLibraries: (@MainActor () async throws -> Void)?
    let canManage: @MainActor () -> Bool
    let reportIssue: (LibraryChannelError) -> Void

    var body: some View {
        SettingsSectionGroup("Custom channels") {
            NavigationLink {
                LibraryChannelEditorView(
                    service: service, prepareLibraries: prepareLibraries, canManage: canManage)
            } label: {
                SettingsRowLabel(icon: "plus", title: "Create custom channel")
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-create-custom-channel")
            ForEach(channels) { channel in
                NavigationLink {
                    LibraryChannelEditorView(
                        service: service, editingChannelID: channel.id,
                        prepareLibraries: prepareLibraries, canManage: canManage)
                } label: {
                    SettingsRowLabel(icon: nil, title: Text(channel.revisions.last?.recipe.name ?? ""))
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-custom-channel-\(channel.id.uuidString)")
                .contextMenu {
                    Button("Delete channel", role: .destructive) {
                        Task {
                            guard canManage() else { reportIssue(.authorizationChanged); return }
                            guard service.definitions.first(where: { $0.id == channel.id })?.isAutomatic == false else {
                                reportIssue(.invalidRecipe)
                                return
                            }
                            do { try await service.delete(channelID: channel.id) }
                            catch { reportIssue((error as? LibraryChannelError) ?? .storageFailed) }
                        }
                    }
                }
            }
        } footer: {
            Text("Optional: choose your own libraries and rules for an additional channel.")
        }
    }
}
#endif
