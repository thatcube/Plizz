#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import MediaDownloads
import MetadataKit
import RatingsService
import SeerService
import TraktService
import SwiftUI

struct PlozziOSItemDetailView: View {
    @Environment(HomeViewModel.self) private var homeViewModel: HomeViewModel?
    let appModel: PlozziOSAppModel
    let provider: any MediaProvider
    let item: MediaItem
    let seerService: SeerService?
    let originSourceAccountID: String?
    /// Show this episode as the page's own subject instead of redirecting to its
    /// series.
    ///
    /// Every other way of reaching an episode — a tapped card, a deep link —
    /// means "show me this episode in context", which is the series page with it
    /// fronted. "Episode Info" means the opposite: this episode's own synopsis,
    /// air date and the file that would play.
    let presentsEpisodeAsSubject: Bool

    @State private var resolvedSeries: MediaItem?
    @State private var resolvedContextItem: MediaItem?
    /// Pre-built `Text` because the two sources differ in kind: an `AppError`
    /// carries our own localizable resource, while `localizedDescription` is a
    /// string Foundation has ALREADY localized and must not be re-looked-up.
    @State private var resolutionError: Text?
    @State private var retryToken = 0

    init(
        appModel: PlozziOSAppModel,
        provider: any MediaProvider,
        item: MediaItem,
        seerService: SeerService? = nil,
        originSourceAccountID: String? = nil,
        presentsEpisodeAsSubject: Bool = false
    ) {
        self.appModel = appModel
        self.provider = provider
        self.item = item
        self.seerService = seerService
        self.presentsEpisodeAsSubject = presentsEpisodeAsSubject
        self.originSourceAccountID = originSourceAccountID
    }

    var body: some View {
        detailBody
            // Each detail page installs its own router. A pushed destination —
            // whether from an inline `NavigationLink` or a
            // `navigationDestination` — does not inherit environment installed
            // on the stack that owns it, so the tab-level router is nil here and
            // navigation actions ("Episode Info") were filtered out of every
            // menu on this page.
            .plozziOSItemNavigation(appModel: appModel)
    }

