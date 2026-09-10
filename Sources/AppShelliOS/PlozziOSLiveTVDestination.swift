#if DEBUG && os(iOS)
import CoreModels
import CoreSecureStore
import CoreUI
import AppRuntime
import EnginePlozzigen
import FeatureLiveTV
import FeatureLiveTVCore
import FeaturePlayback
import SwiftUI

/// Development-only Live TV destination hosted by the real iPhone/iPad tab shell.
struct PlozziOSLiveTVDestination: View {
    let isActive: Bool
    let profileID: String

    @Environment(ProfilesModel.self) private var profiles
    @State private var isExpanded = false
    @State private var liveOutputGroup = LiveChannelOutputGroup()
    @State private var network: LiveTVMobileNetworkController
    @State private var externalSessions: [UUID: UUID] = [:]
    @State private var sessionProfileScope: ProfileScope
    private let preferencesNamespace: String?
    private let preferencesStore: LiveTVPreferencesStore
    private let viewSettingsStore: LiveTVViewSettingsStore
    private let sourceStore: any LiveTVSourcesStoring
    private let importModel: LiveTVPrototypeImportModel?
    private let accountsProviders: AccountsProvidersModel?
    private let authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private let connectServer: (() -> Void)?
    private let didConfigurePlaylist: () -> Void
    private let completeLibraryChannelPlayback: @MainActor @Sendable (MediaItem, UUID) throws -> Void
    private let isProfileAuthorized: @MainActor () -> Bool
    private let restoreDestination: @MainActor () async -> Bool

    init(
        isActive: Bool,
        profileID: String,
        preferencesNamespace: String?,
        importModel: LiveTVPrototypeImportModel? = nil,
        accountsProviders: AccountsProvidersModel? = nil,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        completeLibraryChannelPlayback: @escaping @MainActor @Sendable (MediaItem, UUID) throws -> Void,
        isProfileAuthorized: @escaping @MainActor () -> Bool,
        restoreDestination: @escaping @MainActor () async -> Bool = { false }
    ) {
        self.isActive = isActive
        self.profileID = profileID
        self.preferencesNamespace = preferencesNamespace
        self.importModel = importModel
        self._sessionProfileScope = State(initialValue: ProfileScope(id: profileID, namespace: preferencesNamespace))
        self.preferencesStore = LiveTVPreferencesStore(namespace: preferencesNamespace)
        self.viewSettingsStore = LiveTVViewSettingsStore(namespace: preferencesNamespace)
        self._network = State(initialValue: LiveTVMobileNetworkController(
            store: LiveTVViewSettingsStore(namespace: preferencesNamespace)
        ))
        self.sourceStore = LiveTVSourceStorage.approvalAwareStore(
            profileID: profileID, namespace: preferencesNamespace
        )
        self.accountsProviders = accountsProviders
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.connectServer = connectServer
        self.didConfigurePlaylist = didConfigurePlaylist
        self.completeLibraryChannelPlayback = completeLibraryChannelPlayback
        self.isProfileAuthorized = isProfileAuthorized
        self.restoreDestination = restoreDestination
    }

