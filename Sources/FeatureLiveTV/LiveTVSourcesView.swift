#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

public struct LiveTVSourcesView: View {
    public enum Presentation { case page, settingsPane }

    @State private var model: LiveTVSourceManagementModel
    @State private var pendingRemoval: LiveTVSourceRemoval?
    @State private var importedRemovalID: UUID?
    @State private var importedRemovalRequest = UUID()
    @State private var catalogReloadRevision = 0
    private let presentation: Presentation
    private let imports: LiveTVPrototypeImportModel?
    private let refresh: (@MainActor () -> Void)?
    private let serverChoices: [LiveTVServerChoice]
    private let serverProviderResolver: LiveTVServerProviderResolver?
    private let connectServer: (() -> Void)?
    private let sourceFilterID: String?
    private let browseSource: ((String?) -> Void)?
    private let didConfigurePlaylist: () -> Void
    private let createChannel: (() -> Void)?
    private let scanChannels: (() -> Void)?
    private let scanCoordinator: LiveTVChannelScanCoordinator?
    private let didImportPlaylist: (String) -> Void
    private var catalog: LiveTVSourcesCatalog?
    private let refreshAfterMutation: Bool

    /// Inject a retained importer and refresh callback to expose the same catalog
    /// tools in Settings and the Live TV toolbar without constructing another transport.
    public init(
        store: any LiveTVSourcesStoring,
        imports: LiveTVPrototypeImportModel? = nil,
        refresh: (@MainActor () -> Void)? = nil,
        presentation: Presentation = .page,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: LiveTVSourceManagementModel(store: store, canMutate: { false }))
        self.presentation = presentation
        self.imports = imports
        self.refresh = refresh
        self.serverChoices = serverChoices
        self.serverProviderResolver = serverProviderResolver
        self.connectServer = connectServer
        sourceFilterID = nil
        browseSource = nil
        self.didConfigurePlaylist = didConfigurePlaylist
        self.createChannel = createChannel
        self.scanChannels = scanChannels
        self.scanCoordinator = scanCoordinator
        self.didImportPlaylist = didImportPlaylist
        catalog = nil
        refreshAfterMutation = refresh != nil
    }

    public init(
        store: any LiveTVSourcesStoring,
        catalog: LiveTVSourcesCatalog,
        presentation: Presentation = .page,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in }
    ) {
        self.init(
            store: store, imports: catalog.imports, refresh: catalog.requestRefresh,
            presentation: presentation, serverChoices: serverChoices,
            serverProviderResolver: serverProviderResolver, connectServer: connectServer,
            didConfigurePlaylist: didConfigurePlaylist, createChannel: createChannel,
            scanChannels: scanChannels, scanCoordinator: scanCoordinator,
            didImportPlaylist: didImportPlaylist
        )
        self.catalog = catalog
    }

    init(
        model: LiveTVSourceManagementModel,
        imports: LiveTVPrototypeImportModel,
        refresh: @escaping @MainActor () -> Void,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        sourceFilterID: String? = nil,
        browseSource: ((String?) -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        presentation = .page
        self.imports = imports
        self.refresh = refresh
        self.serverChoices = serverChoices
        self.serverProviderResolver = serverProviderResolver
        self.connectServer = connectServer
        self.sourceFilterID = sourceFilterID
        self.browseSource = browseSource
        self.didConfigurePlaylist = didConfigurePlaylist
        self.createChannel = createChannel
        self.scanChannels = scanChannels
        self.scanCoordinator = scanCoordinator
        self.didImportPlaylist = didImportPlaylist
        catalog = nil
        refreshAfterMutation = false
    }

    public var body: some View {
        LiveTVSourceAccessGate(model: model) {
            let content = LiveTVSourcesContent(
                model: model, imports: catalog?.isCurrent == false ? nil : imports, refresh: refresh,
                serverChoices: serverChoices, serverProviderResolver: serverProviderResolver,
                connectServer: connectServer, sourceFilterID: sourceFilterID,
                browseSource: browseSource, didConfigurePlaylist: didConfigurePlaylist,
                removeSource: { pendingRemoval = $0 }, createChannel: createChannel,
                scanChannels: scanChannels, scanCoordinator: scanCoordinator,
                didImportPlaylist: didImportPlaylist
            )
            if presentation == .settingsPane {
                VStack(alignment: .leading, spacing: 24) {
                    content
                    catalogStatus
                }
            } else {
                LiveTVSettingsPage(title: "Sources") {
                    content
                    catalogStatus
                }
            }
        }
        #if os(tvOS)
        .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
        #elseif os(iOS)
        .toggleStyle(SettingsTouchSwitchToggleStyle())
        #endif
        .task(id: catalogReloadRevision) {
            model.reload()
            if model.hasLoaded {
                if catalogReloadRevision == 0 { await catalog?.restore() }
                else { await catalog?.refresh() }
            }
        }
        .onChange(of: model.mutationRevision) { _, _ in
            if refreshAfterMutation { refresh?() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange)) { notification in
            guard let catalog, notification.object as? String == catalog.profileID else { return }
            catalog.invalidate()
            catalogReloadRevision &+= 1
        }
        .task(id: importedRemovalRequest) {
            guard let importedRemovalID, let imports else { return }
            do {
                try await imports.removeImportedPlaylistFile(id: importedRemovalID)
                guard self.importedRemovalID == importedRemovalID, !Task.isCancelled else { return }
                self.importedRemovalID = nil
            } catch {
                guard self.importedRemovalID == importedRemovalID, !Task.isCancelled else { return }
                model.mutationIssue = .importedFileRemoval
            }
        }
        .alert("Source changes couldn't be saved", isPresented: Binding(
            get: { model.mutationIssue != nil },
            set: { if !$0 { model.mutationIssue = nil } }
        )) {
            if model.mutationIssue == .importedFileRemoval {
                Button("Retry") {
                    model.mutationIssue = nil
                    importedRemovalRequest = UUID()
                }
            }
            Button("OK", role: .cancel) { model.mutationIssue = nil }
        } message: {
            if let issue = model.mutationIssue { Text(issue.message) }
        }
        .confirmationDialog("Remove this source?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let removal = pendingRemoval {
                Button("Remove source", role: .destructive) {
                    switch removal {
                    case .playlist(let source):
                        model.removePlaylist(source.id)
                        if imports != nil, !model.configuration.playlists.contains(where: { $0.id == source.id }),
                           let id = source.importedPlaylistID {
                            importedRemovalID = id
                            importedRemovalRequest = UUID()
                        }
                    case .server(let source): model.removeServer(source.id)
                    }
                    pendingRemoval = nil
                }
            }
        } message: {
            Text("Its channels leave the guide. Channel preferences are kept.")
        }
    }

    @ViewBuilder
    private var catalogStatus: some View {
        if let catalog {
            if let issue = catalog.issue {
                SettingsSectionGroup {
                    Text(issue.message)
                    Button("Retry", action: catalog.requestRefresh)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            } else if catalog.isLoading {
                ProgressView("Loading channels and guide")
            }
        }
    }
}

