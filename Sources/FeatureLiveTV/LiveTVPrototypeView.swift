#if DEBUG
import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

public enum LiveTVPrototypeEntry {
    public static var isEnabled: Bool { LiveTVPrototypeLaunch.isEnabled() }
}

public struct LiveTVPrototypePlayback {
    public let paneID: UUID
    public let channel: LiveTVPrototypeChannel
    public let input: LiveChannelInput
    public let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    public let previousChannel: () -> Void
    public let nextChannel: () -> Void
    public let isFavorite: Bool
    public let canToggleFavorite: Bool
    public let onToggleFavorite: () -> Void
    public let isExpanded: Bool
    public let returnToGuide: () -> Void
    public let playPauseRequest: Int
    public let playbackStarted: () -> Void
    public let reportingID: UUID
    public let playbackUpdate: @MainActor (LiveTVPlaybackUpdate) -> Void
    public let playbackFailed: @MainActor () -> Void
    public let videoAspectRatioChanged: @MainActor (Double?) -> Void
    public let preparingChannelName: String?
    public let isMultiview: Bool
    public let isAudible: Bool
    public let openMultiview: () -> Void
    public let canOpenMultiview: Bool
    public let isPlaybackActive: Bool
    public let isAuthorized: Bool
    public let countsAsWatching: Bool
    public let externalContinuationChanged: @MainActor (Bool) -> Void
    public let restorePlayer: @MainActor () async -> Bool
    public let stopPlayback: @MainActor () -> Void
}

private struct PrototypeExternalPlayback: Equatable {
    let paneID: UUID
    let preparedID: UUID
}

private struct PrototypeSearchBookmark {
    let row: LiveTVGuideRowID?
    let guideOffset: TimeInterval
    let timeAnchor: Date
    let timelineOffset: CGFloat
}

private enum PrototypeSearchScope: Hashable {
    case channels, programs
}

private enum PrototypeEnrollmentCommitError: Error {
    case authorizationChanged, configurationChanged
}