    private func liveTVContent(cache: LiveTVIndexedCache, runtime: LiveTVLibraryRuntime) -> some View {
        LiveTVPrototypeView(
            isActive: isActive,
            preferencesStore: preferencesStore,
            viewSettingsStore: viewSettingsStore,
            sourceStore: sourceStore,
            serverProviderResolver: accountsProviders?.liveTVProviderResolver(),
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            isProfileAuthorized: { [profiles, profileID, preferencesNamespace, isProfileAuthorized] in
                isProfileAuthorized()
                    && profiles.activeProfileID == profileID && profiles.activeNamespace == preferencesNamespace
            },
            serverChoices: accountsProviders?.liveTVServerChoices ?? [],
            serverAuthorizationID: accountsProviders?.liveTVAuthorizationID ?? "",
            connectServer: connectServer,
            didConfigurePlaylist: didConfigurePlaylist,
            onExpandedChange: { isExpanded = $0 },
            allowsPlayback: isCurrentProfileScope && network.allowsPlayback,
            playbackUnavailableReason: effectiveNetworkBlock?.playbackMessage,
            restoreDestination: restoreDestination,
            catalogCache: cache,
            sourceLoader: LiveTVCatalogStorage.loader(profileID: profileID, namespace: preferencesNamespace),
            importModel: importModel,
            profileID: profileID,
            preferencesNamespace: runtime.preferencesNamespace,
            libraryService: runtime.service,
            libraryHistory: runtime.history,
            libraryIssue: runtime.issue,
            reloadLibrary: runtime.retry,
            prepareLibraryChannels: runtime.prepareForEditing,
            libraryIsAuthorized: { [weak runtime] in runtime?.authorizationID != nil },
            sourceApprovalContext: { [profiles] in LiveTVSourceApprovalContext(profiles: profiles) }
        ) { playback in
            LiveChannelPlayerView(
                channelID: playback.channel.id,
                title: playback.channel.name,
                input: playback.input,
                logoURL: playback.channel.logoURL,
                makeEngine: {
                    runtime.makeEngine(
                        engine: try PlozzigenVideoEngine(authenticatedHTTPResolver: playback.authenticatedHTTPResolver),
                        onCompleted: { [profiles, profileID, preferencesNamespace,
                                        completeLibraryChannelPlayback, weak runtime] item, token in
                            try Task.checkCancellation()
                            guard profiles.activeProfileID == profileID,
                                  profiles.activeNamespace == preferencesNamespace,
                                  let runtime, runtime.profileID == profileID,
                                  runtime.preferencesNamespace == preferencesNamespace,
                                  runtime.authorizationID != nil,
                                  runtime.history.authorizationID == token else {
                                throw LibraryChannelError.authorizationChanged
                            }
                            try completeLibraryChannelPlayback(item, token)
                        }
                    )
                },
                onPreviousChannel: playback.previousChannel,
                onNextChannel: playback.nextChannel,
                isFavorite: playback.isFavorite,
                canToggleFavorite: playback.canToggleFavorite,
                onToggleFavorite: playback.onToggleFavorite,
                isExpanded: playback.isExpanded,
                isActive: playback.isPlaybackActive,
                onReturnToGuide: playback.returnToGuide,
                playPauseRequest: playback.playPauseRequest,
                onPlaybackStarted: playback.playbackStarted,
                reportingID: playback.reportingID,
                onPlaybackUpdate: playback.playbackUpdate,
                onPlaybackFailed: playback.playbackFailed,
                onVideoAspectRatioChange: playback.videoAspectRatioChanged,
                preparingChannelName: playback.preparingChannelName,
                onMultiview: playback.canOpenMultiview ? playback.openMultiview : nil,
                outputGroup: liveOutputGroup,
                outputID: playback.paneID,
                isAudible: playback.isAudible,
                countsAsWatching: playback.countsAsWatching,
                isMultiview: playback.isMultiview,
                trackPreferences: runtime.trackPreferences,
                networkBlock: effectiveNetworkBlock,
                isAuthorized: playback.isAuthorized && isCurrentProfileScope,
                presentationControls: { AnyView(PlozziOSLivePresentationControls(context: $0)) },
                onExternalContinuationChanged: { continuing in
                    if continuing {
                        guard isCurrentProfileScope else {
                            playback.externalContinuationChanged(false)
                            return
                        }
                        externalSessions[playback.paneID] = playback.reportingID
                    } else if externalSessions[playback.paneID] == playback.reportingID {
                        externalSessions.removeValue(forKey: playback.paneID)
                    }
                    playback.externalContinuationChanged(continuing)
                },
                onRestoreUI: {
                    guard isCurrentProfileScope else { return false }
                    let restored = await playback.restorePlayer()
                    return restored && isCurrentProfileScope
                },
                onStopPlayback: playback.stopPlayback
            )
        }
    }

    var body: some View {
        LiveTVCatalogStorageView(load: { try LiveTVCatalogStorage.cache(profileID: profileID) }) { cache in
            LiveTVLibraryRuntimeView(profileID: profileID, profiles: profiles, accounts: accountsProviders) { runtime in
                liveTVContent(cache: cache, runtime: runtime)
            }
        }
        .id(profileScope)
        .toolbar(isExpanded ? .hidden : .visible, for: .tabBar)
        .onAppear {
            network.start()
        }
        .onDisappear {
            if externalSessions.isEmpty { network.stop() }
        }
        .onChange(of: activeProfileScope) { _, currentScope in
            if currentScope != profileScope {
                network.stop()
                externalSessions.removeAll()
            }
        }
        .onChange(of: profileScope) { _, currentScope in
            network.stop()
            externalSessions.removeAll()
            network = LiveTVMobileNetworkController(store: viewSettingsStore)
            sessionProfileScope = currentScope
            network.start()
        }
        .onChange(of: isActive, initial: true) { _, active in
            if !active {
                isExpanded = false
            }
        }
    }