    @ViewBuilder
    private var detailBody: some View {
        if let library = MediaFolderNavigation.library(
            for: item,
            providerKind: provider.kind,
            sourceAccountID: originSourceAccountID ?? item.sourceAccountID ?? provider.session.server.id
        ) {
            PlozziOSLibraryGridView(
                viewModel: LibraryBrowseViewModel(
                    provider: provider,
                    containerID: library.id,
                    containerKind: library.kind,
                    sourceAccountID: library.sourceAccountID
                ),
                title: library.title,
                provider: provider,
                settings: appModel.settings,
                scanStatus: appModel.shareScanStatus
            )
        } else if shouldResolveSeries {
            if let resolvedSeries {
                canonicalDetail(for: resolvedSeries)
            } else if let resolutionError {
                ContentUnavailableView {
                    Label(
                        "Unable to load show",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    resolutionError
                } actions: {
                    Button("Try Again") {
                        self.resolutionError = nil
                        retryToken &+= 1
                    }
                }
                .task(id: retryToken) { await resolveSeries() }
            } else {
                ProgressView("Loading show…")
                    .task(id: retryToken) { await resolveSeries() }
            }
        } else {
            canonicalDetail(for: item)
        }
    }

    private var shouldResolveSeries: Bool {
        guard !(presentsEpisodeAsSubject && item.kind == .episode) else { return false }
        return !item.isNotInLibraryDiscovery
            && (item.kind == .episode || item.kind == .season)
            && item.seriesID != nil
    }

    private func canonicalDetail(for resolvedItem: MediaItem) -> some View {
        let contextItem = resolvedContextItem ?? item
        return PlozziOSCanonicalItemDetailView(
            appModel: appModel,
            provider: provider,
            item: resolvedItem,
            continueWatching: homeViewModel?.continueWatchingForDetail ?? [],
            seerService: seerService,
            originSourceAccountID: originSourceAccountID,
            initialSeasonID: contextItem.kind == .season
                ? contextItem.id
                : contextItem.seasonID,
            initialEpisode: contextItem.kind == .episode
                ? contextItem
                : nil,
            presentsEpisodeAsSubject: presentsEpisodeAsSubject
        )
    }

    private func resolveSeries() async {
        do {
            var contextItem = (try? await provider.item(id: item.id)) ?? item
            if contextItem.sourceAccountID == nil,
               let sourceAccountID = item.sourceAccountID {
                contextItem = contextItem.taggingSource(sourceAccountID)
            }
            guard let seriesID = contextItem.seriesID else {
                throw AppError.notFound
            }
            var series = try await provider.item(id: seriesID)
            guard !Task.isCancelled else { return }
            if series.sourceAccountID == nil,
               let sourceAccountID = item.sourceAccountID {
                series = series.taggingSource(sourceAccountID)
            }
            resolvedContextItem = contextItem
            resolvedSeries = series
            resolutionError = nil
        } catch {
            guard !Task.isCancelled else { return }
            resolutionError = (error as? AppError).map { Text($0.userMessage) }
                ?? Text(verbatim: error.localizedDescription)
        }
    }
}

private struct PlozziOSCanonicalItemDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.themePalette) private var palette
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel
    /// Pushes another title from the Related row. Read here rather than only in a
    /// subview because a `navigationDestination` is hosted by the stack, so it
    /// inherits the STACK's environment — the router has to be read where the page
    /// itself is declared.
    @Environment(\.mediaItemNavigator) private var itemNavigator
    @State private var viewModel: ItemDetailViewModel
    @State private var playbackRequest: PlozziOSPlaybackRequest?
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?
    @State private var requestError: LocalizedStringResource?
    @State private var isRequesting = false
    @State private var requestConfirmationItem: MediaItem?
    @State private var requestConfirmationSeasons: [Int]?
    @State private var requestConfirmationContext: String?
    @State private var seasonRequestState = SeasonRequestState()
    @State private var seasonRequestScope: String?
    @State private var seasonRequestRefreshID = UUID()
    @State private var seasonRequestRefreshFailed = false
    @State private var isRefreshingSeasonRequests = false
    @State private var seasonRequestRetryToken = 0
    @State private var requestStatusOverride: MediaAvailabilityStatus?
    @State private var sourceOverride: String?
    @State private var versionOverride: String?
    @State private var seriesPlayTarget: MediaItem?
    @State private var hasResolvedSeriesPlayTarget = false
    @State private var presentsSeriesDownloads = false
    /// Whether the hero describes the **show** rather than `seriesPlayTarget`.
    ///
    /// True when there is no resume point to offer — nothing watched, or all of it
    /// watched and the pointer stale. Play still starts an episode in both cases,
    /// so the two cannot be the same value: the hero is editorial (the show), the
    /// play target is technical (the file that will run).
    @State private var seriesHeroShowsSeries = false
    @State private var heroPullDistance: CGFloat = 0
    private let seerService: SeerService?
    private var isDiscoveryItem: Bool { viewModel.isDiscoveryItem }
    private let initialSources: [MediaSourceRef]
    private let initialSeasonID: String?
    private let initialEpisode: MediaItem?
    /// Whether the episode is this page's own subject rather than a season/series
    /// page's fronted child — see `showsEpisodeSubjectHero`.
    private let presentsEpisodeAsSubject: Bool
    private let capabilities = MediaCapabilities.detected()

    init(
        appModel: PlozziOSAppModel,
        provider: any MediaProvider,
        item: MediaItem,
        continueWatching: [MediaItem] = [],
        seerService: SeerService? = nil,
        originSourceAccountID: String? = nil,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil,
        presentsEpisodeAsSubject: Bool = false
    ) {
        self.seerService = seerService
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        self.presentsEpisodeAsSubject = presentsEpisodeAsSubject
        let identitySources = appModel.identityIndex.identitySourcesProvider
        let isDiscoveryItem = DetailOpenEnvironment.isDiscovery(
            item,
            identitySources: identitySources
        )
        let discoveryStatusRefresh:
            (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)?
        if isDiscoveryItem {
            discoveryStatusRefresh = { [seerService] item in
                await seerService?.availability(for: item)
            }
        } else {
            discoveryStatusRefresh = nil
        }
        let selection = DetailOpenEnvironment.initialSourceSelection(
            for: item,
            isDiscovery: isDiscoveryItem,
            libraryOrigin: originSourceAccountID,
            identitySources: appModel.identityIndex.identitySourcesProvider,
            sourceLocality: {
                appModel.accountsProviders.provider(forAccountID: $0)?.connectionLocality
            }
        )
        let initialSources = selection.sources
        let selectedSource = selection.selected
        let selectedItem = DetailOpenEnvironment.initialItem(for: item, selectedSource: selectedSource)
        let resume = DetailPlaybackSelection.resumeItem(for: selectedItem, in: continueWatching)
        _seriesPlayTarget = State(initialValue:
            SeriesEpisodeEntry.openingSeed(
                for: selectedItem, initialEpisode: initialEpisode,
                initialSeasonID: initialSeasonID, resumeEpisode: resume
            )
        )
        let selectedProvider = selectedSource.flatMap {
            appModel.accountsProviders.provider(forAccountID: $0.accountID)
        } ?? provider
        self.initialSources = initialSources
        let accounts = appModel.accountsProviders.homeAccounts
        _viewModel = State(
            initialValue: ItemDetailViewModel(
                provider: selectedProvider,
                itemID: selectedSource?.itemID ?? item.id,
                initialItem: DetailPlaybackSelection.applyingResumeItem(resume, to: selectedItem),
                initialResumeEpisode: selectedItem.kind == .series ? resume : nil,
                isDiscoveryItem: isDiscoveryItem,
                discoveryStatusRefresh: discoveryStatusRefresh,
                loadSeasonEpisodeRoster: { [seer = appModel.seerService] item, number in
                    await seer.seasonEpisodeRoster(for: item, seasonNumber: number)
                },
                ratingsProvider: RatingsServiceFactory.make(),
                sourceAccountID: selectedSource?.accountID ?? item.sourceAccountID,
                originSourceAccountID: originSourceAccountID,
                initialSources: initialSources,
                alternateProviderResolver: { accountID in
                    appModel.accountsProviders.provider(forAccountID: accountID)
                },
                crossServerSourceResolver: crossServerSourceResolver(
                    in: accounts,
                    identitySources: identitySources
                ),
                relatedTitlesLoader:
                    relatedTitleLibrarySearch(in: accounts).map { search in
                        RelatedTitlesLoader(
                            resolver: .production(traktClientID: TraktConfig.resolved().clientID),
                            search: search,
                            indexedLibrarySources: identitySources,
                            displayMode: DetailOpenEnvironment.relatedTitlesDisplayMode(
                                isDiscoveryItem: isDiscoveryItem
                            )
                        )
                    }
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading details…")
            case .empty:
                ContentUnavailableView(
                    "Details unavailable",
                    systemImage: "film.stack"
                )
            case let .loaded(detail):
                detailContent(detail)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load details", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.reload() }
                    }
                }

            }
        }
        .background(palette.backgroundBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if trailerController.isPlaying,
                   trailerController.activeSurfaceRole == .detail,
                   trailerController.currentItemID == viewModel.state.value?.item.id {
                    PlozziOSTrailerMuteToolbarButton(
                        isMuted: trailerController.isMuted,
                        onToggle: trailerController.toggleMuted
                    )
                }

                if let detail = viewModel.state.value,
                   seriesDownloadPresentation(for: detail).isVisible {
                    Button {
                        presentsSeriesDownloads = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Manage Seasons")
                }
            }
        }
        .sheet(isPresented: $presentsSeriesDownloads) {
            if let detail = viewModel.state.value {
                PlozziOSSeriesDownloadPicker(
                    series: detail.item,
                    seasons: detail.children.filter { $0.kind == .season },
                    looseEpisodes: detail.children.filter { $0.kind == .episode },
                    viewModel: viewModel,
                    presentation: seriesDownloadPresentation(for: detail),
                    seasonRequestAvailability: currentSeasonRequestAvailability(for: detail),
                    isRequestingSeasons: isRequesting,
                    isRefreshingSeasons: seasonRequestScope == seasonRequestScopeKey(for: detail)
                        && isRefreshingSeasonRequests,
                    seasonRequestRefreshFailed: currentSeasonRequestRefreshFailed(for: detail),
                    requestActingName: appModel.activeSeerrRequestActingName,
                    onRefreshSeasonRequests: { seasonRequestRetryToken &+= 1 },
                    onRequestSeasons: { beginRequest(detail.item, seasons: $0) },
                    onDownloadBatch: downloadBatch,
                    onDownloadSeason: downloadSeason,
                    onDownloadEpisode: downloadEpisode
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .modifier(requestPresentation(inDownloadSheet: true))
            }
        }
        .onChange(of: presentsSeriesDownloads) { _, isPresented in
            if isPresented { seasonRequestRetryToken &+= 1 }
        }
        .task { await viewModel.load() }
        .onChange(of: viewModel.serverResumeEpisode) { _, resume in
            guard seriesPlayTarget == nil,
                  let series = viewModel.state.value?.item,
                  let seed = SeriesEpisodeEntry.openingSeed(
                      for: series, initialEpisode: initialEpisode,
                      initialSeasonID: initialSeasonID, resumeEpisode: resume
                  ) else { return }
            seriesPlayTarget = seed
            seriesHeroShowsSeries = false
        }
        .modifier(requestPresentation(inDownloadSheet: false))
        .fullScreenCover(item: $playbackRequest) {
            if let playbackProvider = appModel.provider(for: $0.item) {
                PlozziOSPlayerView(request: $0, provider: playbackProvider)
            } else {
                ContentUnavailableView(
                    "Server unavailable",
                    systemImage: "server.rack",
                    description: Text("Reconnect the selected server and try again.")
                )
            }
        }
    }

    private func detailContent(_ detail: ItemDetailViewModel.Detail) -> some View {
        let heroTarget = seriesHeroShowsSeries
            ? detail.item
            : (seriesPlayTarget ?? detail.item)
        let playableHeroTarget = seriesPlayTarget.map(playbackItem(for:))
            ?? detailPlayableItem(for: detail.item)
        let seasons = detail.children.filter { $0.kind == .season }
        let openingSeasonID = SeriesResume.openingSeasonID(
            seasons: seasons, episodes: [],
            selectedSeasonID: nil, preserveSelection: false,
            initialSeasonID: initialSeasonID, initialEpisode: initialEpisode,
            resumeEpisode: viewModel.serverResumeEpisode
        )
        let showsPlayPlaceholder = !isDiscoveryItem && !hasResolvedSeriesPlayTarget
            && DetailPlaybackSelection.showsPlayPlaceholder(
                for: detail.item, hasPlayTarget: playableHeroTarget != nil,
                childrenLoaded: detail.childrenLoaded,
                seasonLoadState: openingSeasonID.map { viewModel.seasonLoadState(for: $0) }
            )
        let options = isDiscoveryItem
            ? DetailPlaybackOptions(
                sources: [],
                selectedSourceAccountID: nil,
                versions: [],
                selectedVersionID: nil
            )
            : detailPlaybackOptions(for: heroTarget)
        let heroStyle: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let headerPresentation = HeroPresentation(item: heroTarget, artworkStyle: heroStyle, surface: .detail)
        let rootPresentation = HeroPresentation(item: detail.item, artworkStyle: heroStyle, surface: .detail)
        let trailerPauseThreshold = PlozziOSHeroMetrics.height(
            style: heroStyle,
            surfaceRole: .detail,
            dynamicTypeSize: dynamicTypeSize
        ) / 2
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlozziOSDetailHeroSection(
                    item: heroTarget,
                    backdropItem: detail.item,
                    playableItem: playableHeroTarget,
                    showsPlayPlaceholder: showsPlayPlaceholder,
                    downloadItem: playableHeroTarget,
                    sources: options.sources,
                    scheduleLine: isDiscoveryItem
                        ? (
                            detail.item.kind == .series
                                ? upcomingHeroLine
                                : detail.externalAvailability?.primaryLine()
                        )
                        : upcomingHeroLine,
                    selectedSourceAccountID: options.selectedSourceAccountID,
                    versions: options.versions,
                    selectedVersionID: options.selectedVersionID,
                    onSelectSource: selectSource,
                    onSelectVersion: {
                        selectVersion($0, for: heroTarget)
                    },
                    actionHandler: appModel.mediaItemActionHandler,
                    // Re-resolve the play target at FIRE time rather than using
                    // the one captured when the body was evaluated. A tap that
                    // races a discovery/snapshot update would otherwise fire the
                    // stale capture: the picker has already moved on to a richer
                    // version set, so it highlights 4K while the play target
                    // still points at the originally-opened 720p. Reading the
                    // live state here guarantees playback derives from the same
                    // source of truth the UI most recently showed. (tvOS's
                    // ItemDetailView does this and documents it as CRITICAL.)
                    onPlay: { _, fromBeginning in
                        let liveTarget = seriesPlayTarget ?? detail.item
                        play(playbackItem(for: liveTarget), fromBeginning: fromBeginning)
                    },
                    trailerItem: viewModel.trailers.first,
                    onPlayTrailer: { play($0, fromBeginning: true) },
                    heroRequest: heroRequest(for: detail.item),
                    // An episode's own page can be reached from Continue Watching
                    // or Search, where Back leaves the show entirely — so offer a
                    // way over to it.
                    offersParentNavigation: showsEpisodeSubjectHero(detail.item),
                    presentsEpisodeStill: showsEpisodeSubjectHero(detail.item),
                    pullDistance: heroPullDistance
                )

                if detail.item.kind == .series, !isDiscoveryItem {
                    PlozziOSInlineSeriesBrowser(
                        viewModel: viewModel,
                        seasons: detail.children.filter { $0.kind == .season },
                        looseEpisodes: detail.children.filter { $0.kind == .episode },
                        initialSeasonID: initialSeasonID,
                        initialEpisode: initialEpisode,
                        onPlayTargetChange: {
                            seriesPlayTarget = $0
                            hasResolvedSeriesPlayTarget = true
                        },
                        onHeroShowsSeriesChange: { seriesHeroShowsSeries = $0 },
                        onPlay: play
                    )
                }

                if isDiscoveryItem, detail.item.kind != .movie, detail.item.kind != .series {
                    PlozziOSRequestAction(
                        item: detail.item,
                        availability: requestStatusOverride ?? detail.item.availability ?? .unknown,
                        isRequesting: isRequesting,
                        errorMessage: requestError,
                        actingName: appModel.activeSeerrRequestActingName,
                        onRequest: { beginRequest($0) }
                    )
                    .padding(.horizontal, pageInset)
                }

                // Above the cast, matching tvOS: what else to watch is the decision
                // being made now; who was in it is looked up afterwards.
                PlozziOSExtrasSection(
                    state: viewModel.extrasState,
                    inset: pageInset,
                    onSelect: { play($0.playbackItem) },
                    onRetry: {
                        Task { await viewModel.retryExtras() }
                    }
                )

                if let entries = viewModel.relatedTitlesLoader?.entries, !entries.isEmpty {
                    PlozziOSRelatedSection(
                        entries: entries,
                        inset: pageInset,
                        onSelect: { itemNavigator?($0) }
                    )
                }

                if !detail.item.people.filter(\.isCast).isEmpty {
                    PlozziOSCastSection(
                        people: detail.item.people.filter(\.isCast),
                        sourceAccountID: detail.item.sourceAccountID
                    )
                }

                DetailInformationSections(
                    item: detail.item,
                    horizontalInset: pageInset,
                    selectedSource: options.sources.first {
                        $0.accountID == options.selectedSourceAccountID
                    } ?? (isDiscoveryItem ? nil : viewModel.currentSourceForDisplay),
                    selectedVersion: isDiscoveryItem
                        ? nil
                        : options.versions.first {
                            $0.id == options.selectedVersionID
                        } ?? MediaVersion.synthesized(from: heroTarget),
                    externalAvailability: detail.externalAvailability,
                    spoilerSettings: appModel.settings.spoilers.settings,
                    overviewAlreadyShown: heroStyle == .compactPortrait
                        ? HeroContentPolicy.detailDescription(focused: headerPresentation, root: rootPresentation)
                        : nil
                )
            }
            // No trailing padding here. The information band is the last thing in
            // this stack and paints its own tint, so a gap added out here is page
            // background sitting under the band: the tint stopped short of the
            // bottom of the page. The band carries the trailing space itself.
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        .scrollClipDisabled()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > trailerPauseThreshold
        } action: { _, isPastHalfHero in
            trailerController.setPaused(isPastHalfHero)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let topOffset = geometry.contentOffset.y
                + geometry.contentInsets.top
            return max(0, -topOffset)
        } action: { _, pullDistance in
            heroPullDistance = pullDistance
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(Text(verbatim: ""))
        .task(id: seasonRequestRefreshKey(for: detail)) {
            await refreshVisibleSeasonRequests(for: detail)
        }
        .task(id: isDiscoveryItem) {
            await pollDiscoveryStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            guard let mutation = MediaItemMutation.from(note) else { return }
            viewModel.applyWatchedState(mutation)
        }
    }

    /// Polls a discovery title's live Seerr status while the detail page is open
    /// so a request made here (or elsewhere) reflects in the hero CTA
    /// (Request → Requested → Downloading % → Play) — mirroring the Home hero.
    /// Fast while a request is still spinning up, relaxed once downloading/idle.
    private func pollDiscoveryStatus() async {
        guard isDiscoveryItem else { return }
        while !Task.isCancelled {
            await viewModel.refreshDiscoveryStatusNow()
            if Task.isCancelled { return }
            let item = viewModel.state.value?.item
            let transitional: Bool
            switch item?.availability {
            case .pending: transitional = true
            case .processing: transitional = item?.downloadProgress == nil
            default: transitional = requestStatusOverride != nil
            }
            try? await Task.sleep(for: transitional ? .seconds(4) : .seconds(20))
        }
    }

    /// The hero's air-schedule line ("New episode every Wednesday"), or `nil`.
    private var upcomingHeroLine: LocalizedStringResource? {
        guard let schedule = viewModel.state.value?.upcomingSchedule else { return nil }
        return SeriesUpcoming.heroLine(
            nextEpisode: schedule.upcomingEpisode,
            cadence: schedule.cadence,
            schedule: schedule.upcomingEpisodes
        )
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }

    /// Whether this page's subject is an episode in its own right, rather than a
    /// season/series page fronting one. iOS carries an explicit flag for this
    /// (set only by the menu's "Episode Info" route), unlike tvOS which infers
    /// it — here `initialEpisode` is set in *both* cases and can't separate them.
    private func showsEpisodeSubjectHero(_ item: MediaItem) -> Bool {
        presentsEpisodeAsSubject && item.kind == .episode
    }

    /// Series requests live in the download sheet; movie requests stay in the hero.
    private func heroRequest(for item: MediaItem) -> PlozziOSHeroRequest? {
        guard isDiscoveryItem, item.kind == .movie else { return nil }
        let availability = requestStatusOverride ?? item.availability
        return PlozziOSHeroRequest(
            cta: MediaItem.heroCTA(
                availability: availability,
                downloadProgress: item.downloadProgress,
                hasValidatedPlayableSource:
                    item.hasPlayableLibraryTarget(
                        additionalSources: availableSources
                    ),
                seerConnected: appModel.seerService.isConfigured
            ),
            isRequesting: isRequesting,
            actingName: appModel.activeSeerrRequestActingName,
            onRequest: { beginRequest($0) }
        )
    }

    private func seriesDownloadPresentation(
        for detail: ItemDetailViewModel.Detail
    ) -> SeriesDownloadPresentation {
        SeriesDownloadPresentation(
            item: detail.item,
            children: detail.children,
            isDiscoveryItem: isDiscoveryItem,
            seerConnected: seerService?.isConfigured == true
        )
    }

    private func requestPresentation(inDownloadSheet: Bool) -> PlozziOSRequestPresentation {
        PlozziOSRequestPresentation(
            presentsDownloads: $presentsSeriesDownloads,
            isSheet: inDownloadSheet,
            error: $requestError,
            confirmationItem: $requestConfirmationItem,
            confirmationSeasons: $requestConfirmationSeasons,
            confirmationContext: $requestConfirmationContext,
            onConfirm: { item, seasons, context in
                Task { await request(item, seasons: seasons, context: context) }
            }
        )
    }

    private struct DetailPlaybackOptions {
        let sources: [MediaSourceRef]
        let selectedSourceAccountID: String?
        let versions: [MediaVersion]
        let selectedVersionID: String?
    }

    private func detailPlaybackOptions(
        for item: MediaItem
    ) -> DetailPlaybackOptions {
        let available = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: available,
            capabilities: capabilities
        )
        let sources = DetailPlaybackSelection.serverChoices(from: available)
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: available,
            activeAccountID: source?.accountID
        )
        let selectedVersionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        return DetailPlaybackOptions(
            sources: sources,
            selectedSourceAccountID: source?.accountID
                ?? item.sourceAccountID,
            versions: versions,
            selectedVersionID: selectedVersionID
        )
    }

    private func detailPlayableItem(for item: MediaItem) -> MediaItem? {
        guard !isDiscoveryItem,
              item.kind == .movie
                || item.kind == .episode
                || item.kind == .video else {
            return nil
        }
        return playbackItem(for: item)
    }

    private func downloadSeason(
        _ season: MediaItem,
        episodes: [MediaItem],
        batchID: String?,
        batchKind: DownloadBatchKind,
        batchTitle: String,
        batchExpectedCount: Int,
        quality: DownloadQuality?
    ) async throws -> Int {
        let playableEpisodes = episodes
        guard let first = playableEpisodes.first,
              let provider = appModel.provider(for: first)
                ?? appModel.provider(for: season) else {
            throw PlozziOSSeasonDownloadError.serverUnavailable
        }
        let records = try await appModel.downloads.enqueueSeason(
            season: season,
            episodes: playableEpisodes,
            provider: provider,
            batchID: batchID,
            batchKind: batchKind,
            batchTitle: batchTitle,
            batchExpectedCount: batchExpectedCount,
            quality: quality
        )
        return records.count
    }

    private func downloadBatch(
        _ batches: [PlozziOSSeasonDownloadPrompt.Batch],
        batchID: String,
        batchKind: DownloadBatchKind,
        batchTitle: String,
        batchExpectedCount: Int,
        quality: DownloadQuality?
    ) async throws -> Int {
        let groups = try batches.map { batch in
            guard let first = batch.episodes.first,
                  let provider = appModel.provider(for: first)
                    ?? appModel.provider(for: batch.season) else {
                throw PlozziOSSeasonDownloadError.serverUnavailable
            }
            return PlozziOSDownloadsModel.BatchGroup(
                season: batch.season,
                episodes: batch.episodes,
                provider: provider
            )
        }
        let records = try await appModel.downloads.enqueueBatch(
            groups: groups,
            batchID: batchID,
            batchKind: batchKind,
            batchTitle: batchTitle,
            batchExpectedCount: batchExpectedCount,
            quality: quality
        )
        return records.count
    }

    private func downloadEpisode(
        _ episode: MediaItem,
        quality: DownloadQuality? = nil
    ) async throws {
        guard let provider = appModel.provider(for: episode) else {
            throw PlozziOSSeasonDownloadError.serverUnavailable
        }
        _ = try await appModel.downloads.enqueue(
            item: episode,
            provider: provider,
            quality: quality
        )
    }

    @ViewBuilder
    private func sourceAndVersionControls(for item: MediaItem) -> some View {
        let sources = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: sources,
            capabilities: capabilities
        )
        let choices = DetailPlaybackSelection.serverChoices(from: sources)
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID
        )
        let versionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        if choices.count > 1 || versions.count > 1 {
            PlozziOSSourceVersionControls(
                sources: choices,
                selectedSourceID: source?.accountID ?? item.sourceAccountID,
                versions: versions,
                selectedVersionID: versionID,
                onSelectSource: selectSource,
                onSelectVersion: { selectVersion($0, for: item) }
            )
        }
    }

    private struct PlozziOSDetailManagementActions: View {
        let item: MediaItem
        let handler: any MediaItemActionHandling

        private var actions: [MediaItemAction] {
            handler.actions(for: item, context: .none)
                .filter { !$0.isNavigation }
        }

        var body: some View {
            if !actions.isEmpty {
                Menu {
                    ForEach(actions) { action in
                        Button(action.title, systemImage: action.systemImage) {
                            handler.perform(action, on: item, context: .none)
                        }
                    }
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func play(_ item: MediaItem, fromBeginning: Bool = false) {
        trailerController.stop()
        // A series can't be played directly (see `playbackTarget`), so resolve
        // its next-up episode first. Every other kind plays as-is.
        guard item.kind == .series else {
            playbackRequest = PlozziOSPlaybackRequest(
                item: item,
                startPosition: fromBeginning ? 0 : (item.resumePosition ?? 0),
                versionPreferences: appModel.versionPreferences
            )
            return
        }
        guard let provider = appModel.provider(for: item) else { return }
        Task { @MainActor in
            guard let episode = await HeroPlayTargetResolver.playbackTarget(
                for: item,
                provider: provider
            ) else { return }
            playbackRequest = PlozziOSPlaybackRequest(
                item: episode,
                startPosition: fromBeginning ? 0 : (episode.resumePosition ?? 0),
                versionPreferences: appModel.versionPreferences
            )
        }
    }

    private var availableSources: [MediaSourceRef] {
        viewModel.sources.isEmpty ? initialSources : viewModel.sources
    }

    private func playbackItem(for item: MediaItem) -> MediaItem {
        let sources = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: sources,
            capabilities: capabilities
        )
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID
        )
        let versionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        let selected = DetailPlaybackSelection.playItem(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID,
            versionID: versionID,
            explicit: viewModel.isLibraryOriginPinned
                || sourceOverride != nil
                || versionOverride != nil
        )
        return PlaybackSourceSelection.bestPlayItem(
            selected,
            accounts: appModel.accountsProviders.resolvedActiveAccounts,
            identitySources: appModel.identityIndex.identitySourcesProvider
        )
    }

    private func downloadLookupID(for item: MediaItem) -> String {
        let playable = playbackItem(for: item)
        return [
            playable.sourceAccountID ?? "_",
            playable.id,
            playable.selectedVersionID ?? "_"
        ].joined(separator: "|")
    }

    private func selectSource(_ accountID: String) {
        sourceOverride = accountID
        versionOverride = nil
        Task { await viewModel.switchToSource(accountID: accountID) }
    }

    private func selectVersion(_ id: String, for item: MediaItem) {
        versionOverride = id
        let key = DetailPlaybackSelection.versionPreferenceKey(for: item)
        guard let version = detailPlaybackOptions(for: item).versions.first(where: { $0.id == id })
        else {
            appModel.versionPreferences.setPreferredVersionID(id, forTitle: key)
            appModel.versionPreferences.setPreferredVersionDescriptor(nil, forTitle: key)
            return
        }
        appModel.versionPreferences.rememberVersion(version, forTitle: key)
    }

    private func beginRequest(_ item: MediaItem, seasons: [Int]? = nil) {
        let context = appModel.plozziOSSeasonRequestContextID
        let selectedSeasons: [Int]?
        if let seasons {
            guard let detail = viewModel.state.value,
                  seasonRequestScope == seasonRequestScopeKey(for: detail),
                  SeasonRequestState.itemKey(for: item) == SeasonRequestState.itemKey(for: detail.item) else {
                seasonRequestRetryToken &+= 1
                return
            }
            let eligible = Set(
                seasonRequestState.availability?.requestableSeasonNumbers ?? []
            )
            let selected = Set(seasons).intersection(eligible).sorted()
            guard !selected.isEmpty else {
                seasonRequestRetryToken &+= 1
                return
            }
            selectedSeasons = selected
        } else {
            selectedSeasons = nil
        }
        if appModel.activeSeerrRequestIdentity == .admin,
           appModel.profiles.profiles.count > 1 {
            requestConfirmationItem = item
            requestConfirmationSeasons = selectedSeasons
            requestConfirmationContext = context
        } else {
            Task { await request(item, seasons: selectedSeasons, context: context) }
        }
    }

    private func request(
        _ item: MediaItem,
        seasons: [Int]? = nil,
        context: String
    ) async {
        guard context == appModel.plozziOSSeasonRequestContextID else {
            requestError = "The request server or profile changed. Review the request and try again."
            return
        }
        guard let seerService else {
            requestError = "Connect Overseerr or Jellyseerr in Settings first."
            return
        }
        isRequesting = true
        requestError = nil
        defer { isRequesting = false }
        let requestScope = seasonRequestScope
        let outcome = await seerService.request(
            item,
            seasons: seasons,
            identity: appModel.activeSeerrRequestIdentity
        )
        guard context == appModel.plozziOSSeasonRequestContextID else { return }
        switch outcome {
        case let .success(status):
            if let seasons {
                guard requestScope == seasonRequestScope else { return }
                seasonRequestState.accept(seasons)
                seasonRequestRetryToken &+= 1
                await refreshSeasonRequestAvailability(for: item)
            } else {
                requestStatusOverride = status
                await viewModel.load()
            }
        case .failure(.alreadyRequested):
            if let seasons {
                guard requestScope == seasonRequestScope else { return }
                let refreshed = await refreshSeasonRequestAvailability(for: item)
                if refreshed { seasonRequestRetryToken &+= 1 }
                let stillRequestable = Set(
                    seasonRequestState.availability?
                        .requestableSeasonNumbers ?? []
                ).isDisjoint(with: seasons) == false
                if !refreshed || stillRequestable {
                    requestError =
                        "This season is already requested. Refresh status to see the latest state."
                }
            } else {
                // Seerr already tracks this title — the seeded availability was
                // stale. Pull the real status so the CTA reflects reality instead of
                // showing a misleading error.
                if let status = await appModel.seerService.availability(for: item) {
                    requestStatusOverride = status.0
                }
                await viewModel.load()
            }
        case let .failure(reason):
            requestError = reason.userMessage
        }
    }

    private func refreshVisibleSeasonRequests(
        for detail: ItemDetailViewModel.Detail
    ) async {
        let scope = seasonRequestScopeKey(for: detail)
        if seasonRequestScope != scope {
            seasonRequestScope = scope
            seasonRequestState.reset()
            seasonRequestRefreshFailed = false
            isRefreshingSeasonRequests = false
            requestConfirmationItem = nil
            requestConfirmationSeasons = nil
            requestConfirmationContext = nil
        }
        guard scope != "disabled", scenePhase == .active else { return }
        repeat {
            await refreshSeasonRequestAvailability(for: detail.item)
            guard !seasonRequestRefreshFailed,
                  seasonRequestState.availability?.seasons
                    .contains(where: \.isInFlight) == true,
                  !Task.isCancelled else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
        } while !Task.isCancelled
    }

    @discardableResult
    private func refreshSeasonRequestAvailability(
        for item: MediaItem
    ) async -> Bool {
        guard let detail = viewModel.state.value,
              detail.item.id == item.id else {
            return false
        }
        let scope = seasonRequestScopeKey(for: detail)
        let refreshID = UUID()
        seasonRequestRefreshID = refreshID
        guard scope != "disabled",
              let seerService,
              seerService.isConfigured else {
            seasonRequestState.reset()
            seasonRequestRefreshFailed = false
            isRefreshingSeasonRequests = false
            return false
        }
        isRefreshingSeasonRequests = true
        defer {
            if seasonRequestRefreshID == refreshID {
                isRefreshingSeasonRequests = false
            }
        }
        let refreshed = await seerService.requestAvailability(for: item)
        guard !Task.isCancelled,
              seasonRequestScope == scope,
              viewModel.state.value.map({ seasonRequestScopeKey(for: $0) }) == scope,
              seasonRequestRefreshID == refreshID,
              viewModel.state.value?.item.id == item.id else {
            return false
        }
        guard let refreshed else {
            seasonRequestRefreshFailed = true
            return false
        }
        let presentSeasonNumbers = detail.children.compactMap {
            ($0.kind == .season || $0.kind == .episode) && $0.locallyValidatedPlayableSource
                ? $0.seasonNumber
                : nil
        }
        seasonRequestState.apply(
            refreshed,
            presentInLibrary: presentSeasonNumbers
        )
        seasonRequestRefreshFailed = false
        return true
    }

    private func seasonRequestScopeKey(
        for detail: ItemDetailViewModel.Detail
    ) -> String {
        guard seriesDownloadPresentation(for: detail).canRequestSeasons else {
            return "disabled"
        }
        return [
            appModel.plozziOSSeasonRequestContextID,
            detail.item.sourceAccountID ?? "_",
            detail.item.id,
            detail.item.providerIDs["Tmdb"] ?? "_"
        ].joined(separator: "|")
    }

    private func currentSeasonRequestAvailability(
        for detail: ItemDetailViewModel.Detail
    ) -> MediaRequestAvailability? {
        seasonRequestScope == seasonRequestScopeKey(for: detail)
            ? seasonRequestState.availability
            : nil
    }

    private func currentSeasonRequestRefreshFailed(
        for detail: ItemDetailViewModel.Detail
    ) -> Bool {
        seasonRequestScope == seasonRequestScopeKey(for: detail)
            && seasonRequestRefreshFailed
    }

    private func seasonRequestRefreshKey(
        for detail: ItemDetailViewModel.Detail
    ) -> String {
        let seasons = detail.children.compactMap(\.seasonNumber)
            .map(String.init)
            .joined(separator: ",")
        return [
            seasonRequestScopeKey(for: detail),
            seasons,
            String(seasonRequestRetryToken),
            scenePhase == .active ? "active" : "inactive"
        ].joined(separator: "|")
    }

    private func requestFailureMessage(_ reason: SeerRequestFailure) -> LocalizedStringResource {
        reason.userMessage
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func download(_ item: MediaItem) async {
        do {
            guard let downloadProvider = appModel.provider(for: item) else {
                downloadError = "The selected server is no longer available."
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: item,
                provider: downloadProvider
            )
            downloadError = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func pauseDownload() async {
        guard let downloadRecord else { return }
        await appModel.downloads.pause(downloadRecord)
        self.downloadRecord = appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        }
    }

    private func resumeDownload() async {
        guard let downloadRecord else { return }
        await appModel.downloads.resume(downloadRecord)
        self.downloadRecord = appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        }
    }

    private func removeDownload(_ item: MediaItem) async {
        guard let downloadRecord else { return }
        await appModel.downloads.remove(downloadRecord)
        self.downloadRecord = await appModel.downloads
            .record(forSelectedVersionOf: item)
    }
}

/// Renders a `MediaVersion` title: the joined technical facts (or provider
/// name) verbatim when known, otherwise our own generic "Version" copy —
/// kept as a real resource here rather than baked into a `String` so it
/// translates like everything else.
private func versionTitleText(_ displayLabel: String?) -> Text {
    if let displayLabel {
        return Text(verbatim: displayLabel)
    }
    return Text("Version", comment: "Generic label for a playback version/source with no distinguishing facts (resolution, edition, etc.) known.")
}

private struct PlozziOSSourceVersionControls: View {
    let sources: [MediaSourceRef]
    let selectedSourceID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    @State private var isVersionPickerPresented = false

    var body: some View {
        HStack(spacing: 12) {
            if sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button {
                            onSelectSource(source.accountID)
                        } label: {
                            sourceSelectionLabel(
                                source,
                                selected: source.accountID == selectedSourceID
                            )
                        }
                    }
                } label: {
                    sourceMenuLabel(selectedSource)
                }
                .buttonStyle(.bordered)
            }

            if versions.count > 1, let selectedVersion {
                Button {
                    isVersionPickerPresented = true
                } label: {
                    Label {
                        versionTitleText(selectedVersion.displayLabel)
                    } icon: {
                        Image(systemName: "film.stack")
                    }
                }
                .buttonStyle(.bordered)
                .popover(
                    isPresented: $isVersionPickerPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    PlozziOSVersionPickerPopover(
                        versions: versions.sortedForPicker(),
                        selectedVersionID: selectedVersion.id,
                        onSelectVersion: onSelectVersion
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceID }
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    private func sourceMenuLabel(
        _ source: MediaSourceRef?
    ) -> some View {
        HStack(spacing: 8) {
            if let provider = source?.providerKind {
                ProviderBrandMark(
                    provider: provider,
                    size: 20,
                    showsBackground: false
                )
            }
            source.map { Text(verbatim: $0.displayName) } ?? Text("Server")
        }
    }

    private func sourceSelectionLabel(
        _ source: MediaSourceRef,
        selected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if let provider = source.providerKind {
                ProviderBrandMark(
                    provider: provider,
                    size: 18,
                    showsBackground: false
                )
            }
            Text(source.displayName)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

}

private struct PlozziOSVersionPickerPopover: View {
    let versions: [MediaVersion]
    let selectedVersionID: String
    let onSelectVersion: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(versions) { version in
                    Button {
                        onSelectVersion(version.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "checkmark")
                                .frame(width: 18)
                                .opacity(version.id == selectedVersionID ? 1 : 0)
                                .accessibilityHidden(version.id != selectedVersionID)
                            versionTitleText(version.displayLabel)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        version.id == selectedVersionID ? .isSelected : []
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 440, maxHeight: 440)
    }
}

private struct PlozziOSRequestAction: View {
    let item: MediaItem
    let availability: MediaAvailabilityStatus
    let isRequesting: Bool
    let errorMessage: LocalizedStringResource?
    let actingName: String?
    let onRequest: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch availability {
            case .unknown, .deleted:
                Button {
                    onRequest(item)
                } label: {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Label(
                            item.kind == .series ? "Request Series" : "Request Movie",
                            systemImage: "plus.rectangle.on.folder"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
                if let actingName {
                    Text("Request as \(actingName)")
                        .font(.footnote)
                        .plozzForeground(.secondary)
                }
            case .pending:
                Label("Requested — awaiting approval", systemImage: "clock")
                    .foregroundStyle(.orange)
            case .processing:
                Label("Library Request Processing", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
            case .partiallyAvailable:
                Label("Partially available", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(.green)
            case .available:
                Label("Available in your library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct PlozziOSRequestPresentation: ViewModifier {
    @Binding var presentsDownloads: Bool
    let isSheet: Bool
    @Binding var error: LocalizedStringResource?
    @Binding var confirmationItem: MediaItem?
    @Binding var confirmationSeasons: [Int]?
    @Binding var confirmationContext: String?
    let onConfirm: (MediaItem, [Int]?, String) -> Void

    private var isEnabled: Bool { presentsDownloads == isSheet }

    func body(content: Content) -> some View {
        content
            .alert(
                Text(verbatim: "Seerr"),
                isPresented: Binding(
                    get: { isEnabled && error != nil },
                    set: { if isEnabled && !$0 { error = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                error.map { Text($0) } ?? Text(verbatim: "")
            }
            .confirmationDialog(
                "Request as Administrator?",
                isPresented: Binding(
                    get: { isEnabled && confirmationItem != nil },
                    set: { if isEnabled && !$0 { clearConfirmation() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Request as Administrator") {
                    guard let item = confirmationItem,
                          let context = confirmationContext else { return }
                    let seasons = confirmationSeasons
                    clearConfirmation()
                    onConfirm(item, seasons, context)
                }
                Button("Cancel", role: .cancel, action: clearConfirmation)
            } message: {
                Text(
                    """
                    This profile isn’t linked to a Seerr user. \
                    The request will use the unrestricted administrator account.
                    """
                )
            }
    }

    private func clearConfirmation() {
        confirmationItem = nil
        confirmationSeasons = nil
        confirmationContext = nil
    }
}

private struct PlozziOSDownloadAction: View {
    let item: MediaItem
    let record: DownloadedMediaRecord?
    let errorMessage: String?
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let record {
                    statusControl(record)
                } else {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func statusControl(_ record: DownloadedMediaRecord) -> some View {
        switch record.status {
        case .queued:
            Label("Queued", systemImage: "clock")
            Button("Cancel", role: .destructive, action: onRemove)
        case .preparing:
            Label("Preparing on server", systemImage: "gearshape.2")
            Button("Pause", action: onPause)
        case .downloading:
            ProgressView(value: record.fractionCompleted ?? 0)
                .frame(maxWidth: 240)
            Button("Pause", action: onPause)
        case .paused:
            Button("Resume Download", action: onResume)
            Button("Remove", role: .destructive, action: onRemove)
        case .failed:
            Button("Try Download Again", action: onResume)
            Button("Remove", role: .destructive, action: onRemove)
        case .completed:
            Label("Available Offline", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Remove Download", role: .destructive, action: onRemove)
        }
    }
}

private struct PlozziOSInlineSeriesBrowser: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSeasonID: String?
    @State private var railTargetID: String?
    /// The season the resting target was settled from, so browsing elsewhere
    /// leaves the hero where the viewer actually is.
    @State private var resolvedSeasonID: String?
    @State private var hasInteractedWithEpisodeBrowser = false

    let viewModel: ItemDetailViewModel
    let seasons: [MediaItem]
    let looseEpisodes: [MediaItem]
    let initialEpisode: MediaItem?
    let initialSeasonID: String?
    let onPlayTargetChange: (MediaItem?) -> Void
    /// Whether the hero should describe the show rather than the play target.
    let onHeroShowsSeriesChange: (Bool) -> Void
    let onPlay: (MediaItem, Bool) -> Void

    init(
        viewModel: ItemDetailViewModel,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        initialSeasonID: String?,
        initialEpisode: MediaItem?,
        onPlayTargetChange: @escaping (MediaItem?) -> Void,
        onHeroShowsSeriesChange: @escaping (Bool) -> Void,
        onPlay: @escaping (MediaItem, Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.seasons = seasons
        self.looseEpisodes = looseEpisodes
        self.initialEpisode = initialEpisode
        self.initialSeasonID = initialSeasonID
        self.onPlayTargetChange = onPlayTargetChange
        self.onHeroShowsSeriesChange = onHeroShowsSeriesChange
        self.onPlay = onPlay
        _selectedSeasonID = State(
            initialValue: SeriesEpisodeEntry.seasonID(
                initialEpisode: initialEpisode,
                initialSeasonID: initialSeasonID,
                seasons: seasons
            )
        )
        _railTargetID = State(initialValue: initialEpisode?.id)
    }

    var body: some View {
        if !seasons.isEmpty || !looseEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if !seasons.isEmpty {
                    HStack(spacing: 10) {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 10) {
                                    ForEach(seasons) { season in
                                        PlozziOSSeasonButton(
                                            title: season.title,
                                            isSelected:
                                                season.id == selectedSeasonID
                                        ) {
                                            hasInteractedWithEpisodeBrowser = true
                                            selectedSeasonID = season.id
                                        }
                                        .id(season.id)
                                    }
                                }
                            }
                            .contentMargins(
                                .leading,
                                pageInset,
                                for: .scrollContent
                            )
                            .contentMargins(
                                .trailing,
                                4,
                                for: .scrollContent
                            )
                            .scrollIndicators(.hidden)
                            .onChange(
                                of: selectedSeasonID,
                                initial: true
                            ) { _, selectedSeasonID in
                                guard let selectedSeasonID else { return }
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(
                                        selectedSeasonID,
                                        anchor: .center
                                    )
                                }
                            }
                        }
                    }
                    .padding(.trailing, pageInset)
                }

                PlozziOSInlineEpisodeRail(
                    episodes: displayedEpisodes,
                    isLoading: !seasons.isEmpty
                        && selectedSeasonID != nil
                        && displayedEpisodes == nil,
                    currentEpisodeID: railTargetID,
                    onInteraction: { hasInteractedWithEpisodeBrowser = true },
                    onPlay: onPlay
                )
            }
            .onChange(of: openingSelectionKey, initial: true) { _, _ in
                let ids = seasons.map(\.id)
                selectedSeasonID = SeriesResume.openingSeasonID(
                    seasons: seasons,
                    episodes: looseEpisodes,
                    selectedSeasonID: selectedSeasonID,
                    preserveSelection: hasInteractedWithEpisodeBrowser,
                    initialSeasonID: initialSeasonID,
                    initialEpisode: initialEpisode,
                    resumeEpisode: viewModel.serverResumeEpisode
                )
                // A different set of season ids means a different server backing
                // this show, so the resume point has to be resolved again against
                // the new source. Leaving the pin in place left the Play button
                // stuck on the previous server's target — or missing entirely,
                // since none of those episode ids exist here.
                if !ids.contains(resolvedSeasonID ?? "") {
                    resolvedSeasonID = nil
                    railTargetID = nil
                }
                if !hasInteractedWithEpisodeBrowser,
                   let series = viewModel.state.value?.item,
                   let seed = SeriesEpisodeEntry.openingSeed(
                       for: series, initialEpisode: initialEpisode,
                       initialSeasonID: initialSeasonID, resumeEpisode: viewModel.serverResumeEpisode
                   ) {
                    resolvedSeasonID = nil
                    onPlayTargetChange(seed)
                    onHeroShowsSeriesChange(false)
                }
            }
            .task(id: selectedSeasonID) {
                if let selectedSeasonID {
                    await viewModel.loadEpisodes(for: selectedSeasonID)
                }
                publishPlayTarget()
            }
            .onChange(of: displayedEpisodes, initial: true) {
                publishPlayTarget()
            }
        }
    }

    private var openingSelectionKey: String {
        let resume = viewModel.serverResumeEpisode
        return "\(seasons.map(\.id).joined(separator: ","))#\(resume?.id ?? "")#\(resume?.resumePosition ?? 0)"
    }

    private var displayedEpisodes: [MediaItem]? {
        guard let owned = ownedEpisodes else { return nil }
        return owned + upcomingPlaceholders(after: owned)
    }

    private var ownedEpisodes: [MediaItem]? {
        if seasons.isEmpty {
            return looseEpisodes
        }
        guard let selectedSeasonID else { return nil }
        return viewModel.episodes(for: selectedSeasonID)
    }

    /// The selected season's unreleased episodes, appended after the owned ones as
    /// non-playable entries — the same treatment tvOS gives them, so a show mid-run
    /// shows what is still to come rather than ending at the last file on disk.
    private func upcomingPlaceholders(after owned: [MediaItem]) -> [MediaItem] {
        guard let schedule = viewModel.state.value?.upcomingSchedule,
              !schedule.upcomingEpisodes.isEmpty else { return [] }
        let seasonNumber = selectedSeasonID
            .flatMap { id in seasons.first { $0.id == id } }?
            .seasonNumber
        guard let series = viewModel.state.value?.item else { return [] }
        return SeriesUpcoming.placeholders(
            for: seasonNumber,
            seriesID: series.id,
            seriesTitle: series.title,
            ownedEpisodes: owned,
            schedule: schedule.upcomingEpisodes,
            seriesArtwork: series
        )
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }

    /// Settles what Play starts, and whether the hero describes that episode or
    /// the show itself.
    ///
    /// Pinned once resolved: browsing to another season must not repoint the hero,
    /// because the resume point has not moved. Apple's TV app shows exactly this —
    /// hero on S1 · E1 while the season selector reads Season 2.
    private func publishPlayTarget() {
        // `displayedEpisodes` is nil only while a season is loading — switching
        // season or server passes through it. Publishing nil there cleared the
        // Play button, and the pin below then prevented it ever coming back, so
        // the button stayed gone until the original season was revisited. Hold
        // the last good target across the gap instead; an *empty* season is a
        // loaded empty array, which still publishes.
        guard let displayedEpisodes else { return }
        // An explicitly opened episode outranks the resume point.
        let openingEpisode = initialEpisode ?? (initialSeasonID == nil ? viewModel.serverResumeEpisode : nil)
        if let loaded = SeriesEpisodeEntry.episode(
            matching: openingEpisode,
            in: displayedEpisodes
        ) {
            resolvedSeasonID = selectedSeasonID
            railTargetID = loaded.id
            onPlayTargetChange(DetailPlaybackSelection.applyingResumeItem(openingEpisode, to: loaded))
            onHeroShowsSeriesChange(false)
            return
        }
        // Already settled from the opening season: a later season change is
        // browsing, not a new resume point.
        if let resolvedSeasonID, resolvedSeasonID != selectedSeasonID { return }
        resolvedSeasonID = selectedSeasonID

        let hasResumePoint = SeriesResume.hasStarted(seasons: seasons, episodes: displayedEpisodes)
            && !SeriesResume.isFinished(seasons: seasons, episodes: displayedEpisodes)
        // Both "never started" and "finished" mean start from the beginning, so
        // Play takes the first episode rather than `nextUp`, which returns the
        // finale once everything is played.
        let target = hasResumePoint
            ? SeriesResume.nextUp(in: displayedEpisodes)
            : displayedEpisodes.first
        railTargetID = target?.id
        onPlayTargetChange(target)
        onHeroShowsSeriesChange(!hasResumePoint)
    }
}

private enum PlozziOSSeasonDownloadError: LocalizedError {
    case serverUnavailable

    var errorDescription: LocalizedStringResource? {
        switch self {
        case .serverUnavailable:
            return "The selected server is no longer available."
        }
    }
}

private struct PlozziOSSeriesDownloadPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var prompt: PlozziOSSeasonDownloadPrompt?

    let series: MediaItem
    let seasons: [MediaItem]
    let looseEpisodes: [MediaItem]
    let viewModel: ItemDetailViewModel
    let presentation: SeriesDownloadPresentation
    let seasonRequestAvailability: MediaRequestAvailability?
    let isRequestingSeasons: Bool
    let isRefreshingSeasons: Bool
    let seasonRequestRefreshFailed: Bool
    let requestActingName: String?
    let onRefreshSeasonRequests: () -> Void
    let onRequestSeasons: ([Int]) -> Void
    let onDownloadBatch: (
        [PlozziOSSeasonDownloadPrompt.Batch],
        String,
        DownloadBatchKind,
        String,
        Int,
        DownloadQuality?
    ) async throws -> Int
    let onDownloadSeason: (
        MediaItem,
        [MediaItem],
        String?,
        DownloadBatchKind,
        String,
        Int,
        DownloadQuality?
    ) async throws -> Int
    let onDownloadEpisode: (MediaItem, DownloadQuality?) async throws -> Void

    private var seasonList: SeriesDownloadSeasons {
        SeriesDownloadSeasons(
            librarySeasons: presentation.hasLibraryDownloads ? seasons : [],
            looseEpisodes: presentation.hasLibraryDownloads ? looseEpisodes : [],
            requestAvailability: presentation.canRequestSeasons ? seasonRequestAvailability : nil
        )
    }

    var body: some View {
        let seasonList = self.seasonList
        let downloadState = presentation.hasLibraryDownloads ? showDownloadState : nil
        let downloadAction = showDownloadAction
        NavigationStack {
            List {
                SeriesDownloadActions(
                    hasDownloads: presentation.hasLibraryDownloads,
                    canRequestSeasons: presentation.canRequestSeasons,
                    availability: seasonList.requestAvailability,
                    isSubmitting: isRequestingSeasons,
                    isRefreshing: isRefreshingSeasons,
                    refreshFailed: seasonRequestRefreshFailed,
                    actingName: requestActingName,
                    onRefresh: onRefreshSeasonRequests,
                    onRequest: onRequestSeasons
                ) {
                    Button(action: beginShowDownload) {
                        SeriesDownloadActionLabel(
                            title: downloadAction.title(for: .current),
                            subtitle: "All available episodes in this show, for offline viewing.",
                            systemImage: downloadAction.systemImage,
                            detail: completedEpisodeCount > 0 && downloadState == nil
                                ? "Downloaded: \(completedEpisodeCount.formatted())"
                                : nil
                        ) {
                            if downloadState != nil || isBusy {
                                PlozziOSDownloadControl(
                                    state: downloadState,
                                    isPreparing: isBusy
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!downloadAction.isEnabled)
                }

                if !presentation.isVisible {
                    ContentUnavailableView(
                        "No Downloads Available",
                        systemImage: "arrow.down.circle",
                        description: Text("Connect Seerr to request missing seasons, or add episodes to your library.")
                    )
                }

                if !seasonList.rows.isEmpty {
                    Section {
                        ForEach(seasonList.rows) { row in
                            seasonRow(row)
                        }
                    } header: {
                        Text(verbatim: series.title)
                            .textCase(nil)
                    }
                }

                if !seasonList.unassignedEpisodes.isEmpty {
                    Section("Episodes") {
                        ForEach(seasonList.unassignedEpisodes, id: \.stablePresentationID) { episode in
                            PlozziOSEpisodeDownloadRow(
                                episode: episode,
                                isBusy: isBusy,
                                onDownload: startEpisodeDownload
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 12, for: .scrollContent)
            .listSectionSpacing(16)
            .navigationTitle("Seasons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isBusy)
                }
                if presentation.canRequestSeasons {
                    ToolbarItem(placement: .topBarTrailing) {
                        SeasonRequestRefreshButton(
                            isRefreshing: isRefreshingSeasons,
                            isSubmitting: isRequestingSeasons,
                            onRefresh: onRefreshSeasonRequests
                        )
                    }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .confirmationDialog(
            downloadConfirmationTitle,
            isPresented: Binding(
                get: { prompt != nil },
                set: {
                    if !$0 {
                        prompt = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let prompt {
                Button("Original • Episodes: \(prompt.count.formatted())") {
                    self.prompt = nil
                    performDownload(prompt, quality: .original)
                }
                if appModel.downloads.supportsReducedQuality(for: series) {
                    Button("1080p • 20 Mbps") {
                        self.prompt = nil
                        performDownload(prompt, quality: .hd1080)
                    }
                    Button("720p • 4 Mbps") {
                        self.prompt = nil
                        performDownload(prompt, quality: .hd720)
                    }
                    Button("480p • 1.5 Mbps") {
                        self.prompt = nil
                        performDownload(prompt, quality: .sd480)
                    }
                    if let custom = appModel.downloads.customDownloadQuality,
                       let title = appModel.downloads.customDownloadQualityTitle {
                        Button(title) {
                            self.prompt = nil
                            performDownload(prompt, quality: custom)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    self.prompt = nil
                }
            }
        } message: {
            if let prompt {
                Text(prompt.message)
                    + Text(" Reduced qualities are transcoded by your media server.")
            }
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private var downloadConfirmationTitle: Text {
        if let prompt {
            return prompt.title
        }
        return Text("Download?")
    }

    private var showDownloadAction: SeriesDownloadAction {
        if isBusy { return .preparing }
        if activeShowBatchID != nil { return .pause }
        if pausedShowBatchID != nil { return .resume }
        return .download
    }

    @ViewBuilder
    private func seasonRow(_ row: SeriesDownloadSeason) -> some View {
        if row.hasLibraryContent {
            NavigationLink {
                seasonDestination(row)
            } label: {
                PlozziOSSeasonDownloadRow(row: row, series: series, viewModel: viewModel)
            }
        } else if row.canRequest, let number = row.number {
            Button {
                onRequestSeasons([number])
            } label: {
                PlozziOSSeasonDownloadRow(row: row, series: series, viewModel: viewModel)
            }
            .buttonStyle(.plain)
            .disabled(isRequestingSeasons)
            .accessibilityLabel(Text("Request \(Text(row.title))"))
        } else {
            PlozziOSSeasonDownloadRow(row: row, series: series, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func seasonDestination(_ row: SeriesDownloadSeason) -> some View {
        if row.librarySeasons.count > 1
            || (!row.librarySeasons.isEmpty && !row.looseEpisodes.isEmpty) {
            List {
                NavigationLink("All Episodes and Versions") {
                    seasonPicker(row)
                }
                ForEach(row.librarySeasons, id: \.stablePresentationID) { librarySeason in
                    NavigationLink {
                        seasonPicker(row, selection: .library(librarySeason.stablePresentationID))
                    } label: {
                        Text(verbatim: librarySeason.title)
                    }
                }
                if !row.looseEpisodes.isEmpty {
                    NavigationLink("Other Episodes") {
                        seasonPicker(row, selection: .loose)
                    }
                }
            }
            .navigationTitle(Text(row.title))
            .navigationBarTitleDisplayMode(.inline)
        } else {
            seasonPicker(row)
        }
    }

    private func seasonPicker(
        _ row: SeriesDownloadSeason,
        selection: PlozziOSSeasonDownloadSelection = .all
    ) -> some View {
        let container: MediaItem
        switch selection {
        case .all: container = row.librarySeasons.first ?? series
        case .loose: container = series
        case .library(let id):
            container = row.librarySeasons.first { $0.stablePresentationID == id } ?? series
        }
        return PlozziOSSeasonDownloadPicker(
            series: series,
            season: row,
            selection: selection,
            viewModel: viewModel,
            isBusy: isBusy,
            canRequestSeasons: presentation.canRequestSeasons,
            requestState: seasonList.rows.first { $0.id == row.id }?.requestState,
            isRequestingSeasons: isRequestingSeasons,
            isRefreshingSeasons: isRefreshingSeasons,
            seasonRequestRefreshFailed: seasonRequestRefreshFailed,
            requestActingName: requestActingName,
            onRefreshSeasonRequests: onRefreshSeasonRequests,
            onRequestSeason: {
                if let number = row.number { onRequestSeasons([number]) }
            },
            onDownloadSeason: {
                beginSeasonDownload(container, title: row.title, episodes: $0)
            },
            onDownloadEpisode: startEpisodeDownload
        )
    }

    private func beginShowDownload() {
        if let batchID = activeShowBatchID {
            Task { await appModel.downloads.pauseBatch(batchID) }
            return
        }
        if let batchID = pausedShowBatchID {
            Task { await appModel.downloads.resumeBatch(batchID) }
            return
        }
        isBusy = true
        Task {
            var batches: [PlozziOSSeasonDownloadPrompt.Batch] = []
            var seen = Set<String>()
            for season in seasons where season.locallyValidatedPlayableSource {
                await viewModel.loadEpisodes(for: season.id)
                guard let episodes = viewModel.seasonLoadState(for: season.id)
                    .authoritativeEpisodes else {
                    errorMessage =
                        "Couldn’t load \(season.title). Check the server and try again."
                    isBusy = false
                    return
                }
                let available = SeasonEpisodeList.downloadableEpisodes(from: episodes, for: series)
                    .filter { seen.insert($0.stablePresentationID).inserted }
                if !available.isEmpty {
                    batches.append(.init(season: season, episodes: available))
                }
            }
            let availableLoose = SeasonEpisodeList.downloadableEpisodes(from: looseEpisodes, for: series)
                .filter { seen.insert($0.stablePresentationID).inserted }
            if !availableLoose.isEmpty {
                batches.append(.init(season: series, episodes: availableLoose))
            }

            isBusy = false
            guard !batches.isEmpty else {
                errorMessage = "This show has no episodes available to download."
                return
            }
            if let episode = batches.first?.episodes.first,
               let provider = appModel.provider(for: episode) {
                await appModel.downloads.refreshReducedQualitySupport(
                    for: episode,
                    provider: provider
                )
            }
            prompt = PlozziOSSeasonDownloadPrompt(
                scope: .show(series.title),
                batches: batches
            )
        }
    }

    private func beginSeasonDownload(
        _ season: MediaItem,
        title: SeriesDownloadSeasonTitle,
        episodes: [MediaItem]
    ) {
        guard !episodes.isEmpty else { return }
        if episodes.count == 1, let episode = episodes.first {
            startEpisodeDownload(
                episode,
                quality: appModel.downloads.downloadQuality
            )
        } else {
            Task {
                if let episode = episodes.first,
                   let provider = appModel.provider(for: episode) {
                    await appModel.downloads.refreshReducedQualitySupport(
                        for: episode,
                        provider: provider
                    )
                }
                prompt = PlozziOSSeasonDownloadPrompt(
                    scope: .season(title),
                    batches: [.init(season: season, episodes: episodes)]
                )
            }
        }
    }

    private func startEpisodeDownload(
        _ episode: MediaItem,
        quality: DownloadQuality
    ) {
        isBusy = true
        Task {
            do {
                try await onDownloadEpisode(episode, quality)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func performDownload(
        _ prompt: PlozziOSSeasonDownloadPrompt,
        quality: DownloadQuality
    ) {
        isBusy = true
        Task {
            let batchID = UUID().uuidString
            let batchKind: DownloadBatchKind
            let batchTitle: String
            switch prompt.scope {
            case .season(let title):
                batchKind = .season
                switch title {
                case .content(let value):
                    batchTitle = value
                case .localized(var resource):
                    resource.locale = locale
                    batchTitle = String(localized: resource) // l10n:content - persisted batch label, resolved only on confirmation
                }
            case .show(let title):
                batchKind = .show
                batchTitle = title
            }
            do {
                _ = try await onDownloadBatch(
                    prompt.batches,
                    batchID,
                    batchKind,
                    batchTitle,
                    prompt.count,
                    quality
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private var showDownloadState: MediaDownloadBadgeState? {
        let librarySeasons = seasons.filter(\.locallyValidatedPlayableSource)
        let episodes: [MediaItem]?
        if librarySeasons.allSatisfy({
            viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes != nil
        }) {
            let candidates = librarySeasons.flatMap {
                viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes ?? []
            } + looseEpisodes
            episodes = SeasonEpisodeList.downloadableEpisodes(from: candidates, for: series)
        } else {
            episodes = nil
        }

        let records = matchingDownloadRecords(
            downloads: appModel.downloads,
            episodes: episodes,
            seriesID: series.id,
            sourceAccountID: series.sourceAccountID,
            seasonNumber: nil
        )
        return downloadCollectionBadgeState(
            records: records,
            expectedCount: episodes?.count,
            scopeKind: .show
        )
    }

    private var completedEpisodeCount: Int {
        appModel.downloads.records.filter {
            $0.snapshot.seriesID == series.id
                && (series.sourceAccountID == nil
                    || $0.snapshot.sourceAccountID == series.sourceAccountID)
                && $0.status == .completed
        }.count
    }

    private var showBatchRecords: [DownloadedMediaRecord] {
        appModel.downloads.records.filter {
            $0.snapshot.seriesID == series.id
                && (series.sourceAccountID == nil
                    || $0.snapshot.sourceAccountID == series.sourceAccountID)
                && $0.batchKind == .show
        }
    }

    private var activeShowBatchID: String? {
        showBatchRecords.first {
            $0.status == .queued
                || $0.status == .preparing
                || $0.status == .downloading
        }?.batchID
    }

    private var pausedShowBatchID: String? {
        guard activeShowBatchID == nil else { return nil }
        return showBatchRecords.first { $0.status == .paused }?.batchID
    }
}

private struct PlozziOSSeasonDownloadRow: View {
    @Environment(PlozziOSAppModel.self) private var appModel

    let row: SeriesDownloadSeason
    let series: MediaItem
    let viewModel: ItemDetailViewModel

    var body: some View {
        let downloadState = self.downloadState
        SeasonDownloadRowContent(
            title: Text(row.title),
            status: row.statusTitle,
            statusSystemImage: row.statusSystemImage,
            showsRequestAction: row.canRequest,
            completedDownloadCount: downloadState == nil ? completedEpisodeCount : 0
        ) {
            if row.hasLibraryContent {
                PlozziOSDownloadThumbnail(
                    item: row.librarySeasons.first ?? series,
                    style: .season
                )
            } else {
                SeasonDownloadRowArtwork(showsMediaEdge: false) {
                    MediaArtworkPlaceholder(glyphSize: 16, symbol: .media)
                }
            }
        } accessory: {
            if let downloadState {
                PlozziOSDownloadControl(state: downloadState)
            }
        }
    }

    private var episodes: [MediaItem]? {
        guard row.librarySeasons.allSatisfy({
            viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes != nil
        }) else { return nil }
        let candidates = row.librarySeasons.flatMap {
            viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes ?? []
        } + row.looseEpisodes
        return SeasonEpisodeList.downloadableEpisodes(from: candidates, for: series)
    }

    private var downloadRecords: [DownloadedMediaRecord] {
        guard row.hasLibraryContent else { return [] }
        guard row.number != nil || episodes != nil else { return [] }
        return matchingDownloadRecords(
            downloads: appModel.downloads,
            episodes: episodes,
            seriesID: row.librarySeasons.first?.seriesID ?? series.id,
            sourceAccountID: row.librarySeasons.first?.sourceAccountID ?? series.sourceAccountID,
            seasonNumber: row.number
        )
    }

    private var downloadState: MediaDownloadBadgeState? {
        downloadCollectionBadgeState(
            records: downloadRecords,
            expectedCount: episodes?.count,
            scopeKind: .season
        )
    }

    private var completedEpisodeCount: Int {
        downloadRecords.filter { $0.status == .completed }.count
    }
}

private enum PlozziOSSeasonDownloadSelection: Equatable {
    case all
    case library(String)
    case loose
}

private enum PlozziOSSeasonEpisodeEntry: Identifiable {
    case roster(SeasonEpisodeRow)
    case unavailable(MediaItem)

    var id: String {
        switch self {
        case .roster(let row): "roster:\(row.id)"
        case .unavailable(let episode): "unavailable:\(episode.stablePresentationID)"
        }
    }

    var episodeNumber: Int? {
        switch self {
        case .roster(let row): row.episodeNumber
        case .unavailable(let episode): episode.episodeNumber
        }
    }
}

private struct PlozziOSSeasonDownloadPicker: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var loadedMetadataContext: String?
    @State private var isRefreshingEpisodes = false

    let series: MediaItem
    let season: SeriesDownloadSeason
    let selection: PlozziOSSeasonDownloadSelection
    let viewModel: ItemDetailViewModel
    let isBusy: Bool
    let canRequestSeasons: Bool
    let requestState: MediaSeasonRequestState?
    let isRequestingSeasons: Bool
    let isRefreshingSeasons: Bool
    let seasonRequestRefreshFailed: Bool
    let requestActingName: String?
    let onRefreshSeasonRequests: () -> Void
    let onRequestSeason: () -> Void
    let onDownloadSeason: ([MediaItem]) -> Void
    let onDownloadEpisode: (MediaItem, DownloadQuality) -> Void

    private var selectedLibrarySeasons: [MediaItem] {
        switch selection {
        case .all: season.librarySeasons
        case .library(let id): season.librarySeasons.filter { $0.stablePresentationID == id }
        case .loose: []
        }
    }

    private var selectionIsAvailable: Bool {
        if case .library = selection { return !selectedLibrarySeasons.isEmpty }
        return true
    }

    private var episodeContainerKey: String {
        let containers = season.librarySeasons.map(\.stablePresentationID).joined(separator: "|")
        return "\(series.stablePresentationID)|\(season.id)|\(containers)|\(needsLooseEpisodeLoad)"
    }

    private var hasLoadedLibrary: Bool {
        season.librarySeasons.allSatisfy {
            viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes != nil
        } && (!needsLooseEpisodeLoad || viewModel.seasonLoadState(for: series.id).authoritativeEpisodes != nil)
    }

    private var needsLooseEpisodeLoad: Bool {
        !season.looseEpisodes.isEmpty || season.librarySeasons.isEmpty
    }

    private var libraryLoadFailed: Bool {
        let containers = season.librarySeasons.map(\.id) + (needsLooseEpisodeLoad ? [series.id] : [])
        return containers.contains {
            if case .failed = viewModel.seasonLoadState(for: $0) { return true }
            return false
        }
    }

    private var libraryEpisodes: [MediaItem] {
        let nested = season.librarySeasons.flatMap {
            viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes ?? []
        }
        let loose = needsLooseEpisodeLoad
            ? (viewModel.seasonLoadState(for: series.id).authoritativeEpisodes ?? []).filter {
                $0.kind == .episode && $0.seasonNumber == season.number
            }
            : []
        return nested + loose
    }

    private var selectedEpisodeIDs: Set<String> {
        let candidates: [MediaItem]
        switch selection {
        case .all:
            candidates = libraryEpisodes
        case .library:
            candidates = selectedLibrarySeasons.flatMap {
                viewModel.seasonLoadState(for: $0.id).authoritativeEpisodes ?? []
            }
        case .loose:
            candidates = (viewModel.seasonLoadState(for: series.id).authoritativeEpisodes ?? [])
                .filter { $0.kind == .episode && $0.seasonNumber == season.number }
        }
        return Set(SeasonEpisodeList.downloadableEpisodes(from: candidates, for: series).map(\.stablePresentationID))
    }

    private var downloadScopeTitle: LocalizedStringResource {
        switch selection {
        case .all:
            season.librarySeasons.count > 1
                || (!season.librarySeasons.isEmpty && !season.looseEpisodes.isEmpty)
                ? "All available episodes and versions in this season, for offline viewing."
                : "All available episodes in this season, for offline viewing."
        case .library: "All available episodes in this version, for offline viewing."
        case .loose: "All available episodes in Other Episodes, for offline viewing."
        }
    }

    private var navigationTitle: Text {
        switch selection {
        case .all: Text(season.title)
        case .loose: Text("Other Episodes")
        case .library:
            selectedLibrarySeasons.first.map { Text(verbatim: $0.title) } ?? Text(season.title)
        }
    }

    private var metadataContext: String {
        "\(appModel.plozziOSSeasonRequestContextID)|\(SeasonRequestState.itemKey(for: series))|\(season.id)"
    }

    private var isCurrentSeries: Bool {
        viewModel.state.value.map {
            SeasonRequestState.itemKey(for: $0.item) == SeasonRequestState.itemKey(for: series)
        } == true
    }

    private var metadataState: SeasonEpisodeRosterLoadState {
        guard let number = season.number else { return .unavailable }
        guard loadedMetadataContext == metadataContext else { return .loading }
        return viewModel.seasonEpisodeRosterState(for: number)
    }

    private var downloadAction: SeriesDownloadAction {
        if isBusy { return .preparing }
        if activeSeasonBatchID != nil { return .pause }
        if pausedSeasonBatchID != nil { return .resume }
        return .download
    }

    var body: some View {
        Group {
            if !selectionIsAvailable {
                ContentUnavailableView(
                    "Season Changed", systemImage: "arrow.clockwise",
                    description: Text("Go back and select a current season version.")
                )
            } else if libraryLoadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Load Episodes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Check the server and try again.")
                } actions: {
                    Button("Try Again") {
                        Task { await loadLibrary(forceRefresh: true) }
                    }
                }
            } else if !hasLoadedLibrary {
                ProgressView("Loading Episodes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let episodes = SeasonEpisodeList(
                    series: series, seasonNumber: season.number,
                    libraryEpisodes: libraryEpisodes, roster: metadataState.roster
                )
                let downloadable = downloadableEpisodes(in: episodes)
                let entries = episodeEntries(in: episodes)
                List {
                    Section {
                        if !downloadable.isEmpty {
                            Button {
                                performSeasonAction(downloadable)
                            } label: {
                                SeriesDownloadActionLabel(
                                    title: downloadAction.title(for: .current),
                                    subtitle: downloadScopeTitle,
                                    systemImage: downloadAction.systemImage
                                ) {
                                    PlozziOSDownloadControl(
                                        state: downloadState(for: downloadable),
                                        isPreparing: isBusy
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!downloadAction.isEnabled || isRefreshingEpisodes)
                        }
                        if canRequestSeasons, (season.number ?? 0) > 0 {
                            SeasonEpisodeRequestControls(
                                state: requestState,
                                hasUnavailableEpisodes: episodes.coverage?.hasUnavailableEpisodes == true,
                                isSubmitting: isRequestingSeasons,
                                isRefreshing: isRefreshingSeasons || isRefreshingEpisodes,
                                refreshFailed: seasonRequestRefreshFailed,
                                actingName: requestActingName,
                                managementURL: appModel.seerService.mediaManagementURL(for: series),
                                onRefresh: onRefreshSeasonRequests,
                                onRequest: onRequestSeason
                            )
                        }
                        if metadataState == .failed {
                            Button {
                                Task { await loadMetadata(forceRefresh: true) }
                            } label: {
                                SeriesDownloadActionLabel(
                                    title: "Retry Episode Information",
                                    subtitle: "Couldn’t load the full episode list. Library downloads are still available.",
                                    systemImage: "arrow.clockwise"
                                ) {}
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        SeasonEpisodeCoverageHeader(
                            coverage: episodes.coverage,
                            isLoading: metadataState == .loading || metadataState == .notLoaded,
                            hasNumberingConflict: episodes.hasNumberingConflict
                        )
                    }
                    Section("Episodes") {
                        ForEach(entries) { entry in
                            switch entry {
                            case .roster(let row):
                                PlozziOSSeasonEpisodeRow(
                                    row: row,
                                    selectedEpisodeIDs: selectedEpisodeIDs,
                                    isBusy: isBusy || isRefreshingEpisodes,
                                    onDownload: onDownloadEpisode
                                )
                            case .unavailable(let episode):
                                PlozziOSUnavailableEpisodeRow(episode: episode)
                            }
                        }
                        if entries.isEmpty {
                            Text("No episode information is available for this season.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.top, 12, for: .scrollContent)
                .listSectionSpacing(16)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SeasonRequestRefreshButton(
                    isRefreshing: isRefreshingEpisodes || isRefreshingSeasons,
                    isSubmitting: isBusy || isRequestingSeasons,
                    onRefresh: { Task { await refresh() } }
                )
                .accessibilityLabel("Refresh Episodes and Season Status")
            }
        }
        .task(id: "\(episodeContainerKey)|\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await loadLibrary(forceRefresh: false)
        }
        .task(id: "\(metadataContext)|\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await loadMetadata(forceRefresh: loadedMetadataContext != metadataContext)
        }
    }

    private func downloadableEpisodes(in list: SeasonEpisodeList) -> [MediaItem] {
        var seen = Set<String>()
        let selection = selectedEpisodeIDs
        return list.rows.flatMap(\.libraryEpisodes).filter {
            selection.contains($0.stablePresentationID) && seen.insert($0.stablePresentationID).inserted
        }
    }

    private func episodeEntries(in list: SeasonEpisodeList) -> [PlozziOSSeasonEpisodeEntry] {
        let entries = list.rows.map(PlozziOSSeasonEpisodeEntry.roster)
            + upcomingPlaceholders(in: list).map(PlozziOSSeasonEpisodeEntry.unavailable)
        return entries.sorted {
            let lhs = $0.episodeNumber ?? Int.max
            let rhs = $1.episodeNumber ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    private func upcomingPlaceholders(in list: SeasonEpisodeList) -> [MediaItem] {
        guard list.coverage == nil else { return [] }
        let unavailable = libraryEpisodes.filter {
            $0.kind == .episode && !$0.locallyValidatedPlayableSource
        }
        let scheduled = SeriesUpcoming.placeholders(
            for: season.number, seriesID: series.id, seriesTitle: series.title,
            ownedEpisodes: libraryEpisodes,
            schedule: viewModel.state.value?.upcomingSchedule?.upcomingEpisodes ?? [], seriesArtwork: series
        )
        var seen = Set<String>()
        return (unavailable + scheduled).filter { seen.insert($0.stablePresentationID).inserted }
    }

    private func loadLibrary(forceRefresh: Bool) async {
        let context = metadataContext
        guard isCurrentSeries, !Task.isCancelled else { return }
        if needsLooseEpisodeLoad {
            await viewModel.loadEpisodes(for: series.id, forceRefresh: forceRefresh)
        }
        for librarySeason in season.librarySeasons {
            guard !Task.isCancelled, isCurrentSeries, context == metadataContext else { return }
            await viewModel.loadEpisodes(for: librarySeason.id, forceRefresh: forceRefresh)
        }
    }

    private func loadMetadata(forceRefresh: Bool) async {
        guard let number = season.number, isCurrentSeries, !Task.isCancelled else { return }
        let context = metadataContext
        await viewModel.loadSeasonEpisodeRoster(for: number, forceRefresh: forceRefresh)
        guard !Task.isCancelled, isCurrentSeries, context == metadataContext else { return }
        loadedMetadataContext = context
    }

    private func refresh() async {
        let context = metadataContext
        isRefreshingEpisodes = true
        defer { isRefreshingEpisodes = false }
        onRefreshSeasonRequests()
        await loadLibrary(forceRefresh: true)
        guard !Task.isCancelled, isCurrentSeries, context == metadataContext else { return }
        await loadMetadata(forceRefresh: true)
    }

    private func downloadState(
        for episodes: [MediaItem]
    ) -> MediaDownloadBadgeState? {
        downloadCollectionBadgeState(
            records: matchingDownloadRecords(
                downloads: appModel.downloads,
                episodes: episodes,
                seriesID: series.id,
                sourceAccountID: series.sourceAccountID,
                seasonNumber: season.number
            ),
            expectedCount: episodes.count,
            scopeKind: .season
        )
    }

    private func performSeasonAction(_ episodes: [MediaItem]) {
        if let batchID = activeSeasonBatchID {
            Task { await appModel.downloads.pauseBatch(batchID) }
        } else if let batchID = pausedSeasonBatchID {
            Task { await appModel.downloads.resumeBatch(batchID) }
        } else {
            onDownloadSeason(episodes)
        }
    }

    private var seasonBatchRecords: [DownloadedMediaRecord] {
        let selection = selectedEpisodeIDs
        return matchingDownloadRecords(
            downloads: appModel.downloads,
            episodes: libraryEpisodes.filter { selection.contains($0.stablePresentationID) },
            seriesID: series.id,
            sourceAccountID: series.sourceAccountID,
            seasonNumber: season.number
        ).filter { $0.batchKind == .season }
    }

    private var activeSeasonBatchID: String? {
        seasonBatchRecords.first {
            $0.status == .queued
                || $0.status == .preparing
                || $0.status == .downloading
        }?.batchID
    }

    private var pausedSeasonBatchID: String? {
        guard activeSeasonBatchID == nil else { return nil }
        return seasonBatchRecords.first { $0.status == .paused }?.batchID
    }
}

private struct PlozziOSSeasonEpisodeRow: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let row: SeasonEpisodeRow
    let selectedEpisodeIDs: Set<String>
    let isBusy: Bool
    let onDownload: (MediaItem, DownloadQuality) -> Void

    var body: some View {
        let selected = row.libraryEpisodes.filter { selectedEpisodeIDs.contains($0.stablePresentationID) }
        if selected.isEmpty {
            SeasonEpisodeRowContent(
                number: row.episodeNumber,
                title: appModel.settings.spoilers.settings.isEnabled ? nil : row.metadata?.title
            ) {
                SeasonEpisodeRowArtwork(showsMediaEdge: false) {
                    MediaArtworkPlaceholder(glyphSize: 16, symbol: .media)
                }
            } status: {
                if row.libraryEpisodes.isEmpty {
                    SeasonEpisodeAvailabilityLabel(
                        availability: row.availability,
                        airDate: row.metadata?.airDate
                    )
                } else {
                    SeasonEpisodeAvailabilityLabel(
                        availability: .inLibrary, title: "Available in Another Version"
                    )
                }
            } accessory: {}
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(selected, id: \.stablePresentationID) { episode in
                    PlozziOSEpisodeDownloadRow(
                        episode: episode, displayedEpisodeNumber: row.episodeNumber,
                        isBusy: isBusy, onDownload: onDownload
                    )
                }
            }
        }
    }
}

private struct PlozziOSUnavailableEpisodeRow: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let episode: MediaItem

    var body: some View {
        SeasonEpisodeRowContent(
            number: episode.episodeNumber,
            title: appModel.settings.spoilers.settings.shouldHideText(for: episode) ? nil : episode.title
        ) {
            SeasonEpisodeRowArtwork(showsMediaEdge: false) {
                MediaArtworkPlaceholder(glyphSize: 16, symbol: .media)
            }
        } status: {
            SeasonEpisodeAvailabilityLabel(
                availability: .scheduled(
                    airDate: episode.scheduledAirDate ?? episode.releaseDate,
                    hasTime: episode.scheduledAirDateHasTime,
                    calendarDayStoredInUTC: episode.scheduledAirDate == nil
                ),
                airDate: episode.scheduledAirDate ?? episode.releaseDate,
                calendarDayStoredInUTC: episode.scheduledAirDate == nil
            )
        } accessory: {}
    }
}

private struct PlozziOSEpisodeDownloadRow: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var showsDownloadConfirmation = false

    let episode: MediaItem
    var displayedEpisodeNumber: Int? = nil
    let isBusy: Bool
    let onDownload: (MediaItem, DownloadQuality) -> Void

    var body: some View {
        let record = currentDownloadRecord
        SeasonEpisodeRowContent(
            number: displayedEpisodeNumber ?? episode.episodeNumber,
            title: appModel.settings.spoilers.settings.shouldHideText(for: episode) ? nil : episode.title
        ) {
            PlozziOSDownloadThumbnail(
                item: episode,
                style: .episode
            )
        } status: {
            if let record {
                downloadStatusText(for: record)
            } else {
                SeasonEpisodeAvailabilityLabel(availability: .inLibrary)
            }
        } accessory: {
            if let record {
                if record.status == .queued
                    || record.status == .preparing
                    || record.status == .downloading {
                    Button {
                        Task { await appModel.downloads.pause(record) }
                    } label: {
                        PlozziOSDownloadControl(state: record.badgeState)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel("Pause Download")
                } else if record.status == .paused || record.status == .failed {
                    Button {
                        Task { await appModel.downloads.resume(record) }
                    } label: {
                        PlozziOSDownloadControl(
                            state: record.badgeState,
                            fallbackSystemImage: "arrow.clockwise"
                        )
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel("Resume Download")
                } else if let state = record.badgeState {
                    PlozziOSDownloadControl(state: state)
                }
            } else {
                Button {
                    if appModel.downloads.asksBeforeDownloading {
                        showsDownloadConfirmation = true
                    } else {
                        onDownload(
                            episode,
                            appModel.downloads.downloadQuality
                        )
                    }
                } label: {
                    PlozziOSDownloadControl()
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(Text("Download \(displayTitle)"))
                .confirmationDialog(
                    Text("Download \(displayTitle)?"),
                    isPresented: $showsDownloadConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Original") {
                        onDownload(episode, .original)
                    }
                    if appModel.downloads.supportsReducedQuality(for: episode) {
                        Button("1080p • 20 Mbps") {
                            onDownload(episode, .hd1080)
                        }
                        Button("720p • 4 Mbps") {
                            onDownload(episode, .hd720)
                        }
                        Button("480p • 1.5 Mbps") {
                            onDownload(episode, .sd480)
                        }
                        if let custom = appModel.downloads.customDownloadQuality,
                           let title = appModel.downloads.customDownloadQualityTitle {
                            Button(title) {
                                onDownload(episode, custom)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Reduced qualities are transcoded by your media server.")
                }
            }
        }
        .task(id: "\(episode.sourceAccountID ?? "")|\(episode.id)") {
            guard let provider = appModel.provider(for: episode) else {
                return
            }
            await appModel.downloads.refreshReducedQualitySupport(
                for: episode,
                provider: provider
            )
        }
    }

    private var displayTitle: Text {
        let spoilers = appModel.settings.spoilers.settings
        if spoilers.shouldHideText(for: episode) {
            if let number = displayedEpisodeNumber ?? episode.episodeNumber {
                return Text("Episode \(number)")
            }
            return Text(spoilers.maskedTitle(for: episode))
        }
        return Text(verbatim: episode.title)
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard !appModel.downloads.records.isEmpty else { return nil }
        return appModel.downloads.cachedRecord(forSelectedVersionOf: episode)
    }

    @ViewBuilder
    private func downloadStatusText(
        for record: DownloadedMediaRecord
    ) -> some View {
        switch record.status {
        case .queued:
            Text("Queued")
        case .preparing:
            if let fraction = record.preparationFraction {
                Text("Preparing on server ") + Text(
                    fraction,
                    format: .percent.precision(.fractionLength(0))
                )
            } else {
                Text("Preparing on server")
            }
        case .downloading:
            downloadingStatusText(for: record)
        case .paused:
            Text("Paused")
        case .failed:
            Text("Download Failed")
        case .completed:
            Text("Downloaded")
        }
    }

    @ViewBuilder
    private func downloadingStatusText(
        for record: DownloadedMediaRecord
    ) -> some View {
        // Metrics are formatted data, not another translatable status template.
        if let fraction = record.fractionCompleted {
            Text(MediaDownloadDestination.current.downloadingTitle)
                + Text(verbatim: " ")
                + Text(fraction, format: .percent.precision(.fractionLength(0)))
                + transferMetricsText(for: record)
        } else {
            Text(MediaDownloadDestination.current.downloadingTitle) + transferMetricsText(for: record)
        }
    }

    private func transferMetricsText(
        for record: DownloadedMediaRecord
    ) -> Text {
        guard let metrics = appModel.downloads.transferMetrics(for: record),
              metrics.bytesPerSecond > 0 else {
            return Text(verbatim: "")
        }
        var detail = metrics.bytesPerSecond.formatted(
            .byteCount(style: .file)
        ) + "/s"
        if let eta = metrics.estimatedTimeRemaining, eta >= 1 {
            detail += " • " + Duration.seconds(eta).formatted(
                .units(
                    allowed: [.hours, .minutes],
                    width: .abbreviated,
                    maximumUnitCount: 2
                )
            ) + " remaining"
        }
        return Text(verbatim: " • \(detail)")
    }
}

private struct PlozziOSDownloadThumbnail: View {
    @Environment(PlozziOSAppModel.self) private var appModel

    enum Style {
        case season
        case episode
    }

    let item: MediaItem
    let style: Style

    @ViewBuilder
    var body: some View {
        let showsMediaEdge = MediaArtworkPlaceholder.Symbol(for: item) == .playback
        switch style {
        case .season:
            SeasonDownloadRowArtwork(showsMediaEdge: showsMediaEdge) {
                FallbackAsyncImage(
                    references: item.artworkReferences(for: .poster),
                    variant: .posterCard,
                    asyncFallbackURL: {
                        await ArtworkRouter.shared.artworkURL(.poster, for: item)
                    },
                    pinIdentity: item.stablePresentationID
                ) {
                    MediaArtworkPlaceholder(glyphSize: 16, symbol: .init(for: item))
                }
            }

        case .episode:
            let spoilers = appModel.settings.spoilers.settings
            SeasonEpisodeRowArtwork(showsMediaEdge: showsMediaEdge) {
                if spoilers.shouldHideThumbnail(for: item), spoilers.mode == .placeholder {
                    MediaArtworkPlaceholder(glyphSize: 16, symbol: .init(for: item))
                } else {
                    FallbackAsyncImage(
                        references: item.artworkReferences(for: .episodeThumbnail),
                        variant: .landscapeCard,
                        asyncFallbackURL: {
                            await ArtworkRouter.shared.artworkURL(.thumbnail, for: item)
                        },
                        pinIdentity: item.stablePresentationID
                    ) {
                        MediaArtworkPlaceholder(glyphSize: 16, symbol: .init(for: item))
                    }
                    .blur(radius: spoilers.shouldHideThumbnail(for: item) ? 10 : 0)
                }
            }
        }
    }
}

private struct PlozziOSDownloadControl: View {
    var state: MediaDownloadBadgeState?
    var isPreparing = false
    var fallbackSystemImage = "arrow.down"

    var body: some View {
        ZStack {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                    .accessibilityLabel("Preparing Download")
            } else if let state {
                statusIcon(state)
            } else {
                Image(systemName: "\(fallbackSystemImage).circle")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Download")
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    @ViewBuilder
    private func statusIcon(_ state: MediaDownloadBadgeState) -> some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        case .inProgress(let fraction):
            if let fraction {
                progressRing(fraction: fraction, color: .primary)
                    .accessibilityLabel(Text(MediaDownloadDestination.current.downloadingTitle))
                    .accessibilityValue(
                        Text(
                            fraction,
                            format: .percent.precision(.fractionLength(0))
                        )
                    )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                    .accessibilityLabel(Text(MediaDownloadDestination.current.downloadingTitle))
            }
        case .paused(let fraction):
            if let fraction {
                progressRing(fraction: fraction, color: .orange)
                    .accessibilityLabel("Download Paused")
                    .accessibilityValue(
                        Text(
                            fraction,
                            format: .percent.precision(.fractionLength(0))
                        )
                    )
            } else {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Download Paused")
            }
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityLabel("Download Failed")
        }
    }

    private func progressRing(
        fraction: Double,
        color: Color
    ) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: 25, height: 25)
    }
}

@MainActor
private func matchingDownloadRecords(
    downloads: PlozziOSDownloadsModel,
    episodes: [MediaItem]?,
    seriesID: String?,
    sourceAccountID: String?,
    seasonNumber: Int?
) -> [DownloadedMediaRecord] {
    guard !downloads.records.isEmpty else { return [] }
    if let episodes {
        return episodes.compactMap {
            downloads.cachedRecord(forSelectedVersionOf: $0)
        }
    }
    guard let seriesID else { return [] }
    return downloads.records.filter { record in
        record.snapshot.seriesID == seriesID
            && (sourceAccountID == nil
                || record.snapshot.sourceAccountID == sourceAccountID)
            && (seasonNumber == nil
                || record.snapshot.seasonNumber == seasonNumber)
    }
}

private func downloadCollectionBadgeState(
    records: [DownloadedMediaRecord],
    expectedCount: Int?,
    scopeKind: DownloadBatchKind
) -> MediaDownloadBadgeState? {
    guard !records.isEmpty else { return nil }
    let explicitBatch = records.filter {
        $0.batchKind == scopeKind && $0.batchID != nil
    }
    let activeBatchID = explicitBatch.first(where: {
        $0.status == .queued
            || $0.status == .preparing
            || $0.status == .downloading
            || $0.status == .paused
            || $0.status == .failed
    })?.batchID
    let progressRecords = activeBatchID.map { id in
        records.filter { $0.batchID == id }
    } ?? []
    let progressExpectedCount =
        progressRecords.first?.batchExpectedCount
        ?? expectedCount
        ?? progressRecords.count
    func visibleFraction(_ record: DownloadedMediaRecord) -> Double? {
        record.status == .preparing
            ? record.preparationFraction
            : record.fractionCompleted
    }
    let hasUnknownProgress = progressRecords.contains {
        $0.status != .completed && visibleFraction($0) == nil
    }
    let fraction: Double? = hasUnknownProgress
        ? nil
        : progressRecords.reduce(0.0) { partial, record in
            partial + (visibleFraction(record)
                ?? (record.status == .completed ? 1 : 0))
        } / Double(max(1, progressExpectedCount))

    if progressRecords.contains(where: { $0.status == .failed }) {
        return .failed
    }
    if progressRecords.contains(where: {
        $0.status == .queued
            || $0.status == .preparing
            || $0.status == .downloading
    }) {
        return .inProgress(fraction: fraction)
    }
    if progressRecords.contains(where: { $0.status == .paused }) {
        return .paused(fraction: fraction)
    }
    if let expectedCount,
       expectedCount > 0,
       records.count == expectedCount,
       records.allSatisfy({ $0.status == .completed }) {
        return .completed
    }
    return nil
}

/// Backing data for a bulk season/show download confirmation.
private struct PlozziOSSeasonDownloadPrompt: Identifiable {
    struct Batch {
        let season: MediaItem
        let episodes: [MediaItem]
    }

    enum Scope {
        case season(SeriesDownloadSeasonTitle)
        case show(String)
    }

    let scope: Scope
    let batches: [Batch]

    var id: String { batches.map(\.season.id).joined(separator: "|") }
    var count: Int { batches.reduce(0) { $0 + $1.episodes.count } }

    var title: Text {
        switch scope {
        case .season(let title):
            Text("Download \(Text(title))?")
        case .show(let title):
            Text("Download all of \(title)?")
        }
    }

    var message: LocalizedStringResource {
        guard let free = Self.freeSpaceText() else {
            return """
                This downloads all \(count) episodes at original quality and can use \
                significant storage and data. You can remove them anytime from Downloads.
                """
        }
        return """
            This downloads all \(count) episodes at original quality and can use \
            significant storage and data. You can remove them anytime from Downloads.

            \(free) free on this device.
            """
    }

    /// Best-effort human-readable free space so a bulk grab shows headroom
    /// awareness. Returns `nil` when the capacity can't be read.
    private static func freeSpaceText() -> String? {
        let url = URL.documentsDirectory
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return capacity.formatted(.byteCount(style: .file))
    }
}

private struct PlozziOSSeasonButton: View {
    @Environment(\.themePalette) private var palette

    /// Season name from the server — content, so rendered verbatim.
    let title: String   // l10n:content — season name from the server
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(
                    isSelected
                        ? palette.backgroundBase
                        : palette.primaryText
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    isSelected
                        ? palette.primaryText
                        : palette.cardSurface.opacity(0.92),
                    in: Capsule()
                )
                .overlay {
                    if !isSelected {
                        Capsule()
                            .strokeBorder(
                                palette.primaryText.opacity(0.2),
                                lineWidth: 1
                            )
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct PlozziOSInlineEpisodeRail: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var scrollPositionID: String?
    let episodes: [MediaItem]?
    let isLoading: Bool
    var currentEpisodeID: String? = nil
    let onInteraction: () -> Void
    let onPlay: (MediaItem, Bool) -> Void

    init(
        episodes: [MediaItem]?,
        isLoading: Bool,
        currentEpisodeID: String? = nil,
        onInteraction: @escaping () -> Void = {},
        onPlay: @escaping (MediaItem, Bool) -> Void
    ) {
        self.episodes = episodes
        self.isLoading = isLoading
        self.currentEpisodeID = currentEpisodeID
        self.onInteraction = onInteraction
        self.onPlay = onPlay
        _scrollPositionID = State(initialValue: currentEpisodeID)
    }

    var body: some View {
        if isLoading {
            PlozziOSInlineEpisodeSkeletonRail()
        } else if let episodes, episodes.isEmpty {
            ContentUnavailableView(
                "No episodes",
                systemImage: "play.rectangle"
            )
            .frame(minHeight: 180)
        } else if let episodes {
            ScrollView(.horizontal) {
                LazyHStack(
                    alignment: .top,
                    spacing: PlozziOSMediaRailLayout.visibleSpacing
                ) {
                    ForEach(episodes) { episode in
                        PlozziOSInlineEpisodeEntry(
                            episode: episode,
                            episodes: episodes,
                            onPlay: onPlay
                        )
                        .id(episode.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition(id: $scrollPositionID, anchor: .leading)
            .contentMargins(
                .horizontal,
                PlozziOSPageLayout.horizontalInset(
                    for: horizontalSizeClass
                ),
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    onInteraction()
                }
            }
            .onChange(of: currentEpisodeID, initial: true) { _, target in
                guard let target else { return }
                scrollPositionID = target
            }
        }
    }
}

private struct PlozziOSInlineEpisodeSkeletonRail: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView(.horizontal) {
            HStack(
                alignment: .top,
                spacing: PlozziOSMediaRailLayout.visibleSpacing
            ) {
                ForEach(0..<6, id: \.self) { _ in
                    PlozziOSInlineEpisodeSkeleton()
                }
            }
        }
        .contentMargins(
            .horizontal,
            PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass),
            for: .scrollContent
        )
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .accessibilityLabel("Loading episodes")
    }
}

private struct PlozziOSInlineEpisodeSkeleton: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette

    @ViewBuilder
    var body: some View {
        if cardStyle == .framed {
            content
                .plozzFramedMediaCard(
                    innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                style: .continuous
            )
            .fill(palette.fill)
            .frame(width: cardWidth, height: cardWidth * 9 / 16)
            .plozzMediaEdge(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
            )

            VStack(alignment: .leading, spacing: 6) {
                skeletonLine(width: 72, height: 10)
                skeletonLine(width: cardWidth * 0.64, height: 17)
                skeletonLine(width: cardWidth * 0.88, height: 13)
                skeletonLine(width: cardWidth * 0.72, height: 13)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(.horizontal, metrics.landscapeCaptionInset)
        }
        .frame(width: cardWidth, alignment: .leading)
        .padding(cardStyle == .framed ? 10 : 0)
        .shimmering()
    }

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(palette.fill)
            .frame(width: width, height: height)
    }

    private var cardWidth: CGFloat {
        horizontalSizeClass == .regular ? 360 : 300
    }
}

private struct PlozziOSInlineEpisodeEntry: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    @Environment(PlozziOSAppModel.self) private var appModel
    @Environment(\.mediaItemNavigator) private var navigator
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?

    let episode: MediaItem
    let episodes: [MediaItem]
    let onPlay: (MediaItem, Bool) -> Void

    @ViewBuilder
    var body: some View {
        if cardStyle == .framed {
            content
                .plozzFramedMediaCard(
                    innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onPlay(episode, false)
            } label: {
                episodeArtwork
            }
            .buttonStyle(.plain)
            // An unreleased episode has no file behind it, so tapping it can only
            // fail. It stays visible and legible — that IS the information — but
            // is inert, and its actions menu is withdrawn since none apply.
            .disabled(episode.isUpcomingUnaired)
            .overlay(alignment: .topLeading) {
                Menu {
                    episodeMenuActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: metrics.artworkMenuGlyphSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(
                            width: metrics.artworkMenuTargetSize,
                            height: metrics.artworkMenuTargetSize
                        )
                        .contentShape(Circle())
                }
                .accessibilityLabel("More actions for \(episode.title)")
                .opacity(episode.isUpcomingUnaired ? 0 : 1)
                .disabled(episode.isUpcomingUnaired)
            }
            .overlay(alignment: .topTrailing) {
                MediaCardPlaybackIndicators(
                    item: episode,
                    showsProgressBar: false,
                    badgeInset: 8
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                        style: .continuous
                    )
                )
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .center, spacing: 8) {
                    EpisodeWatchStatePill(
                        item: episode,
                        showsWatched: false,
                        showsBackground: false
                    )
                    .font(.caption.weight(.semibold))
                    .frame(height: 24)
                    Spacer(minLength: 8)
                    if let state = currentDownloadRecord?.badgeState {
                        MediaDownloadBadge(state: state, size: metrics.resumeChipAccessorySize)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let number = episode.episodeNumber {
                    Text("Episode \(number)")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .plozzForeground(.secondary)
                }
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview.overviewMarkdown ?? AttributedString(overview))
                        .font(.subheadline)
                        .plozzForeground(.secondary)
                        .lineLimit(2)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 40,
                            alignment: .topLeading
                        )
                } else {
                    Color.clear.frame(height: 40).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.landscapeCaptionInset)
        }
        .frame(width: cardWidth, alignment: .leading)
        .padding(cardStyle == .framed ? 10 : 0)
        .contextMenu { episodeMenuActions }
        .task(id: "\(episode.id)|\(episode.selectedVersionID ?? "")") {
            downloadRecord = await appModel.downloads
                .record(forSelectedVersionOf: episode)
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { downloadError != nil },
                set: { if !$0 { downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: downloadError ?? "")
        }
    }

    private var cardWidth: CGFloat {
        horizontalSizeClass == .regular ? 360 : 300
    }

    private var episodeArtwork: some View {
        // `.episodeThumbnail` rather than a hand-rolled `backdropURL ?? posterURL`:
        // `backdropURL` is the SHOW's artwork, so preferring it showed series art
        // on every episode row here while tvOS — which uses the shared placement —
        // was correct. Going through the placement also picks up the external
        // artwork fallback when a server has no still of its own.
        FallbackAsyncImage(
            references: episode.artworkReferences(for: .episodeThumbnail),
            variant: .landscapeCard,
            asyncFallbackURL: { await ArtworkRouter.shared.artworkURL(.thumbnail, for: episode) },
            pinIdentity: episode.stablePresentationID
        ) {
            // Shared with the tvOS cards so a missing episode still looks the same
            // on every platform; this was a bare filled rectangle with no glyph.
            MediaArtworkPlaceholder(
                glyphSize: 32, symbol: .init(for: episode),
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
            )
        }
        .frame(width: cardWidth, height: cardWidth * 9 / 16)
        .overlay {
            // The shared wash — this card's own gradient is where it came from.
            MediaArtworkChromeScrim(top: true, bottom: true)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                style: .continuous
            )
        )
        .plozzMediaEdge(
            cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
            isEnabled: MediaArtworkPlaceholder.Symbol(for: episode) == .playback
        )
    }

    @ViewBuilder
    private var episodeMenuActions: some View {
        // Download actions now come from the shared catalog like every other
        // action, so this no longer appends its own — which is what kept them
        // exclusive to this one surface.
        ForEach(mediaActions) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                // Navigation is a view-layer concern: the action handler
                // deliberately ignores it, so routing everything through the
                // handler would leave "Episode Info" visible but inert.
                if action.isNavigation {
                    navigator?(episode)
                } else {
                    appModel.mediaItemActionHandler.perform(
                        action,
                        on: episode,
                        context: MediaItemActionContext(orderedSiblings: episodes)
                    )
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

    @ViewBuilder
    private var downloadMenuAction: some View {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading:
            Button("Pause Download", systemImage: "pause.circle") {
                Task { await pauseDownload() }
            }
        case .paused, .failed:
            Button("Resume Download", systemImage: "arrow.clockwise.circle") {
                Task { await resumeDownload() }
            }
        case .completed:
            Button(
                "Remove Download",
                systemImage: "trash",
                role: .destructive
            ) {
                Task { await removeDownload() }
            }
        case nil:
            Button("Download Episode", systemImage: "arrow.down.circle") {
                Task { await startDownload() }
            }
        }
    }

    private var mediaActions: [MediaItemAction] {
        appModel.mediaItemActionHandler.actions(
            for: episode,
            context: MediaItemActionContext(orderedSiblings: episodes)
        )
        // Drop navigation actions only when nothing can route them, matching
        // `MediaItemContextMenu`. Filtering them unconditionally is what kept
        // "Episode Info" out of this menu even after the button learned to route.
        .filter { !$0.isNavigation || navigator != nil }
    }
    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func startDownload() async {
        do {
            guard let provider = appModel.provider(for: episode) else {
                downloadError = "The selected server is no longer available."
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: episode,
                provider: provider
            )
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func pauseDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.pause(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func resumeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.resume(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func removeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.remove(record)
        downloadRecord = nil
    }
}

/// Compact per-episode download status overlaid on the thumbnail. Per the
/// desired read: a neutral **white progress ring with no center glyph** while
/// downloading (unmistakably progress, not a button), and a **filled gray
/// down-arrow** when complete (a settled status, not an action). Hidden when the
/// episode isn't downloaded — download itself is started from the ⋯ menu.
private struct PlozziOSCastSection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    // Scales the trailing whitespace with the OS text size so the space under the
    // (variably wrapped) cast names stays proportional at every Dynamic Type level,
    // mirroring the space above the About header rather than a fixed gap.
    @ScaledMetric(relativeTo: .subheadline) private var regularBottomPadding: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var compactBottomPadding: CGFloat = 24
    /// Opens a person's own page, told which server listed them — their credits
    /// are answered with that server's own person id.
    @Environment(\.mediaPersonSourceNavigator) private var openPerson
    let people: [MediaPerson]
    /// The server this title came from, and therefore whose person ids its cast
    /// list holds.
    let sourceAccountID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.title2.bold())
                .padding(.horizontal, pageInset)

            ScrollView(.horizontal) {
                LazyHStack(
                    alignment: .top,
                    spacing: PlozziOSMediaRailLayout.visibleSpacing
                ) {
                    ForEach(people.prefix(20)) { person in
                        Button {
                            openPerson?(person, sourceAccountID)
                        } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AsyncImage(url: person.imageURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(palette.fill)
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .plozzForeground(.secondary)
                                    }
                            }
                            .frame(width: tileDiameter, height: tileDiameter)
                            .clipShape(Circle())
                            .frame(width: tileDiameter, alignment: .top)

                            Text(person.name)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .top
                                )
                            if let role = person.role {
                                Text(role)
                                    .font(.caption)
                                    .plozzForeground(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .top
                                    )
                            }
                        }
                        .frame(width: tileDiameter, alignment: .top)
                        .multilineTextAlignment(.center)
                        }
                        // Plain, so the tile keeps its own colours: a bordered
                        // style would tint the name and role blue.
                        .buttonStyle(.plain)
                        // The whole tile takes the tap, not just the artwork.
                        .contentShape(Rectangle())
                        .disabled(openPerson == nil)
                    }
                }
            }
            .contentMargins(
                .horizontal,
                pageInset,
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
        }
        // Symmetric scaled whitespace above and below the cast rail so it sits with
        // balanced breathing room between the hero and the info band — and the gap
        // under the (variably wrapped) names mirrors the gap over the About header.
        .padding(.vertical, verticalPadding)
    }

    private var verticalPadding: CGFloat {
        horizontalSizeClass == .compact ? compactBottomPadding : regularBottomPadding
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }

    /// Match Home's poster artwork scale without the card's surrounding glass.
    private var tileDiameter: CGFloat { metrics.posterWidth }
}
#endif