public struct LiveTVPrototypeView<PlayerContent: View>: View {
    @State private var model: LiveTVPrototypeModel
    @State private var preview: LiveTVPreviewController
    @State private var imports: LiveTVPrototypeImportModel
    @State private var playback: LiveTVPlaybackCoordinator
    @State private var playbackResolvers: LiveTVPlaybackResolverContext
    @State private var sourceAuthority: LiveTVPlaybackSourceAuthority
    @State private var appliedSourceAuthorizationID: String?
    @State private var multiview: LiveTVMultiviewCoordinator
    @State private var enrollment = LiveTVServerEnrollmentCoordinator()
    @State private var sources: LiveTVSourceManagementModel?
    @State private var sourceApplicationFailed = false
    @State private var reloadRequest = 0
    @State private var sheet: PrototypeSheet?
    @State private var selectedChannelID: String?
    @State private var selectedRowID: LiveTVGuideRowID?
    @State private var isSearching = false
    @State private var searchScope: PrototypeSearchScope = .channels
    @State private var searchFocusRequest = 0
    @State private var searchOrigin: PrototypeSearchBookmark?
    @State private var topRequest = 0
    @State private var nowRequest = 0
    @State private var channelSequence = LiveTVChannelSequence(channels: [])
    @State private var controlsActive = false
    @State private var guideHasFocus = false
    @State private var toolbarFocusRequest = 0
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var loadedRequest: Int?
    @State private var guideOffset: TimeInterval = 0
    @State private var timelineOffset: CGFloat = 0
    @State private var timeAnchor = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1_800) * 1_800)
    @State private var pendingTuneID: String?
    @State private var pendingServerConnection = false
    @State private var externalPlayback: PrototypeExternalPlayback?
    @State private var multiviewSelection: LiveTVMultiviewSelection?
    @State private var pendingMultiviewFavorite: LiveTVMultiviewFavorite?
    @State private var multiviewFavoriteIssue: LocalizedStringResource?
    @State private var managesLibraryChannels = false
    @State private var libraryGuideIssue: LibraryChannelError?
    @State private var portableIdentityHold: LiveTVPlaybackIdentityHold
    @State private var pendingPortableReload = false
    @State private var scanBinding: LiveTVScanCatalogBinding
    @State private var showsScanSources = false
    @State private var pendingScanOfferSourceID: String?
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    private let isActive: Bool
    private let profileID: String
    private let allowsPlayback: Bool
    private let playbackUnavailableReason: LocalizedStringResource?
    private let restoreDestination: @MainActor () async -> Bool
    private let usesNativeFullscreen: Bool
    private let viewSettingsStore: (any LiveTVViewSettingsStoring)?
    private let sourceStore: (any LiveTVSourcesStoring)?
    private let enrollmentSuppression: LiveTVServerEnrollmentSuppressionStore
    private let libraryService: LibraryChannelService?
    private let libraryHistory: LibraryChannelHistorySettings?
    private let libraryIssue: LibraryChannelError?
    private let automaticChannels: LiveTVAutomaticChannelsState?
    private let reloadLibrary: (() -> Void)?
    private let prepareLibraryChannels: (@MainActor () async throws -> Void)?
    private let libraryIsAuthorized: @MainActor @Sendable () -> Bool
    private let didConfigurePlaylist: () -> Void
    private let serverProviderResolver: LiveTVServerProviderResolver
    private let authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private let serverChoices: [LiveTVServerChoice]
    private let serverAuthorizationID: String
    private let isProfileAuthorized: @MainActor @Sendable () -> Bool
    private let connectServer: (() -> Void)?
    private let onExpandedChange: (Bool) -> Void
    private let player: (LiveTVPrototypePlayback) -> PlayerContent

    public init(
        isActive: Bool = true,
        usesNativeFullscreen: Bool = false,
        preferencesStore: (any LiveTVPreferencesStoring)? = nil,
        viewSettingsStore: (any LiveTVViewSettingsStoring)? = nil,
        sourceStore: (any LiveTVSourcesStoring)? = nil,
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        isProfileAuthorized: @escaping @MainActor @Sendable () -> Bool = { true },
        serverChoices: [LiveTVServerChoice] = [],
        serverAuthorizationID: String = "",
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        onExpandedChange: @escaping (Bool) -> Void = { _ in },
        allowsPlayback: Bool = true,
        playbackUnavailableReason: LocalizedStringResource? = nil,
        restoreDestination: @escaping @MainActor () async -> Bool = { false },
        catalogCache: LiveTVIndexedCache? = nil,
        sourceLoader: (any LiveTVSourceLoading)? = nil,
        importModel: LiveTVPrototypeImportModel? = nil,
        profileID: String = ProfileStore.defaultProfileID,
        preferencesNamespace: String?,
        libraryService: LibraryChannelService? = nil,
        libraryHistory: LibraryChannelHistorySettings? = nil,
        libraryIssue: LibraryChannelError? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil,
        reloadLibrary: (() -> Void)? = nil,
        prepareLibraryChannels: (@MainActor () async throws -> Void)? = nil,
        libraryIsAuthorized: @escaping @MainActor @Sendable () -> Bool = { true },
        sourceApprovalContext: @escaping @MainActor @Sendable () -> LiveTVSourceApprovalContext? = { nil },
        @ViewBuilder player: @escaping (LiveTVPrototypePlayback) -> PlayerContent
    ) {
        self.isActive = isActive
        self.profileID = profileID
        _portableIdentityHold = State(initialValue: LiveTVPlaybackIdentityHold(profileID: profileID))
        self.allowsPlayback = allowsPlayback
        self.playbackUnavailableReason = playbackUnavailableReason
        self.restoreDestination = restoreDestination
        self.usesNativeFullscreen = usesNativeFullscreen
        self.viewSettingsStore = viewSettingsStore
        self.sourceStore = sourceStore
        self.enrollmentSuppression = LiveTVServerEnrollmentSuppressionStore(
            profileID: profileID, namespace: preferencesNamespace
        )
        self.libraryService = libraryService
        self.libraryHistory = libraryHistory
        self.libraryIssue = libraryIssue
        self.automaticChannels = automaticChannels
        self.reloadLibrary = reloadLibrary
        self.prepareLibraryChannels = prepareLibraryChannels
        self.libraryIsAuthorized = libraryIsAuthorized
        let sourceAuthority = LiveTVPlaybackSourceAuthority(
            profileID: profileID,
            approvals: LiveTVSourceApprovalStore(profileID: profileID, namespace: preferencesNamespace),
            sourceStore: sourceStore, context: sourceApprovalContext
        )
        _sourceAuthority = State(initialValue: sourceAuthority)
        let resolver: LiveTVServerProviderResolver = serverProviderResolver ?? { _ in nil }
        self.serverProviderResolver = resolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        let resolverContext = LiveTVPlaybackResolverContext(
            serverProviderResolver: resolver, authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        _playbackResolvers = State(initialValue: resolverContext)
        let currentResolver: LiveTVServerProviderResolver = { resolverContext.provider(for: $0) }
        self.isProfileAuthorized = isProfileAuthorized
        self.serverChoices = serverChoices
        self.serverAuthorizationID = serverAuthorizationID
        self.connectServer = connectServer
        self.didConfigurePlaylist = didConfigurePlaylist
        let sources = sourceStore.map {
            LiveTVSourceManagementModel(store: $0, canMutate: { false })
        }
        _sources = State(initialValue: sources)
        let imports = importModel ?? LiveTVPrototypeImportModel(
            configuration: .empty, loader: sourceLoader ?? LiveTVSourceLoader(),
            serverProviderResolver: currentResolver, cache: catalogCache
        )
        _imports = State(initialValue: imports)
        self.onExpandedChange = onExpandedChange
        self.player = player
        let arguments = ProcessInfo.processInfo.arguments
        let model = LiveTVPrototypeModel(
            now: Date(), scenario: .noGuide,
            isLargeCatalog: arguments.contains("--live-tv-5000"),
            channels: [], preferencesStore: preferencesStore
        )
        _model = State(initialValue: model)
        let scanBinding = LiveTVScanCatalogBinding(
            profileID: profileID, model: model,
            coordinator: LiveTVChannelScanCoordinator(store: LiveTVChannelHealthStore(
                namespace: profileID
            )),
            authorization: sourceAuthority.authorization
        )
        _scanBinding = State(initialValue: scanBinding)
        #if os(tvOS)
        let preview = LiveTVPreviewController(model: model)
        #else
        let preview = LiveTVPreviewController(model: model, followsFocus: false)
        #endif
        _preview = State(initialValue: preview)
        let libraryResolver: @MainActor @Sendable (
            LiveTVPrototypeChannel
        ) throws -> LiveTVLibraryChannelReference? = { [weak libraryService] channel in
            guard let libraryService, channel.source == .plozz, libraryIsAuthorized(),
                  let definition = libraryService.definitions.first(where: {
                      $0.catalogID == channel.id && $0.isEnabled
                  }) else { return nil }
            _ = try libraryService.slot(channelID: definition.id, at: Date())
            let context = try libraryService.playbackContext(catalogID: channel.id)
            guard let authorizationID = context.authorizationID else {
                throw LiveTVPlaybackPreparationError.authorizationChanged
            }
            return LiveTVLibraryChannelReference(channelID: context.channelID, authorizationID: authorizationID)
        }
        let preparation = LiveTVPlaybackPreparation(
            serverProviderResolver: currentResolver, authenticatedHTTPResolver: resolverContext,
            libraryChannelResolver: libraryResolver
        )
        let authorizes: @MainActor @Sendable (
            LiveTVPrototypeChannel, LiveTVServerChannelReference?
        ) -> Bool = { channel, reference in
            isProfileAuthorized() && (sources?.hasLoaded ?? true)
                && (channel.source != .plozz || libraryIsAuthorized())
                && sourceAuthority.allows(channel, configuration: sources?.configuration ?? imports.configuration)
                && LiveTVPlaybackCatalogAuthorization.allows(
                    channel, reference: reference, model: model, imports: imports,
                    configuration: sources?.configuration ?? imports.configuration,
                    libraryService: libraryService
                )
        }
        _playback = State(initialValue: LiveTVPlaybackCoordinator(
            model: model, preview: preview,
            preparation: preparation,
            reference: { imports.serverChannelReferences[$0] },
            isAuthorized: authorizes,
            isGuideOnly: { channelID in
                guard let reference = imports.serverChannelReferences[channelID] else { return false }
                return imports.serverSources.first(where: { $0.id == reference.sourceID })?
                    .availability?.status == .unsupportedPlaybackMode
            }
        ))
        _multiview = State(initialValue: LiveTVMultiviewCoordinator(
            primary: preparation,
            makePreparation: {
                LiveTVPlaybackPreparation(
                    serverProviderResolver: currentResolver,
                    authenticatedHTTPResolver: resolverContext,
                    libraryChannelResolver: libraryResolver
                )
            },
            reference: { imports.serverChannelReferences[$0] },
            authorizes: authorizes,
            recordWatched: { _ = model.recordWatched($0) }
        ))
    }

    public var body: some View {
        lifecycleContent
    }

    private var playerAndGuideSurface: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(
                size: geometry.size, safeAreaInsets: geometry.safeAreaInsets,
                navigationInset: navigationInset, largeText: typeSize.isAccessibilitySize,
                isSearching: isSearching
            )
            let expanded = multiviewSelection == nil && (preview.isExpanded || multiview.isEnabled)
            ZStack(alignment: .topLeading) {
                palette.backgroundBase.ignoresSafeArea()

                // Stable pane IDs retain renderers through single/multiple layouts and promotion.
                ForEach(multiview.panes) { pane in
                    if let prepared = pane.preparation.current {
                        let videoFrame = showingMultiview
                            ? LiveTVMultiviewGeometry.frame(
                                for: pane.id, panes: multiview.panes.map(\.id),
                                primary: multiview.primaryPaneID, layout: multiview.layout,
                                corner: multiview.corner, insetSize: multiview.insetSize,
                                expanded: multiview.expandedPaneID, size: layout.bounds.size,
                                isEditing: multiview.isEditingLayout,
                                aspectRatio: pane.videoAspectRatio.map { CGFloat($0) }
                            )
                            .offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY)
                            : (expanded ? layout.bounds : layout.videoFrame)
                        player(playbackInput(for: pane, prepared: prepared))
                    .environment(\.themePalette, ThemePalette.dark)
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .clipShape(RoundedRectangle(
                        cornerRadius: showingMultiview && multiview.isEditingLayout ? 10 : 0))
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: palette.backgroundBase, location: 0),
                                .init(color: .clear, location: 0.28),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .opacity(expanded || layout.compact ? 0 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .position(
                        x: !showingMultiview && layoutDirection == .rightToLeft
                            ? geometry.size.width - videoFrame.midX : videoFrame.midX,
                        y: videoFrame.midY
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: preview.isExpanded)
                    .zIndex(showingMultiview && pane.id != multiview.primaryPaneID ? 1 : 0)
                    .opacity(multiviewSelection != nil
                        ? (pane.id == multiview.audiblePaneID ? 1 : 0)
                        : (multiview.expandedPaneID == nil || multiview.expandedPaneID == pane.id ? 1 : 0))
                    .allowsHitTesting(!multiview.isEnabled)
                    .accessibilityHidden(multiview.isEnabled)
                    }
                }

                PrototypePreviewScrim(layout: layout, reduceTransparency: reduceTransparency)
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(
                        x: layoutDirection == .rightToLeft
                            ? geometry.size.width - layout.bounds.midX : layout.bounds.midX,
                        y: layout.bounds.midY
                    )
                    .opacity(expanded ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: preview.isExpanded)

                guideContent(layout, canvasWidth: geometry.size.width)
                #if os(tvOS)
                .focusSection()
                #endif
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(expanded ? 0 : 1)
                .offset(y: expanded && !reduceMotion ? geometry.size.height * 0.55 : 0)
                .disabled(expanded || !isActive)
                .allowsHitTesting(!expanded && isActive)
                .accessibilityHidden(expanded || !isActive)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: preview.isExpanded)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSearching)
                if showingMultiview {
                    LiveTVMultiviewOverlay(
                        coordinator: multiview,
                        exit: { leaveMultiview() },
                        returnToGuide: { leaveMultiview(); returnToGuide() },
                        addChannel: { beginMultiviewSelection(.add) },
                        replaceChannel: { beginMultiviewSelection(.replace($0)) },
                        isFavorite: model.favoriteMultiviews.contains(where: multiview.matches),
                        toggleFavorite: toggleMultiviewFavorite
                    )
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(x: layout.bounds.midX, y: layout.bounds.midY)
                    .zIndex(2)
                }
            }
        }
        .environment(\.themePalette, palette)
        .tint(palette.accent)
        .foregroundStyle(palette.primaryText)
        .overlay(alignment: .topTrailing) {
            if let id = playback.pendingWatchChannelID, !preview.isExpanded || playback.preparation.current == nil {
                PrototypeWatchPreparationStatus(
                    channelName: model.channel(id: id)?.name ?? "",
                    cancel: playback.cancelWatch
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isActive, !allowsPlayback, !model.channels.isEmpty, let playbackUnavailableReason {
                Label {
                    Text(playbackUnavailableReason)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.callout)
                .padding()
                .background(palette.backgroundBase, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .allowsHitTesting(false)
            }
        }
        #if os(tvOS)
        .onPlayPauseCommand {
            if isActive && (!preview.isExpanded || multiview.isEnabled) {
                multiview.requestPlayPause()
            }
        }
        #endif
    }

    private func playbackInput(
        for pane: LiveTVMultiviewPane, prepared: LiveTVPreparedStream
    ) -> LiveTVPrototypePlayback {
        let presentationID = playback.presentationID
        return LiveTVPrototypePlayback(
            paneID: pane.id,
            channel: prepared.channel, input: prepared.input,
            authenticatedHTTPResolver: playbackResolvers,
            previousChannel: { changeChannel(by: -1) },
            nextChannel: { changeChannel(by: 1) },
            isFavorite: model.favoriteIDs.contains(prepared.channel.id),
            canToggleFavorite: model.preferencesIssue != .loadFailed,
            onToggleFavorite: { model.toggleFavorite(prepared.channel.id) },
            isExpanded: preview.isExpanded && !multiview.isEnabled,
            returnToGuide: {
                guard playback.ownsPlayerPresentation(presentationID) else { return }
                returnToGuide()
            },
            playPauseRequest: pane.playPauseRequest,
            playbackStarted: {
                if multiview.isEnabled {
                    multiview.confirmWatching(pane.id, preparedID: prepared.id)
                } else {
                    playback.confirmWatching(prepared.id)
                }
            },
            reportingID: prepared.id,
            playbackUpdate: { multiview.report($0, paneID: pane.id, preparedID: prepared.id) },
            playbackFailed: {
                if multiview.isEnabled {
                    multiview.playbackFailed(pane.id, preparedID: prepared.id)
                } else {
                    playback.playbackFailed(prepared.id)
                }
            },
            videoAspectRatioChanged: {
                multiview.updateVideoAspectRatio($0, paneID: pane.id, preparedID: prepared.id)
            },
            preparingChannelName: pane.preparation.preparingChannelID.flatMap {
                model.channel(id: $0)?.name
            },
            isMultiview: multiview.isEnabled,
            isAudible: pane.id == multiview.audiblePaneID,
            openMultiview: {
                guard !hasAuthorizedExternalPlayback, activity.acceptsInteraction,
                      multiview.begin() else { return }
                updatePlaybackAvailability()
            },
            canOpenMultiview: !multiview.isEnabled && !hasAuthorizedExternalPlayback,
            isPlaybackActive: activity.isPlaybackActive,
            isAuthorized: !sourceApplicationFailed
                && authorizesPlayback(prepared),
            countsAsWatching: countsAsWatching(paneID: pane.id),
            externalContinuationChanged: {
                updateExternalPlayback($0, paneID: pane.id, preparedID: prepared.id)
            },
            restorePlayer: { await restorePlayer(paneID: pane.id, preparedID: prepared.id) },
            stopPlayback: { stopPlayer(paneID: pane.id, preparedID: prepared.id) }
        )
    }

    private func stopPlayer(paneID: UUID, preparedID: UUID) {
        guard let pane = multiview.panes.first(where: { $0.id == paneID }),
              pane.preparation.current?.id == preparedID else { return }
        if externalPlayback == PrototypeExternalPlayback(paneID: paneID, preparedID: preparedID) {
            externalPlayback = nil
        }
        if multiview.isEnabled, multiview.panes.count > 1 {
            multiview.remove(paneID)
            if multiview.panes.count == 1 { leaveMultiview() }
        } else {
            playback.stop()
            multiview.stop()
        }
        updatePlaybackAvailability()
    }

    private func countsAsWatching(paneID: UUID) -> Bool {
        let isExternal = hasAuthorizedExternalPlayback && externalPlayback?.paneID == paneID
        let visible = sheet == nil && multiviewSelection == nil && (multiview.isEnabled
            ? multiview.expandedPaneID == nil || multiview.expandedPaneID == paneID
            : preview.isExpanded || !isSearching)
        return activity.countsAsWatching(
            isUserRequested: isExternal || multiview.isEnabled || preview.isExpanded || preview.isHoldingWatchedChannel,
            isPictureVisible: visible, isExternallyPresented: isExternal
        )
    }

    private func leaveMultiview() {
        multiviewSelection = nil
        if let retained = multiview.exit() { playback.adoptPreparation(retained) }
        playback.setInteractionActive(activity.acceptsInteraction)
        updatePreviewAvailability()
    }

    private var presentedContent: some View {
        playerAndGuideSurface
        .sheet(item: $sheet, onDismiss: {
            if let favorite = pendingMultiviewFavorite {
                pendingMultiviewFavorite = nil
                restoreMultiviewFavorite(favorite)
            } else if pendingServerConnection {
                pendingServerConnection = false
                connectServer?()
            } else if let id = pendingTuneID {
                pendingTuneID = nil
                tune(id)
            }
        }) { destination in
            PrototypeSheetContent(
                model: model, imports: imports, destination: destination,
                reload: { reloadRequest += 1 },
                showGuide: {
                    model.guideOnly = true
                    topRequest += 1
                },
                guideOffset: Binding(
                    get: { guideOffset },
                    set: { guideOffset = $0; timelineOffset = 0 }
                ),
                goToNow: { nowRequest += 1 },
                guideStart: timeAnchor.addingTimeInterval(guideOffset),
                tune: { pendingTuneID = $0 },
                openMultiview: { pendingMultiviewFavorite = $0; sheet = nil },
                channelActionTitle: multiviewSelection?.title,
                sourceManagement: sources == nil ? nil : { AnyView(sourceSetupDestination($0)) }
            )
            .environment(\.themePalette, palette)
            .tint(palette.accent)
        }
        .alert("Multiview", isPresented: Binding(
            get: { isActive && (multiviewFavoriteIssue != nil || (!multiview.isEnabled && multiview.issue != nil)) },
            set: {
                if !$0 {
                    multiviewFavoriteIssue = nil
                    if !multiview.isEnabled { multiview.dismissIssue() }
                }
            }
        )) {
            Button("OK", role: .cancel) {
                multiviewFavoriteIssue = nil
                if !multiview.isEnabled { multiview.dismissIssue() }
            }
        } message: {
            if let issue = multiviewFavoriteIssue ?? multiview.issue { Text(issue) }
        }
        .alert("Can't play this channel", isPresented: Binding(
            get: { isActive && playback.watchFailure != nil },
            set: { if !$0 { playback.dismissFailure() } }
        ), presenting: playback.watchFailure) { failure in
            if failure.currentToStop != nil {
                Button("Stop current channel and retry", role: .destructive) {
                    playback.stopCurrentAndRetry(failure)
                }
            }
            Button("OK", role: .cancel) { playback.dismissFailure() }
        } message: { failure in
            Text(failure.message)
        }
        .alert("Live TV preferences unavailable", isPresented: Binding(
            get: { isActive && sheet == nil && model.preferencesIssue != nil },
            set: { if !$0 { model.dismissPreferencesIssue() } }
        )) {
            Button("Retry") { model.retryPreferences() }
            Button("Not now", role: .cancel) { model.dismissPreferencesIssue() }
        } message: {
            if model.preferencesIssue == .loadFailed {
                Text("Your Favorites, recently watched channels, and hidden channels could not be loaded. Retry before making changes. Your saved preferences have not been replaced.")
            } else {
                Text("The change to your Favorites, recently watched channels, or hidden channels could not be saved. Retry to keep it across sessions.")
            }
        }
    }

    private var loadingContent: some View {
        presentedContent
        .task(id: isActive ? reloadRequest : -1) {
            await reloadCatalog()
        }
        .task(id: preview.pendingRequest) {
            guard let request = preview.pendingRequest else { return }
            do {
                try await Task.sleep(for: LiveTVPreviewController.settlingDelay)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected preview timer failure: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            if await playback.preparePreview(request) {
                let elapsed = request.focusedAt.duration(to: ContinuousClock.now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                HandoffDiagnostics.emit(
                    "LIVE_TV event=previewCommit settleMs=\(String(format: "%.0f", milliseconds))"
                )
            }
        }
        .task(id: isActive) {
            while isActive && !Task.isCancelled {
                model.synchronizeClock()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var portableStateObservedContent: some View {
        loadingContent
        .onChange(of: scanBinding.coordinator.scanHiddenChannelIDs) { _, _ in
            scanBinding.synchronizeVisibility()
        }
        .onChange(of: holdsPlaybackIdentity, initial: true) { _, holding in
            portableIdentityHold.update(holding)
            if !holding, pendingPortableReload {
                pendingPortableReload = false
                loadedRequest = nil
                reloadRequest &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply)) { notification in
            guard notification.object as? String == profileID else { return }
            model.reloadPreferences()
            refreshSourceAuthority()
            if holdsPlaybackIdentity {
                pendingPortableReload = true
            } else {
                loadedRequest = nil
                reloadRequest &+= 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange)
                .receive(on: DispatchQueue.main)
        ) { notification in
            guard notification.object as? String == profileID else { return }
            refreshSourceAuthority()
        }
        .onChange(of: libraryCatalogRevision, initial: true) { _, revision in
            guard let revision else { return }
            publishLibraryGuide(
                channelIDs: Set(revision.channels.prefix(PrototypeGuideWindowRequest.rowLimit).map(\.id)),
                range: DateInterval(start: timeAnchor, duration: 6 * 3_600)
            )
        }
    }

    private var playerStateObservedContent: some View {
        portableStateObservedContent
        .onChange(of: playback.preparation.current?.id) { _, _ in
            playback.synchronizePlayerState()
            updatePlaybackAvailability()
        }
        .onChange(of: playback.preparation.isPreparing) { _, _ in
            playback.synchronizePlayerState()
        }
        .onChange(of: playback.canAutoPreview) { _, _ in
            updatePreviewAvailability()
        }
        .onChange(of: playback.acceptedWatchID) { _, _ in
            handleWatchAcceptance()
        }
        .onChange(of: model.channels) { _, _ in
            playback.validateAuthorization()
            multiview.validateAuthorization()
            updatePlaybackAvailability()
        }
        .onChange(of: imports.serverChannelReferences) { _, _ in
            playback.validateAuthorization()
            multiview.validateAuthorization()
            updatePlaybackAvailability()
        }
    }

    private var playbackObservedContent: some View {
        playerStateObservedContent
        .onChange(of: sources?.mutationRevision) { _, _ in
            guard applySourceConfiguration() else { return }
            loadedRequest = nil
            reloadRequest &+= 1
        }
        .onChange(of: sourceAuthority.contextIdentity) { _, _ in
            scanBinding.deactivate()
            refreshSourceAuthority()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange)) { _ in
            scanBinding.deactivate()
            refreshSourceAuthority()
        }
        .onChange(of: serverAuthorizationID) { _, _ in
            enrollment.invalidate()
            playbackResolvers.update(
                serverProviderResolver: serverProviderResolver,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            playback.validateAuthorization()
            multiview.validateAuthorization()
            do {
                try imports.setServerProviderResolver(
                    { [playbackResolvers] in playbackResolvers.provider(for: $0) }, into: model
                )
                playback.validateAuthorization()
                sourceApplicationFailed = false
                loadedRequest = nil
                reloadRequest &+= 1
            } catch {
                sourceApplicationFailed = true
                playback.stop()
                multiview.stop()
            }
            updatePlaybackAvailability()
        }
    }

    private var browsingObservedContent: some View {
        playbackObservedContent
        .onChange(of: selectedChannelID) { _, id in playback.focus(id) }
        .onChange(of: model.sort) { _, _ in persistViewFilters() }
        .onChange(of: model.favoritesOnly) { _, _ in persistViewFilters() }
        .onChange(of: model.guideOnly) { _, _ in persistViewFilters() }
        .onChange(of: controlsActive) { _, _ in updatePreviewAvailability() }
        .onChange(of: guideHasFocus) { _, _ in updatePreviewAvailability() }
        .onChange(of: sheet?.id) { _, _ in
            if sheet != nil { playback.cancelWatch() }
            else {
                managesLibraryChannels = false
                showsScanSources = false
            }
            updatePreviewAvailability()
            focusInitialChannelIfNeeded()
        }
        .onChange(of: model.guideChannels.first?.id, initial: true) { _, _ in
            focusInitialChannelIfNeeded()
        }
    }

    private var lifecycleContent: some View {
        browsingObservedContent
        .onChange(of: scenePhase, initial: true) { _, _ in
            updatePlaybackAvailability()
        }
        .onChange(of: isProfileAuthorized(), initial: true) { _, _ in
            if !isProfileAuthorized() { enrollment.invalidate() }
            updatePlaybackAvailability()
        }
        .onChange(of: allowsPlayback, initial: true) { _, _ in
            updatePlaybackAvailability()
        }
        .onChange(of: isActive, initial: true) { _, active in
            if !active {
                enrollment.invalidate()
                loadedRequest = nil
                pendingServerConnection = false
                pendingTuneID = nil
                pendingMultiviewFavorite = nil
                sheet = nil
                if !hasAuthorizedExternalPlayback {
                    leaveMultiview()
                    multiview.setActive(false)
                    playback.stop()
                }
            }
            if active {
                model.reloadPreferences()
                applyViewSettings()
            }
            updatePlaybackAvailability()
            if active { playback.focus(selectedChannelID) }
            focusInitialChannelIfNeeded()
        }
        .onChange(of: hidesAppNavigation, initial: true) { _, hidesChrome in
            onExpandedChange(hidesChrome)
        }
        .onAppear(perform: updatePlaybackAvailability)
        .onDisappear(perform: handleDisappearance)
    }

    private func handleDisappearance() {
        let preservesFullscreen = isActive && isProfileAuthorized() && usesNativeFullscreen && preview.isExpanded
        guard !preservesFullscreen, !hasAuthorizedExternalPlayback else { return }
        enrollment.invalidate()
        leaveMultiview()
        multiview.setActive(false)
        playback.setActive(false)
        scanBinding.deactivate()
        portableIdentityHold.update(false)
        onExpandedChange(false)
    }

    private var holdsPlaybackIdentity: Bool {
        multiview.panes.contains { $0.preparation.current != nil || $0.preparation.isPreparing }
            || playback.pendingWatchChannelID != nil
    }

    @ViewBuilder
    private func guideContent(_ layout: PrototypePreviewLayout, canvasWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let sources, !sources.hasLoaded || sourceApplicationFailed {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVSourceLoadState(
                        issue: sources.loadIssue,
                        applicationFailed: sourceApplicationFailed,
                        retry: { loadedRequest = nil; reloadRequest &+= 1 }
                    )
                }
            } else if model.channels.isEmpty, let automaticChannels,
                      automaticChannels.needsEmptyState, canManageLibraryChannels {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVAutomaticChannelsEmptyView(state: automaticChannels) {
                        managesLibraryChannels = true
                        sheet = .sources
                    }
                }
            } else if model.channels.isEmpty, blockedPlaylistCount > 0 {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    ContentUnavailableView {
                        Label("Source approval needed", systemImage: "lock")
                    } description: {
                        Text("Ask a parent to approve your IPTV sources. One approval covers every channel in a source.")
                    } actions: {
                        Button("Manage sources") { sheet = .sources }
                    }
                }
            } else if let sources,
                      model.channels.isEmpty,
                      sources.configuration.playlists.isEmpty && sources.configuration.servers.isEmpty {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVSetupWelcome(
                        addPlaylist: { sheet = .addPlaylist },
                        useServer: { sheet = .serverSetup },
                        issue: sources.mutationIssue?.message,
                        serverStatuses: enrollment.statuses.filter { $0.phase != .idle },
                        createChannel: canManageLibraryChannels ? {
                            managesLibraryChannels = true
                            sheet = .sources
                        } : nil,
                        automaticChannels: automaticChannels
                    )
                }
            } else if let sources,
                      model.channels.isEmpty,
                      !sources.configuration.playlists.contains(where: \.isEnabled),
                      !sources.configuration.servers.contains(where: \.isEnabled) {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    ContentUnavailableView {
                        Label("Your sources are paused", systemImage: "pause.circle")
                    } description: {
                        Text("Enable a source to bring its channels back to the guide.")
                    } actions: {
                        Button("Manage sources") { sheet = .sources }
                    }
                }
            } else {
                catalogGuideContent(layout, canvasWidth: canvasWidth)
            }
        }
    }

    @ViewBuilder
    private func catalogGuideContent(_ layout: PrototypePreviewLayout, canvasWidth: CGFloat) -> some View {
        #if os(tvOS)
        if isSearching {
            PrototypeGuidePlacement(frame: layout.bounds, canvasWidth: canvasWidth) {
                PrototypeNativeSearch(
                    query: $model.query, restoresGuideFocus: preview.isRestoringGuideFocus,
                    isPresented: isActive && isGuidePresented && sheet == nil,
                    close: closeSearch, editing: { controlsActive = true }
                ) { dismissSearch in
                    VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                        if let multiviewSelection {
                            LiveTVMultiviewGuideSelectionHeader(
                                selection: multiviewSelection, cancel: finishMultiviewSelection)
                        }
                        searchScopePicker
                        if searchScope == .channels {
                            PrototypeSearchSummary(channelCount: model.visibleChannels.count, category: model.category)
                        }
                        searchResults(closeSearch: dismissSearch)
                    }
                    .ignoresSafeArea(.container, edges: [.bottom, .trailing])
                    .environment(\.themePalette, palette)
                    .environment(\.plozzReduceTransparency, reduceTransparency)
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.locale, locale)
                }
            }
            .transition(.opacity)
        } else {
            PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                browsingContent(layout)
            }
            .transition(.opacity)
        }
        #else
        PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
            browsingContent(layout)
        }
        #endif
    }

    @ViewBuilder
    private func sourceSetupDestination(_ destination: PrototypeSheet) -> some View {
        if let sources {
            switch destination {
            case .addPlaylist:
                LiveTVSourceAccessGate(model: sources) {
                    LiveTVPlaylistEditor { input in
                        let previous = Set(sources.configuration.playlists.map(\.id))
                        try sources.savePlaylist(input: input)
                        pendingScanOfferSourceID = sources.configuration.playlists.last {
                            !previous.contains($0.id)
                        }?.id
                        didConfigurePlaylist()
                    }
                }
            case .serverSetup:
                LiveTVSourceAccessGate(model: sources) {
                    LiveTVServerSetupView(
                        sources: sources, choices: serverChoices,
                        resolver: serverProviderResolver,
                        connectServer: connectServer == nil ? nil : requestServerConnection
                    )
                }
            default:
                LiveTVSourcesView(
                    model: sources, imports: imports, refresh: { reloadRequest &+= 1 },
                    serverChoices: serverChoices, serverProviderResolver: serverProviderResolver,
                    connectServer: connectServer == nil ? nil : requestServerConnection,
                    sourceFilterID: model.configuredSourceID,
                    browseSource: { sourceID in
                        model.source = nil
                        model.configuredSourceID = sourceID
                        topRequest &+= 1
                        sheet = nil
                    },
                    didConfigurePlaylist: didConfigurePlaylist,
                    createChannel: canManageLibraryChannels ? { managesLibraryChannels = true } : nil,
                    scanChannels: { showsScanSources = true },
                    scanCoordinator: scanBinding.coordinator,
                    didImportPlaylist: { pendingScanOfferSourceID = $0 }
                )
                .navigationDestination(isPresented: $managesLibraryChannels) {
                    if let libraryService, let libraryHistory {
                        LibraryChannelManagementView(
                            service: libraryService, history: libraryHistory,
                            prepareLibraries: prepareLibraryChannels, automaticChannels: automaticChannels)
                        .navigationDestination(isPresented: $showsScanSources) {
                            LiveTVSourceAccessGate(model: sources) {
                                if scanBinding.issue != nil {
                                    LiveTVSettingsPage(title: "Check channels") {
                                        SettingsSectionGroup {
                                            Text("Channel checks are unavailable. Your channel preferences are unchanged.")
                                            Button("Retry", action: scanBinding.retry)
                                                .buttonStyle(PrototypeButtonStyle())
                                        }
                                    }
                                } else {
                                    LiveTVScanSourcesView(
                                        coordinator: scanBinding.coordinator,
                                        sourceNames: Dictionary(uniqueKeysWithValues: imports.configuration.playlists.map {
                                            ($0.id, $0.name)
                                        })
                                    )
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    private func requestServerConnection() {
        pendingTuneID = nil
        pendingServerConnection = true
        sheet = nil
    }

    private var libraryCatalogRevision: PrototypeLibraryCatalogRevision? {
        libraryService.map { PrototypeLibraryCatalogRevision(service: $0, isAuthorized: libraryIsAuthorized()) }
    }

    private var canManageLibraryChannels: Bool {
        libraryService != nil && libraryHistory != nil
    }

    private func publishLibraryGuide(channelIDs: Set<String>, range: DateInterval) {
        guard let libraryService else { return }
        installCatalogHooks()
        do {
            let channels = libraryIsAuthorized() ? libraryService.channels : []
            let allowed = Set(channels.map(\.id))
            let programs = allowed.isEmpty ? [] : try libraryService.programmes(
                channelIDs: channelIDs.intersection(allowed), from: range.start, to: range.end
            )
            try imports.setGeneratedCatalog(channels: channels, programs: programs, into: model)
            libraryGuideIssue = nil
        } catch {
            libraryGuideIssue = (error as? LibraryChannelError) ?? .storageFailed
            do {
                try imports.setGeneratedCatalog(channels: [], programs: [], into: model)
            } catch {
                sourceApplicationFailed = true
                playback.stop()
                multiview.stop()
                HandoffDiagnostics.emit("LIVE_TV event=libraryCatalogRetirementFailed")
            }
        }
        playback.validateAuthorization()
        multiview.validateAuthorization()
        updatePlaybackAvailability()
    }

    private func reloadCatalog() async {
        guard isActive, loadedRequest != reloadRequest else { return }
        installCatalogHooks()
        let request = reloadRequest
        if let sources {
            sources.reload()
            guard sources.hasLoaded, applySourceConfiguration() else {
                playback.validateAuthorization()
                return
            }
        }
        async let enrolled = enrollAuthorizedServers()
        await imports.reload(into: model)
        let added = await enrolled
        guard !Task.isCancelled, request == reloadRequest, isProfileAuthorized() else { return }
        if !added.isEmpty, let sources {
            sources.reload()
            guard sources.hasLoaded, applySourceConfiguration() else { return }
            await imports.reloadServers(into: model)
        }
        if !Task.isCancelled, request == reloadRequest { loadedRequest = request }
    }

    private func enrollAuthorizedServers() async -> [String] {
        guard let sourceStore, sources?.hasLoaded == true, isProfileAuthorized(),
              !serverChoices.isEmpty else { return [] }
        return await enrollment.refresh(
            choices: serverChoices, resolver: serverProviderResolver,
            configuration: { try sourceStore.load() },
            suppressedAccountIDs: { try enrollmentSuppression.suppressedAccountIDs() },
            apply: { updated in
                guard isProfileAuthorized() else {
                    throw PrototypeEnrollmentCommitError.authorizationChanged
                }
                let current = try sourceStore.load()
                let suppressed = try enrollmentSuppression.suppressedAccountIDs()
                guard updated.playlists == current.playlists,
                      current.servers.allSatisfy({ updated.servers.contains($0) }),
                      updated.servers.allSatisfy({ source in
                          current.servers.contains(source) || !suppressed.contains(source.accountID)
                      }) else {
                    throw PrototypeEnrollmentCommitError.configurationChanged
                }
                try updated.validate()
                try sourceStore.save(updated)
            }
        )
    }

    @discardableResult
    private func applySourceConfiguration() -> Bool {
        guard let sources, sources.hasLoaded else { return false }
        do {
            let authorization = try sourceAuthority.authorization(configuration: sources.configuration)
            try imports.applyConfiguration(authorization.filtering(sources.configuration), into: model)
            appliedSourceAuthorizationID = authorization.identity
            playback.validateAuthorization()
            multiview.validateAuthorization()
            sourceApplicationFailed = false
            updatePlaybackAvailability()
            return true
        } catch {
            sourceApplicationFailed = true
            externalPlayback = nil
            multiview.setActive(false)
            playback.stop()
            updatePlaybackAvailability()
            return false
        }
    }

    private func refreshSourceAuthority() {
        guard let sources else { return }
        let previousConfiguration = sources.configuration
        sources.reload()
        guard sources.hasLoaded else {
            sourceApplicationFailed = true
            updatePlaybackAvailability()
            return
        }
        let previous = appliedSourceAuthorizationID
        guard applySourceConfiguration() else { return }
        if previous != appliedSourceAuthorizationID || previousConfiguration != sources.configuration {
            loadedRequest = nil
            reloadRequest &+= 1
        }
    }

    private func browsingContent(_ layout: PrototypePreviewLayout) -> some View {
        VStack(spacing: PrototypeLayout.sectionGap) {
            ZStack(alignment: .bottomLeading) {
                PrototypePreviewHero(
                    channel: heroChannel, program: heroProgram, layout: layout,
                    watch: { if let id = heroChannel?.id { tune(id) } },
                    watchTitle: multiviewSelection?.title
                )
                .opacity(isSearching ? 0 : 1)
                .allowsHitTesting(!isSearching)
                .accessibilityHidden(isSearching)
                #if os(iOS)
                if isSearching {
                    PrototypeSearchHeader(
                        query: $model.query, channelCount: model.visibleChannels.count,
                        category: model.category, focusRequest: searchFocusRequest,
                        browse: enterGuide, close: closeSearch,
                        focusChanged: { if $0 { controlsActive = true } }
                    )
                    .frame(maxWidth: min(layout.contentFrame.width, 1_200), alignment: .leading)
                    .disabled(blocksBrowseControls)
                    .transition(.opacity)
                }
                #endif
            }
            .frame(height: layout.heroHeight, alignment: .bottomLeading)
            if let multiviewSelection {
                LiveTVMultiviewGuideSelectionHeader(
                    selection: multiviewSelection, cancel: finishMultiviewSelection)
            }
            if heroIsGuideOnly && !isSearching {
                Text("Guide only · This server's Live TV playback mode isn't supported yet.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            if blockedPlaylistCount > 0 && !isSearching {
                Text("Some IPTV sources need parental approval in Sources.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            if let issue = libraryGuideIssue ?? libraryIssue, !isSearching {
                HStack {
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    if let reloadLibrary {
                        Button("Retry Plozz channels", action: reloadLibrary)
                            .buttonStyle(PrototypeButtonStyle())
                    }
                }
                if let pendingScanOfferSourceID, !isSearching {
                    LiveTVScanImportOffer(
                        coordinator: scanBinding.coordinator, sourceID: pendingScanOfferSourceID,
                        skip: { self.pendingScanOfferSourceID = nil }
                    )
                }
            }
            HStack(alignment: .top, spacing: PrototypeLayout.sectionGap) {
                if layout.sidebarWidth > 0 {
                    PrototypeBrowseSidebar(
                        model: model, active: $controlsActive,
                        focusRequest: toolbarFocusRequest, isSearching: isSearching,
                        search: { if isSearching { closeSearch() } else { openSearch() } },
                        enterGuide: enterGuide,
                        multiviews: multiviewSelection == nil ? { sheet = .multiviewFavorites } : nil
                    )
                    .modifier(LiveTVMultiviewGuideExit(
                        cancel: multiviewSelection == nil ? nil : finishMultiviewSelection))
                    .frame(width: layout.sidebarWidth)
                    .disabled(blocksBrowseControls)
                }
                VStack(spacing: PrototypeLayout.sectionGap) {
                    if layout.sidebarWidth == 0 {
                        PrototypeBrowseToolbar(
                            model: model, active: $controlsActive,
                            focusRequest: toolbarFocusRequest,
                            compact: layout.contentFrame.width < 650,
                            isSearching: isSearching,
                            search: { if isSearching { closeSearch() } else { openSearch() } },
                            filters: { sheet = .filters },
                            multiviews: multiviewSelection == nil ? { sheet = .multiviewFavorites } : nil
                        )
                        .modifier(LiveTVMultiviewGuideExit(
                            cancel: multiviewSelection == nil ? nil : finishMultiviewSelection))
                        .disabled(blocksBrowseControls)
                    }
                    if isSearching {
                        searchScopePicker
                        searchResults(closeSearch: closeSearch)
                    } else {
                        guideBrowser(closeSearch: closeSearch)
                    }
                }
                .frame(width: layout.guideWidth + layout.guideTrailingExtension)
                .padding(.trailing, -layout.guideTrailingExtension)
                .padding(.bottom, -layout.guideBottomExtension)
            }
        }
    }

    private func guideBrowser(closeSearch: @escaping () -> Void) -> some View {
        PrototypeBrowser(
            model: model, imports: imports,
            selectedID: $selectedChannelID, selectedRowID: $selectedRowID,
            railActive: $controlsActive, focusedProgram: $focusedProgram, hasFocus: $guideHasFocus,
            topRequest: topRequest, nowRequest: nowRequest, guideOffset: $guideOffset,
            timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
            restoreFocusRequest: preview.focusRestoreRequest,
            isPresented: isActive && isGuidePresented && sheet == nil,
            isRestoringFocus: preview.isRestoringGuideFocus,
            restoresPlaybackFocus: preview.restoresPlaybackFocus, watchOrigin: preview.watchOrigin,
            focusRestored: {
                preview.completeGuideFocusRestore($0, focusedChannelID: selectedChannelID)
            },
            tune: { tune($0.channelID, origin: $0) },
            details: { sheet = .program($0) }, openControls: openSearch,
            openSources: { sheet = .sources }, openGuideTime: { sheet = .guideTime },
            openToolbar: {
                if playback.pendingWatchChannelID != nil {
                    playback.cancelWatch()
                    return
                }
                guard !preview.isRestoringGuideFocus else { return }
                if isSearching {
                    closeSearch()
                    return
                }
                controlsActive = true
                toolbarFocusRequest &+= 1
            },
            isLoading: model.channels.isEmpty && (imports.catalogPhase == .idle || imports.catalogPhase == .loading),
            loadFailed: imports.catalogPhase == .failed,
            reload: { reloadRequest += 1 },
            hideChannel: hideChannel,
            selectionAction: multiviewSelection?.title,
            selectedChannelIDs: multiviewSelection == nil ? [] : Set(multiview.panes.compactMap { $0.channel?.id }),
            libraryCatalog: libraryCatalogRevision,
            loadLibraryGuide: publishLibraryGuide
        )
    }

    private var searchScopePicker: some View {
        Picker("Search in", selection: $searchScope) {
            Text("Channels").tag(PrototypeSearchScope.channels)
            Text("Programs").tag(PrototypeSearchScope.programs)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityIdentifier("live-tv-search-scope")
        .onChange(of: searchScope) { _, _ in
            focusedProgram = nil
            playback.focus(nil)
        }
    }

    @ViewBuilder
    private func searchResults(closeSearch: @escaping () -> Void) -> some View {
        if searchScope == .channels {
            guideBrowser(closeSearch: closeSearch)
        } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("Search programs", systemImage: "magnifyingglass")
            } description: {
                Text("Search for a program in your available guide.")
            }
        } else {
            ScrollView {
                LiveTVProgramSearchView(
                    imports: imports, model: model, query: model.query,
                    watch: { tune($0.id) },
                    showDetails: { sheet = .program($0) }
                )
                .padding(PrototypeLayout.sectionGap)
            }
            .accessibilityIdentifier("live-tv-program-search-results")
        }
    }

    private var hidesAppNavigation: Bool {
        if showingMultiview { return isActive }
        #if os(tvOS)
        return preview.suppressesNavigation(isActive: isActive, isSearching: isSearching)
        #else
        return preview.suppressesNavigation(isActive: isActive)
        #endif
    }

    private var showingMultiview: Bool { multiview.isEnabled && multiviewSelection == nil }
    private var isGuidePresented: Bool { !showingMultiview && !preview.isExpanded }

    private func beginMultiviewSelection(_ selection: LiveTVMultiviewSelection) {
        guard activity.acceptsInteraction, multiview.isEnabled else { return }
        multiviewSelection = selection
        returnToGuide()
        if !preview.isRestoringGuideFocus { enterGuide() }
    }

    private func finishMultiviewSelection() {
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: selectedChannelID)
        controlsActive = false
        multiviewSelection = nil
    }

    private func toggleMultiviewFavorite() {
        if let favorite = model.favoriteMultiviews.first(where: multiview.matches) {
            model.removeMultiviewFavorite(favorite.id)
        } else if let favorite = multiview.favoriteSnapshot() {
            model.saveMultiviewFavorite(favorite)
        } else {
            multiviewFavoriteIssue = "Wait for the channels to load before saving this Multiview."
        }
    }

    private func restoreMultiviewFavorite(_ favorite: LiveTVMultiviewFavorite) {
        guard activity.acceptsInteraction else { return }
        guard multiview.restore(favorite, from: model.channels),
              let first = favorite.channelIDs.first else { return }
        updatePlaybackAvailability()
        preview.watch(first)
    }

    private var blocksBrowseControls: Bool {
        #if os(tvOS)
        if !preview.hasRequestedInitialGuideFocus,
           model.guideChannels.first != nil || imports.catalogPhase == .idle || imports.catalogPhase == .loading {
            return true
        }
        #endif
        return preview.isRestoringGuideFocus
    }

    private func focusInitialChannelIfNeeded() {
        #if os(tvOS)
        guard let row = preview.requestInitialGuideFocus(
            isActive: isActive, hasOverlay: isSearching || sheet != nil
        ) else { return }
        selectedRowID = row
        selectedChannelID = row.channelID
        focusedProgram = nil
        controlsActive = false
        #endif
    }

    private var heroChannel: LiveTVPrototypeChannel? {
        (selectedChannelID ?? model.playingChannelID).flatMap { model.channel(id: $0) }
    }

    private var blockedPlaylistCount: Int {
        guard let sources, sources.hasLoaded, !sourceApplicationFailed else { return 0 }
        let enabled = Set(sources.configuration.playlists.filter(\.isEnabled).map(\.id))
        return enabled.subtracting(imports.configuration.playlists.map(\.id)).count
    }

    private var heroProgram: LiveTVPrototypeProgram? {
        if let focusedProgram, focusedProgram.channelID == heroChannel?.id { return focusedProgram }
        return heroChannel.flatMap { model.currentProgram(for: $0.id) }
    }

    private var heroIsGuideOnly: Bool {
        guard let channel = heroChannel, let reference = imports.serverChannelReferences[channel.id] else {
            return false
        }
        return imports.serverSources.first(where: { $0.id == reference.sourceID })?
            .availability?.status == .unsupportedPlaybackMode
    }

    private func updatePreviewAvailability() {
        #if os(tvOS)
        let canFollowFocus = guideHasFocus
        #else
        let canFollowFocus = true
        #endif
        preview.setBrowsingActive(
            activity.acceptsInteraction && playback.canAutoPreview
                && sheet == nil && !controlsActive && canFollowFocus && !multiview.isEnabled
        )
    }

    private func updatePlaybackAvailability() {
        if externalPlayback != nil && !hasAuthorizedExternalPlayback { externalPlayback = nil }
        let active = activity.isPlaybackActive
        scanBinding.setActive(
            isActive && scenePhase == .active && isProfileAuthorized()
                && !sourceApplicationFailed && allowsPlayback && (sources?.hasLoaded ?? true)
        )
        if !active && multiview.isEnabled { leaveMultiview() }
        multiview.setActive(active)
        playback.setActive(active)
        playback.setInteractionActive(activity.acceptsInteraction && !multiview.isEnabled)
        updatePreviewAvailability()
        if activity.acceptsInteraction { playback.focus(selectedChannelID) }
    }

    private func installCatalogHooks() {
        imports.beforeCatalogPublication = { [weak scanBinding] configuration, channels in
            scanBinding?.updateCatalog(configuration, channels: channels)
        }
        imports.beforeSourceRefresh = { [weak scanBinding] in scanBinding?.invalidate($0) }
        imports.generatedProgramLoader = { [weak libraryService, libraryIsAuthorized] channelIDs, range in
            guard let libraryService, libraryIsAuthorized() else {
                throw LibraryChannelError.authorizationChanged
            }
            return try libraryService.programmes(
                channelIDs: channelIDs, from: range.start, to: range.end
            )
        }
    }

    private func authorizesPlayback(_ prepared: LiveTVPreparedStream) -> Bool {
        // Parent updates can discard new init candidates; use the installed State owners.
        let channel = prepared.channel
        guard isProfileAuthorized(), sources?.hasLoaded ?? true,
              channel.source != .plozz || libraryIsAuthorized(),
              sourceAuthority.allows(channel, configuration: sources?.configuration ?? imports.configuration),
              LiveTVPlaybackCatalogAuthorization.allows(
                channel, reference: prepared.serverReference, model: model, imports: imports,
                configuration: sources?.configuration ?? imports.configuration,
                libraryService: libraryService
              ) else { return false }
        if case .libraryChannel(let id, let authorizationID) = prepared.input {
            return prepared.authorizationID == authorizationID
                && libraryService?.playbackAuthorizationID(channelID: id) == authorizationID
        }
        return true
    }

    private var activity: LiveTVPlaybackActivity {
        LiveTVPlaybackActivity(
            isDestinationActive: isActive, isSceneActive: scenePhase == .active,
            isInBackground: scenePhase == .background,
            isAuthorized: isProfileAuthorized() && !sourceApplicationFailed && (sources?.hasLoaded ?? true),
            allowsPlayback: allowsPlayback,
            hasAuthorizedExternalPresentation: hasAuthorizedExternalPlayback
        )
    }

    private var hasAuthorizedExternalPlayback: Bool {
        guard allowsPlayback, !sourceApplicationFailed, !multiview.isEnabled, multiview.panes.count == 1,
              let externalPlayback,
              let pane = multiview.panes.first(where: { $0.id == externalPlayback.paneID }),
              let prepared = pane.preparation.current, prepared.id == externalPlayback.preparedID else {
            return false
        }
        return authorizesPlayback(prepared)
    }

    private func updateExternalPlayback(_ continuing: Bool, paneID: UUID, preparedID: UUID) {
        let identity = PrototypeExternalPlayback(paneID: paneID, preparedID: preparedID)
        if !continuing {
            if externalPlayback == identity { externalPlayback = nil }
            updatePlaybackAvailability()
            return
        }
        guard allowsPlayback, !sourceApplicationFailed, !multiview.isEnabled,
              let pane = multiview.panes.first(where: { $0.id == paneID }),
              let prepared = pane.preparation.current, prepared.id == preparedID,
              authorizesPlayback(prepared) else { return }
        externalPlayback = identity
        updatePlaybackAvailability()
    }

    private func restorePlayer(paneID: UUID, preparedID: UUID) async -> Bool {
        guard allowsPlayback, !sourceApplicationFailed,
              let pane = multiview.panes.first(where: { $0.id == paneID }),
              let prepared = pane.preparation.current, prepared.id == preparedID,
              authorizesPlayback(prepared) else { return false }
        if !isActive, !(await restoreDestination()) { return false }
        guard pane.preparation.current?.id == preparedID, allowsPlayback, !sourceApplicationFailed,
              authorizesPlayback(prepared) else { return false }
        preview.watch(prepared.channel.id)
        return true
    }

    private func returnToGuide() {
        playback.cancelWatch()
        model.synchronizeClock()
        controlsActive = false
        #if os(tvOS)
        preview.returnToGuide()
        #else
        preview.returnToGuide(restoresFocus: false)
        #endif
    }

    private func openSearch() {
        playback.cancelWatch()
        guard !isSearching else {
            searchFocusRequest &+= 1
            return
        }
        #if os(tvOS)
        // Exclude both native and custom shell navigation before UIKit presents
        // its keyboard and claims focus.
        onExpandedChange(true)
        #endif
        searchOrigin = PrototypeSearchBookmark(
            row: selectedRowID, guideOffset: guideOffset, timeAnchor: timeAnchor, timelineOffset: timelineOffset
        )
        guideOffset = 0
        timelineOffset = 0
        timeAnchor = Date(timeIntervalSince1970: floor(model.now.timeIntervalSince1970 / 1_800) * 1_800)
        #if os(tvOS)
        selectedRowID = model.guideChannels.first?.id
        selectedChannelID = selectedRowID?.channelID
        focusedProgram = nil
        #endif
        controlsActive = true
        isSearching = true
        searchFocusRequest &+= 1
    }

    private func closeSearch() {
        playback.cancelWatch()
        guard isSearching else { return }
        model.query = ""
        if let bookmark = searchOrigin {
            guideOffset = bookmark.guideOffset
            timeAnchor = bookmark.timeAnchor
            timelineOffset = bookmark.timelineOffset
        }
        if let origin = searchOrigin?.row, let row = model.guideRow(for: origin.channelID, preferring: origin.section) {
            selectedRowID = row
            selectedChannelID = row.channelID
        }
        searchOrigin = nil
        enterGuide()
        isSearching = false
    }

    private func enterGuide() {
        controlsActive = false
        guard isActive else { return }
        #if os(tvOS)
        preview.requestBrowsingFocus()
        #endif
    }

    private func hideChannel(_ channel: LiveTVPrototypeChannel, from row: LiveTVGuideRowID) {
        let replacement = LiveTVGuideFocusTarget.rowAfterHiding(row, in: model.guideChannels)
        guard model.hideChannel(channel) else { return }
        selectedRowID = replacement
        selectedChannelID = replacement?.channelID
        focusedProgram = nil
        if replacement != nil {
            enterGuide()
        } else {
            controlsActive = true
            if !multiview.isEnabled && preview.followsFocus && !preview.isHoldingWatchedChannel { playback.stop() }
            toolbarFocusRequest &+= 1
        }
    }

    private func applyViewSettings() {
        guard let settings = viewSettingsStore?.load() else { return }
        model.sort = settings.sortByName ? .name : .channelNumber
        model.favoritesOnly = settings.favoritesOnly
        model.guideOnly = settings.guideOnly
        preview.setKeepWatchingWhileBrowsing(settings.keepWatchingWhileBrowsing)
        #if os(tvOS)
        preview.setFollowsFocus(settings.autoPreview)
        #endif
    }

    private func persistViewFilters() {
        guard let viewSettingsStore else { return }
        let current = viewSettingsStore.load()
        var settings = current
        settings.sortByName = model.sort == .name
        settings.favoritesOnly = model.favoritesOnly
        settings.guideOnly = model.guideOnly
        if settings != current { viewSettingsStore.save(settings) }
    }

    private func tune(_ id: String, origin: LiveTVGuideRowID? = nil) {
        guard activity.acceptsInteraction else {
            HandoffDiagnostics.emit("LIVE_TV event=watchIgnored reason=inactiveDestination")
            return
        }
        if let selection = multiviewSelection {
            guard let channel = model.channel(id: id) else {
                multiviewFavoriteIssue = "This channel is no longer available."
                return
            }
            selection.apply(channel, to: multiview)
            finishMultiviewSelection()
            return
        }
        if !preview.isExpanded {
            let channels: [LiveTVPrototypeChannel]
            if isSearching && searchScope == .programs {
                let allowed = model.programmeSearchChannelIDs
                channels = model.unhiddenCatalogChannels.filter { allowed.contains($0.id) }
            } else {
                channels = model.guideChannels.map(\.channel)
            }
            channelSequence = LiveTVChannelSequence(channels: channels)
        }
        let selectedOrigin = !preview.isExpanded && selectedRowID?.channelID == id ? selectedRowID : nil
        playback.watch(id, origin: origin ?? selectedOrigin)
    }

    private func handleWatchAcceptance() {
        guard isActive, preview.isExpanded, let current = playback.preparation.current else { return }
        #if os(tvOS)
        onExpandedChange(true)
        #endif
        selectedChannelID = current.channel.id
        selectedRowID = preview.watchOrigin
        focusedProgram = nil
        controlsActive = false
    }

    private func changeChannel(by offset: Int) {
        guard let id = channelSequence.neighbor(
            of: playback.pendingWatchChannelID ?? playback.preparation.current?.channel.id,
            offset: offset, visibleChannels: model.visibleChannels
        ) else { return }
        tune(id)
    }
}

private struct PrototypeWatchPreparationStatus: View {
    let channelName: String
    let cancel: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack {
            ProgressView()
            Text("Opening \(channelName)")
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding()
        .background(palette.backgroundBase, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

struct PrototypeImportStatus: View {
    let imports: LiveTVPrototypeImportModel
    let listedChannels: Int

    var body: some View {
        if imports.playlistPhase == .loading || imports.playlistPhase == .idle {
            Label("Loading playlist", systemImage: "arrow.down.circle")
        } else if imports.playlistPhase == .failed {
            Label("Playlist update failed · Open Sources", systemImage: "wifi.exclamationmark")
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                if imports.enabledSourceIDs.isEmpty {
                    Text("Guide sources off · Channels ready")
                } else {
                    switch imports.guidePhase {
                    case .idle:
                        Label("Guide not loaded · Open Sources", systemImage: "calendar")
                    case .loading:
                        Text("Loading guides · \(imports.completedSourceCount) of \(imports.enabledSourceIDs.count) sources")
                        Text("\(listedChannels) channels with listings so far")
                    case .failed:
                        Label("Guide update failed · Channels ready", systemImage: "wifi.exclamationmark")
                    case .loaded:
                        if let end = imports.coverageEnd, end < Date() {
                            Label("Guide listings are out of date", systemImage: "clock.badge.exclamationmark")
                        } else {
                            Text("Guide listings for \(listedChannels) channels")
                        }
                    }
                    if imports.failedSourceCount > 0 {
                        Text("\(imports.failedSourceCount) guide sources unavailable · Open Sources")
                    }
                }
            }
        }
    }
}
#endif