    private var effectiveNetworkBlock: LiveTVNetworkBlock? {
        isCurrentProfileScope ? network.block : .checkingConnection
    }

    private var isCurrentProfileScope: Bool {
        sessionProfileScope == profileScope && activeProfileScope == profileScope
    }

    private var profileScope: ProfileScope { ProfileScope(id: profileID, namespace: preferencesNamespace) }
    private var activeProfileScope: ProfileScope {
        ProfileScope(id: profiles.activeProfileID, namespace: profiles.activeNamespace)
    }

    private struct ProfileScope: Hashable {
        let id: String
        let namespace: String?
    }
}

struct PlozziOSLiveTVSourcesDestination: View {
    let profileID: String
    let preferencesNamespace: String?
    let accountsProviders: AccountsProvidersModel
    let profiles: ProfilesModel
    var connectServer: (() -> Void)? = nil
    let didConfigurePlaylist: () -> Void
    var isPresented = true
    var isProfileAuthorized: @MainActor () -> Bool = { true }

    var body: some View {
        LiveTVCatalogStorageView(load: { try LiveTVCatalogStorage.cache(profileID: profileID) }) { cache in
            LiveTVLibraryRuntimeView(profileID: profileID, profiles: profiles, accounts: accountsProviders) { library in
                LiveTVSourcesRuntimeView(
                    profileID: profileID, namespace: preferencesNamespace,
                    profiles: profiles, accounts: accountsProviders, cache: cache,
                    isPresented: isPresented, isProfileAuthorized: isProfileAuthorized
                ) { runtime in
                    PlozziOSLiveTVSourcesContent(
                        runtime: runtime, library: library, accounts: accountsProviders,
                        connectServer: connectServer, didConfigurePlaylist: didConfigurePlaylist
                    )
                }
            }
        }
        .environment(profiles)
        .id(profileID)
        .id(preferencesNamespace)
    }
}

private struct PlozziOSLiveTVSourcesContent: View {
    let runtime: LiveTVSourcesRuntime
    let library: LiveTVLibraryRuntime
    let accounts: AccountsProvidersModel
    let connectServer: (() -> Void)?
    let didConfigurePlaylist: () -> Void
    @State private var managesChannels = false
    @State private var scansChannels = false
    @State private var scanOfferSourceID: String?

    var body: some View {
        SettingsPageList {
            LiveTVSourcesView(
                store: runtime.store, catalog: runtime.catalog, presentation: .settingsPane,
                serverChoices: accounts.liveTVServerChoices,
                serverProviderResolver: accounts.liveTVProviderResolver(),
                connectServer: connectServer, didConfigurePlaylist: didConfigurePlaylist,
                createChannel: { managesChannels = true },
                scanChannels: { scansChannels = true },
                scanCoordinator: runtime.scanBinding.coordinator,
                didImportPlaylist: { scanOfferSourceID = $0 }
            )
            if let scanOfferSourceID, runtime.isCurrent {
                LiveTVScanImportOffer(
                    coordinator: runtime.scanBinding.coordinator, sourceID: scanOfferSourceID,
                    skip: { self.scanOfferSourceID = nil }
                )
            }
        }
        .navigationTitle("Sources")
        .navigationDestination(isPresented: $managesChannels) {
            LiveTVSourcesLibraryView(runtime: runtime, library: library) {
                LibraryChannelManagementView(
                    service: library.service, history: library.history, prepareLibraries: library.prepareForEditing)
            }
        }
        .navigationDestination(isPresented: $scansChannels) {
            LiveTVSourcesScanView(runtime: runtime) {
                LiveTVScanSourcesView(
                    coordinator: runtime.scanBinding.coordinator,
                    sourceNames: Dictionary(uniqueKeysWithValues: runtime.catalog.imports.configuration.playlists.map {
                        ($0.id, $0.name)
                    })
                )
            }
        }
        .onChange(of: runtime.authorityID) { _, _ in
            managesChannels = false
            scansChannels = false
            scanOfferSourceID = nil
        }
    }
}
#endif
