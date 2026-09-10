#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Programme matches are a separate result section, never disguised as channel-name matches.
public struct LiveTVProgramSearchView: View {
    private let imports: LiveTVPrototypeImportModel
    private let model: LiveTVPrototypeModel
    private let query: String
    private let watch: @MainActor (LiveTVPrototypeChannel) -> Void
    private let showDetails: (@MainActor (LiveTVPrototypeProgram) -> Void)?
    private let excludedChannelIDs: Set<String>
    @State private var programs: [LiveTVPrototypeProgram] = []
    @State private var completedRequest: LiveTVProgramSearchRequest?
    @State private var fallbackDetails: LiveTVPrototypeProgram?
    @State private var loading = false
    @State private var failed = false

    public init(
        imports: LiveTVPrototypeImportModel, model: LiveTVPrototypeModel,
        query: String, watch: @escaping @MainActor (LiveTVPrototypeChannel) -> Void,
        showDetails: (@MainActor (LiveTVPrototypeProgram) -> Void)? = nil,
        excludedChannelIDs: Set<String> = []
    ) {
        self.imports = imports
        self.model = model
        self.query = query
        self.watch = watch
        self.showDetails = showDetails
        self.excludedChannelIDs = excludedChannelIDs
    }

    public var body: some View {
        let request = searchRequest
        let displayedPrograms = visiblePrograms(for: request)
        SettingsSectionGroup("Programmes") {
            if loading { ProgressView("Searching programmes") }
            ForEach(displayedPrograms) { program in
                if let channel = model.channel(id: program.channelID) {
                    Button {
                        guard completedRequest == searchRequest,
                              searchRequest.channelIDs.contains(program.channelID),
                              imports.isProgramSearchResultAvailable(program, catalog: model) else { return }
                        if let showDetails { showDetails(program) }
                        else { fallbackDetails = program }
                    } label: {
                        LiveTVProgramSearchRow(program: program, channelName: channel.name, now: model.now)
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
            if failed, completedRequest == request {
                Text("Programme search couldn't load. Your channel results are still available.")
            } else if !loading, completedRequest == request, displayedPrograms.isEmpty, !request.query.isEmpty {
                Text("No matching programmes in the retained guide.")
            }
        }
        .task(id: request) {
            programs = []
            completedRequest = nil
            loading = false
            failed = false
            guard !request.query.isEmpty, !request.channelIDs.isEmpty else {
                completedRequest = request
                return
            }
            loading = true
            defer { if !Task.isCancelled, request == searchRequest { loading = false } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard model.now.timeIntervalSince1970.isFinite else { throw LiveTVCacheError.invalidRange }
                // Do not use the channel-name query to narrow schedule-title results.
                let matches = try await imports.searchPrograms(
                    query: request.query, range: DateInterval(start: model.now, duration: 28 * 86_400),
                    allowedChannelIDs: request.channelIDs, catalog: model
                )
                try Task.checkCancellation()
                guard request == searchRequest else { return }
                programs = matches
                completedRequest = request
                failed = false
            } catch is CancellationError {
                guard !Task.isCancelled, request == searchRequest else { return }
                completedRequest = request
                failed = true
            } catch {
                guard !Task.isCancelled, request == searchRequest else { return }
                completedRequest = request
                failed = true
            }
        }
        .sheet(item: $fallbackDetails) { program in
            if let channel = model.channel(id: program.channelID),
               searchRequest.channelIDs.contains(channel.id),
               imports.isProgramSearchResultAvailable(program, catalog: model) {
                LiveTVProgramDetailsView(program: program, channelName: channel.name, now: model.now) {
                    guard searchRequest.channelIDs.contains(channel.id),
                          imports.isProgramSearchResultAvailable(program, catalog: model) else { return }
                    watch(channel)
                }
            }
        }
        .onChange(of: request) { previous, current in
            guard previous.modelIdentity == current.modelIdentity,
                  previous.importerIdentity == current.importerIdentity else {
                fallbackDetails = nil
                return
            }
            if let program = fallbackDetails,
               !current.channelIDs.contains(program.channelID)
                || !imports.isProgramSearchResultAvailable(program, catalog: model) {
                fallbackDetails = nil
            }
        }
    }

    var searchRequest: LiveTVProgramSearchRequest {
        let seconds = model.now.timeIntervalSince1970
        return LiveTVProgramSearchRequest(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            channelIDs: model.programmeSearchChannelIDs.subtracting(excludedChannelIDs),
            enabledGuideIDs: imports.enabledSourceIDs,
            modelIdentity: ObjectIdentifier(model), importerIdentity: ObjectIdentifier(imports),
            catalogRevision: model.catalogRevision, importRevision: imports.catalogRevision,
            guideRefresh: imports.lastGuideRefresh,
            clockMinute: seconds.isFinite ? (seconds / 60).rounded(.down) : 0
        )
    }

    private func visiblePrograms(for request: LiveTVProgramSearchRequest) -> [LiveTVPrototypeProgram] {
        request.filtering(programs, completedRequest: completedRequest, model: model, imports: imports)
    }
}

struct LiveTVProgramSearchRequest: Hashable {
    let query: String
    let channelIDs: Set<String>
    let enabledGuideIDs: Set<String>
    let modelIdentity: ObjectIdentifier
    let importerIdentity: ObjectIdentifier
    let catalogRevision: Int
    let importRevision: Int
    let guideRefresh: Date?
    let clockMinute: TimeInterval

    @MainActor
    func filtering(
        _ programs: [LiveTVPrototypeProgram], completedRequest: Self?,
        model: LiveTVPrototypeModel, imports: LiveTVPrototypeImportModel
    ) -> [LiveTVPrototypeProgram] {
        guard completedRequest == self, modelIdentity == ObjectIdentifier(model),
              importerIdentity == ObjectIdentifier(imports), catalogRevision == model.catalogRevision,
              importRevision == imports.catalogRevision, enabledGuideIDs == imports.enabledSourceIDs else { return [] }
        let allowed = channelIDs.intersection(model.programmeSearchChannelIDs)
        return programs.filter {
            allowed.contains($0.channelID) && $0.end > model.now
                && imports.isProgramSearchResultAvailable($0, catalog: model)
        }
    }
}

private struct LiveTVProgramSearchRow: View {
    let program: LiveTVPrototypeProgram
    let channelName: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(program.title).font(.headline)
            Text(channelName)
            HStack {
                if program.start <= now, now < program.end { Text("Now") }
                else if program.start > now { Text("Upcoming") }
                else { Text("Earlier") }
                Text(program.start, format: .dateTime.weekday().month().day().hour().minute())
                Text(program.end, format: .dateTime.hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

public struct LiveTVProgramDetailsView: View {
    private let program: LiveTVPrototypeProgram
    private let channelName: String
    private let now: Date
    private let watch: () -> Void
    private let guideSourceName: String?
    private let isFavorite: Bool
    private let toggleFavorite: (() -> Void)?
    private let watchTitle: LocalizedStringResource

    public init(
        program: LiveTVPrototypeProgram, channelName: String, now: Date,
        guideSourceName: String? = nil, isFavorite: Bool = false,
        toggleFavorite: (() -> Void)? = nil,
        watchTitle: LocalizedStringResource = "Watch channel", watch: @escaping () -> Void
    ) {
        self.program = program
        self.channelName = channelName
        self.now = now
        self.watch = watch
        self.guideSourceName = guideSourceName
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
        self.watchTitle = watchTitle
    }

    public var body: some View {
        LiveTVSettingsPage(title: "Programme details") {
            SettingsSectionGroup {
                LiveTVProgramSearchRow(program: program, channelName: channelName, now: now)
                if !program.subtitle.isEmpty { Text(program.subtitle) }
                if let guideSourceName { Text("Guide: \(guideSourceName)").font(.caption) }
                if let details = program.details {
                    if let artwork = details.artworkURL {
                        AsyncImage(url: artwork) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 480, maxHeight: 270)
                        .accessibilityHidden(true)
                    }
                    if let episode = details.episode { Text(episode) }
                    if let description = details.description { Text(description) }
                    if !details.categories.isEmpty { Text(details.categories.joined(separator: " · ")) }
                    if !details.languages.isEmpty { Text(details.languages.joined(separator: " · ")) }
                    if let rating = details.rating { Text(rating) }
                    if details.endWasInferred { Text("End time estimated from the next programme.").font(.caption) }
                }
                Button(action: watch) { Text(watchTitle) }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                if let toggleFavorite {
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: toggleFavorite)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            } footer: {
                Text("Watching tunes the channel live, not this programme from the beginning.")
            }
        }
    }
}
#endif