private enum LiveTVSourceRemoval {
    case playlist(LiveTVPlaylistSource)
    case server(LiveTVServerSource)
}

private struct LiveTVSourcesContent: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let refresh: (@MainActor () -> Void)?
    let serverChoices: [LiveTVServerChoice]
    let serverProviderResolver: LiveTVServerProviderResolver?
    let connectServer: (() -> Void)?
    let sourceFilterID: String?
    let browseSource: ((String?) -> Void)?
    let didConfigurePlaylist: () -> Void
    let removeSource: (LiveTVSourceRemoval) -> Void
    let createChannel: (() -> Void)?
    let scanChannels: (() -> Void)?
    let scanCoordinator: LiveTVChannelScanCoordinator?
    let didImportPlaylist: (String) -> Void

    var body: some View {
        if let issue = model.loadIssue {
            SettingsSectionGroup {
                Label {
                    Text(issue.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                Button("Retry") { model.reload() }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }
        } else if !model.hasLoaded {
            ProgressView("Loading sources")
        } else {
            if browseSource != nil || createChannel != nil || scanChannels != nil {
                SettingsSectionGroup {
                    if let createChannel {
                        Button("Create channel", systemImage: "sparkles.tv", action: createChannel)
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                    if let scanChannels {
                        Button("Check channel availability", systemImage: "checkmark.circle", action: scanChannels)
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                    if browseSource != nil {
                        NavigationLink {
                            LiveTVSourceFilterList(
                                configuration: model.configuration,
                                sourceFilterID: sourceFilterID, browseSource: browseSource
                            )
                        } label: {
                            SettingsRowLabel(icon: "line.3.horizontal.decrease", title: "Browse channels from", trailing: {
                                if let name = selectedSourceName {
                                    Text(name).settingsRowSecondary()
                                } else {
                                    Text("All sources").settingsRowSecondary()
                                }
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                }
            }
            ForEach(model.configuration.playlists) { source in
                SettingsSectionGroup(verbatim: source.name) {
                    Toggle("Enabled", isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setPlaylistEnabled(source.id, enabled: $0) }
                    ))
                    .accessibilityIdentifier("live-tv-source-enabled-\(source.id)")
                    LiveTVSourceApprovalControl(
                        source: source, sourceStore: model.sourceStoreForApproval,
                        onChange: {
                            model.reload()
                            refresh?()
                        }
                    )
                    if let scanCoordinator, scanCoordinator.sourceIDs.contains(source.id) {
                        NavigationLink {
                            LiveTVSettingsPage(title: "Check channels") {
                                LiveTVScanSourceSection(
                                    coordinator: scanCoordinator, sourceID: source.id, sourceName: source.name
                                )
                            }
                        } label: {
                            SettingsRowLabel(icon: "checkmark.magnifyingglass", title: "Check channel availability")
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("live-tv-source-scan-\(source.id)")
                    }
                    NavigationLink {
                        if source.importedPlaylistID != nil {
                            LiveTVImportedPlaylistEditor(
                                sources: model, imports: imports, original: source,
                                didConfigurePlaylist: didConfigurePlaylist
                            )
                        } else {
                            LiveTVPlaylistSourceEditor(
                                model: model, source: source, didConfigurePlaylist: didConfigurePlaylist
                            )
                        }
                    } label: {
                        SettingsRowLabel(icon: "list.bullet.rectangle", title: "Playlist and guides")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-edit-source-\(source.id)")
                    if let imports {
                        if imports.supportsDurableCatalog {
                            NavigationLink {
                                LiveTVGuideMappingView(
                                    imports: imports, sourceID: source.id, authorize: model.ensureCanMutate
                                )
                            } label: {
                                SettingsRowLabel(icon: "link", title: "Correct guide mapping")
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                        if let failure = imports.guideDiscoveryFailures[source.id] {
                            Text(failure.userDescription)
                                .font(.caption)
                        }
                        if let reviews = imports.identityReviews[source.id], !reviews.isEmpty {
                            NavigationLink {
                                LiveTVIdentityReviewView(
                                    imports: imports, sourceID: source.id, authorize: model.ensureCanMutate
                                )
                            } label: {
                                SettingsRowLabel(icon: "person.crop.rectangle.badge.questionmark", title: "Review channel identities", trailing: {
                                    Text(reviews.count, format: .number).settingsRowSecondary()
                                })
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                        NavigationLink {
                            LiveTVPlaylistSourceDetails(
                                model: model, imports: imports, sourceID: source.id,
                                didConfigurePlaylist: didConfigurePlaylist
                            )
                        } label: {
                            LiveTVPlaylistSourceSummary(
                                source: source,
                                status: imports.playlistSources.first { $0.id == source.id }
                            )
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                    Button(role: .destructive) {
                        removeSource(.playlist(source))
                    } label: {
                        SettingsRowLabel(icon: "trash", title: "Remove source")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-remove-source-\(source.id)")
                }
            }

            ForEach(model.configuration.servers) { source in
                SettingsSectionGroup(verbatim: source.name) {
                    Toggle("Enabled", isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setServerEnabled(source.id, enabled: $0) }
                    ))
                    NavigationLink {
                        LiveTVServerSourceRename(model: model, source: source)
                    } label: {
                        SettingsRowLabel(icon: "pencil", title: "Rename source")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    if let imports {
                        NavigationLink {
                            LiveTVServerSourceDetails(model: model, imports: imports, sourceID: source.id)
                        } label: {
                            LiveTVServerSourceSummary(
                                source: source,
                                status: imports.serverSources.first { $0.id == source.id }
                            )
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                    Button(role: .destructive) {
                        removeSource(.server(source))
                    } label: {
                        SettingsRowLabel(icon: "trash", title: "Remove source")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
            SettingsSectionGroup {
                NavigationLink {
                    LiveTVPlaylistEditor { input in
                        let previousIDs = Set(model.configuration.playlists.map(\.id))
                        try model.savePlaylist(input: input)
                        didConfigurePlaylist()
                        if let added = model.configuration.playlists.first(where: { !previousIDs.contains($0.id) }) {
                            didImportPlaylist(added.id)
                        }
                    }
                } label: {
                    SettingsRowLabel(icon: "plus", title: "Add IPTV playlist")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                #if os(iOS)
                if let imports, imports.supportsDurableCatalog {
                    NavigationLink {
                        LiveTVImportedPlaylistEditor(
                            sources: model, imports: imports, didConfigurePlaylist: didConfigurePlaylist,
                            didImportPlaylist: didImportPlaylist
                        )
                    } label: {
                        SettingsRowLabel(icon: "doc.badge.plus", title: "Import M3U file")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                #endif
                NavigationLink {
                    LiveTVServerSetupView(
                        sources: model, choices: serverChoices,
                        resolver: serverProviderResolver, connectServer: connectServer
                    )
                } label: {
                    SettingsRowLabel(icon: "server.rack", title: "Use a media server")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }

            if let imports {
                LiveTVGuideOverview(imports: imports)
                if let failure = imports.cacheFailure {
                    SettingsSectionGroup {
                        Text(failure.userDescription)
                    }
                }
            }
            if let refresh {
                SettingsSectionGroup {
                    Button("Refresh sources", systemImage: "arrow.clockwise", action: refresh)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .disabled(imports?.isLoading == true)
                    if imports?.isLoading == true {
                        ProgressView("Refreshing sources")
                    }
                }
            }
        }
    }

    private var selectedSourceName: String? {
        model.configuration.playlists.first { $0.id == sourceFilterID }?.name
            ?? model.configuration.servers.first { $0.id == sourceFilterID }?.name
    }
}

private struct LiveTVSourceFilterList: View {
    let configuration: LiveTVSourcesConfiguration
    let sourceFilterID: String?
    let browseSource: ((String?) -> Void)?

    var body: some View {
        if let browseSource {
            LiveTVSettingsPage(title: "Browse sources") {
                SettingsSectionGroup {
                    Button {
                        browseSource(nil)
                    } label: {
                        SettingsRowLabel(icon: nil, title: "All sources", trailing: {
                            if sourceFilterID == nil { SettingsSelectionIndicator() }
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityAddTraits(sourceFilterID == nil ? .isSelected : [])
                    ForEach(configuration.playlists.filter(\.isEnabled)) { source in
                        Button {
                            browseSource(source.id)
                        } label: {
                            SettingsRowLabel(icon: nil, title: Text(source.name), trailing: {
                                if sourceFilterID == source.id { SettingsSelectionIndicator() }
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityAddTraits(sourceFilterID == source.id ? .isSelected : [])
                    }
                    ForEach(configuration.servers.filter(\.isEnabled)) { source in
                        Button {
                            browseSource(source.id)
                        } label: {
                            SettingsRowLabel(icon: nil, title: Text(source.name), trailing: {
                                if sourceFilterID == source.id { SettingsSelectionIndicator() }
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityAddTraits(sourceFilterID == source.id ? .isSelected : [])
                    }
                }
            }
        }
    }
}

private struct LiveTVGuideOverview: View {
    let imports: LiveTVPrototypeImportModel

    var body: some View {
        SettingsSectionGroup("Guide coverage") {
            Text("\(imports.matchedChannelCount) channels matched")
            Text("\(imports.retainedProgramCount) cached programme listings")
            if let start = imports.coverageStart, let end = imports.coverageEnd {
                Text(start..<end, format: .interval.day().month().hour().minute())
            }
        }
    }
}

private struct LiveTVPlaylistSourceDetails: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let sourceID: String
    let didConfigurePlaylist: () -> Void
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let source = model.configuration.playlists.first(where: { $0.id == sourceID }) {
            LiveTVSettingsPage(title: "Source details") {
                SettingsSectionGroup(verbatim: source.name) {
                    Toggle("Enabled", isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setPlaylistEnabled(source.id, enabled: $0) }
                    ))
                }
                SettingsSectionGroup("Guide refresh") {
                    Toggle("Use guides declared by the playlist", isOn: Binding(
                        get: { source.discoversPlaylistGuides },
                        set: { model.setGuidePolicy(sourceID, discovers: $0) }
                    ))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep previous days")
                        SettingsOptionPicker(options: Array(0...7), selection: Binding(
                            get: { source.guideLookbackDays },
                            set: { model.setGuidePolicy(sourceID, lookbackDays: $0) }
                        )) { value in "\(value) days" }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Look ahead")
                        SettingsOptionPicker(options: [1, 3, 7, 14, 28], selection: Binding(
                            get: { source.guideLookaheadDays },
                            set: { model.setGuidePolicy(sourceID, lookaheadDays: $0) }
                        )) { value in "\(value) days" }
                    }
                } footer: {
                    Text("Keeps the listings provided within this range. A guide may supply fewer days.")
                }
                if let imports {
                    if let status = imports.playlistSources.first(where: { $0.id == sourceID }) {
                        SettingsSectionGroup("Channels") {
                            LiveTVPlaylistImportStatus(status: status)
                        }
                    }
                    ForEach(imports.guideSources.filter { $0.playlistSourceID == sourceID }) { status in
                        SettingsSectionGroup(verbatim: status.source.name) {
                            PrototypeSourceAddress(url: status.source.url).font(.caption)
                            PrototypeGuideSourceStatus(
                                status: status, enabled: imports.enabledSourceIDs.contains(status.id)
                            )
                        }
                    }
                }
                SettingsSectionGroup {
                    NavigationLink("Edit playlist and guides") {
                        if source.importedPlaylistID != nil {
                            LiveTVImportedPlaylistEditor(
                                sources: model, imports: imports, original: source,
                                didConfigurePlaylist: didConfigurePlaylist
                            )
                        } else {
                            LiveTVPlaylistSourceEditor(
                                model: model, source: source, didConfigurePlaylist: didConfigurePlaylist
                            )
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                SettingsSectionGroup {
                    Button("Remove source", role: .destructive) { confirmsRemoval = true }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
            .confirmationDialog("Remove this source?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button("Remove source", role: .destructive) {
                    let revision = model.mutationRevision
                    model.removePlaylist(source.id)
                    if revision != model.mutationRevision { dismiss() }
                }
            } message: {
                Text("Channel preferences are kept.")
            }
        } else {
            ContentUnavailableView("Source removed", systemImage: "list.bullet.rectangle")
        }
    }
}

private struct LiveTVPlaylistImportStatus: View {
    let status: LiveTVPlaylistSourceStatus

    var body: some View {
        if status.phase == .loading {
            ProgressView("Loading channels")
        } else if status.phase == .idle {
            Text("Ready to load")
        }
        if let failure = status.failure {
            Text(failure.userDescription)
            if status.lastRefresh != nil { Text("Keeping previously loaded channels") }
        }
        if status.lastRefresh != nil {
            if status.skippedEntryCount > 0 {
                Text("\(status.skippedEntryCount) unsupported or duplicate entries skipped")
            }
        }
        if let date = status.lastRefresh {
            Text("Last refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                .font(.caption)
        }
    }
}

private struct LiveTVServerSourceDetails: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let sourceID: String
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let source = model.configuration.servers.first(where: { $0.id == sourceID }) {
            LiveTVSettingsPage(title: "Source details") {
                SettingsSectionGroup(verbatim: source.name) {
                    Toggle("Enabled", isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setServerEnabled(source.id, enabled: $0) }
                    ))
                    NavigationLink("Rename source") {
                        LiveTVServerSourceRename(model: model, source: source)
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                if let status = imports?.serverSources.first(where: { $0.id == sourceID }) {
                    SettingsSectionGroup("Live TV status") {
                        LiveTVServerSourceSummary(source: source, status: status)
                        Text("\(status.channelCount) channels")
                        Text("\(status.programCount) loaded program listings")
                        if let date = status.lastGuideRefresh {
                            Text("Guide refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                                .font(.caption)
                        }
                    }
                }
                SettingsSectionGroup {
                    Button("Remove source", role: .destructive) { confirmsRemoval = true }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
            .confirmationDialog("Remove this source?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button("Remove source", role: .destructive) {
                    let revision = model.mutationRevision
                    model.removeServer(source.id)
                    if revision != model.mutationRevision { dismiss() }
                }
            } message: {
                Text("The server account stays connected.")
            }
        } else {
            ContentUnavailableView("Source removed", systemImage: "server.rack")
        }
    }
}

private struct LiveTVServerSourceRename: View {
    let model: LiveTVSourceManagementModel
    @State private var original: LiveTVServerSource
    @State private var name: String
    @State private var failure: LiveTVSourceManagementModel.Issue?
    @Environment(\.dismiss) private var dismiss

    init(model: LiveTVSourceManagementModel, source: LiveTVServerSource) {
        self.model = model
        _original = State(initialValue: source)
        _name = State(initialValue: source.name)
    }

    var body: some View {
        LiveTVSettingsPage(title: "Rename source") {
            SettingsSectionGroup {
                TextField("Source name", text: $name)
                if let failure { Text(failure.message) }
                Button("Save name") {
                    do {
                        try model.renameServer(original, name: name)
                        dismiss()
                    } catch LiveTVSourceManagementModel.MutationError.changedSource {
                        failure = .changedSource
                    } catch LiveTVSourceManagementModel.MutationError.accessDenied {
                        failure = .accessDenied
                    } catch {
                        failure = .save
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 512)
            }
        }
    }
}

private struct LiveTVPlaylistSourceEditor: View {
    let model: LiveTVSourceManagementModel
    @State private var source: LiveTVPlaylistSource
    let didConfigurePlaylist: () -> Void

    init(
        model: LiveTVSourceManagementModel,
        source: LiveTVPlaylistSource,
        didConfigurePlaylist: @escaping () -> Void
    ) {
        self.model = model
        _source = State(initialValue: source)
        self.didConfigurePlaylist = didConfigurePlaylist
    }

    var body: some View {
        LiveTVPlaylistEditor(
            name: source.name, playlistURL: source.playlistURL, guideURLs: source.guideURLs,
            isEditing: true
        ) { input in
            try model.savePlaylist(input: input, replacing: source)
            didConfigurePlaylist()
        }
    }
}

private struct LiveTVServerSourceSummary: View {
    let source: LiveTVServerSource
    let status: LiveTVServerSourceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.name).font(.headline)
            if !source.isEnabled {
                Text("Disabled").font(.caption)
            } else if let status {
                if let failure = status.failure {
                    Text(failure.userDescription).font(.caption)
                } else if let availability = status.availability {
                    LiveTVServerAvailabilitySummary(availability: availability)
                } else if status.phase == .loading {
                    ProgressView("Loading channels")
                } else {
                    Text("Ready to load").font(.caption)
                }
                if let failure = status.guideFailure {
                    Text(failure.userDescription).font(.caption)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LiveTVPlaylistSourceSummary: View {
    let source: LiveTVPlaylistSource
    let status: LiveTVPlaylistSourceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(source.name).font(.headline).lineLimit(2)
                Spacer()
                if !source.isEnabled {
                    Text("Disabled").font(.caption).settingsRowSecondary()
                }
            }
            if source.importedPlaylistID != nil {
                Text("Imported file").font(.caption).settingsRowSecondary()
            } else if let host = source.playlistURL.host {
                Text(host).font(.caption).settingsRowSecondary().privacySensitive()
            }
            if source.isEnabled, let status {
                switch status.phase {
                case .idle:
                    Text("Ready to load").font(.caption)
                case .loading:
                    ProgressView("Loading channels")
                case .loaded:
                    Text("\(status.channelCount) channels").font(.caption)
                case .failed:
                    Label("Refresh failed", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
            if source.guideURLs.isEmpty {
                Text("No guide added").font(.caption).settingsRowSecondary()
            } else {
                Text("\(source.guideURLs.count) guide sources").font(.caption).settingsRowSecondary()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
