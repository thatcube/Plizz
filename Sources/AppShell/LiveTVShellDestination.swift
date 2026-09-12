#if DEBUG && os(tvOS)
import CoreModels
import CoreSecureStore
import AppRuntime
import EnginePlozzigen
import FeatureLiveTV
import FeatureLiveTVCore
import FeaturePlayback
import SwiftUI

/// Development-only composition root for Live TV inside Plozz's real navigation.
///
/// The prototype owns one player construction site and keeps this child at a
/// stable identity while channels change. The shell only reports whether the
/// destination is visible and coordinates its expanded chrome.
struct LiveTVShellDestination: View {
    let isActive: Bool
    let profileID: String
    let usesNativeNavigation: Bool
    let onExpandedChange: (Bool) -> Void

    @Environment(ProfilesModel.self) private var profiles
    @State private var hidesNavigation = false
    @State private var liveOutputGroup = LiveChannelOutputGroup()
    private let preferencesStore: LiveTVPreferencesStore
    private let viewSettingsStore: LiveTVViewSettingsStore
    private let sourceStore: any LiveTVSourcesStoring
    private let preferencesNamespace: String?
    private let accountsProviders: AccountsProvidersModel?
    private let authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private let connectServer: (() -> Void)?
    private let didConfigurePlaylist: () -> Void
    private let completeLibraryChannelPlayback: @MainActor @Sendable (MediaItem, UUID) throws -> Void
    private let isProfileAuthorized: @MainActor () -> Bool

    init(
        isActive: Bool,
        profileID: String,
        preferencesNamespace: String?,
        accountsProviders: AccountsProvidersModel? = nil,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        completeLibraryChannelPlayback: @escaping @MainActor @Sendable (MediaItem, UUID) throws -> Void,
        isProfileAuthorized: @escaping @MainActor () -> Bool,
        usesNativeNavigation: Bool = false,
        onExpandedChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isActive = isActive
        self.profileID = profileID
        self.usesNativeNavigation = usesNativeNavigation
        self.onExpandedChange = onExpandedChange
        self.preferencesStore = LiveTVPreferencesStore(namespace: preferencesNamespace)
        self.viewSettingsStore = LiveTVViewSettingsStore(namespace: preferencesNamespace)
        self.sourceStore = LiveTVSourceStorage.approvalAwareStore(
            profileID: profileID, namespace: preferencesNamespace
        )
        self.preferencesNamespace = preferencesNamespace
        self.accountsProviders = accountsProviders
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.connectServer = connectServer
        self.didConfigurePlaylist = didConfigurePlaylist
        self.completeLibraryChannelPlayback = completeLibraryChannelPlayback
        self.isProfileAuthorized = isProfileAuthorized
    }

    @ViewBuilder
    var body: some View {
        if usesNativeNavigation {
            LiveTVNavigationContainer(hidesNavigation: hidesNavigation) {
                liveTVContent
            }
        } else {
            liveTVContent
        }
    }

    private var liveTVContent: some View {
        LiveTVCatalogStorageView(load: { try LiveTVCatalogStorage.cache(profileID: profileID) }) { cache in
            LiveTVLibraryRuntimeView(profileID: profileID, profiles: profiles, accounts: accountsProviders) { library in
                liveTVContent(cache: cache, library: library)
            }
        }
        .id(profileID)
    }

    private func liveTVContent(cache: LiveTVIndexedCache, library: LiveTVLibraryRuntime) -> some View {
        LiveTVPrototypeView(
            isActive: isActive,
            usesNativeFullscreen: usesNativeNavigation,
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
            onExpandedChange: updateExpandedState,
            catalogCache: cache,
            sourceLoader: LiveTVCatalogStorage.loader(profileID: profileID, namespace: preferencesNamespace),
            profileID: profileID,
            preferencesNamespace: preferencesNamespace,
            libraryService: library.service,
            libraryHistory: library.history,
            libraryIssue: library.issue,
            automaticChannels: library.automaticChannelsPresentation,
            reloadLibrary: library.retry,
            prepareLibraryChannels: library.prepareForEditing,
            libraryIsAuthorized: { [weak library] in library?.authorizationID != nil },
            sourceApprovalContext: { [profiles] in LiveTVSourceApprovalContext(profiles: profiles) }
        ) { playback in
            LiveChannelPlayerView(
                channelID: playback.channel.id,
                title: playback.channel.name,
                input: playback.input,
                logoURL: playback.channel.logoURL,
                makeEngine: {
                    library.makeEngine(
                        engine: try PlozzigenVideoEngine(
                            authenticatedHTTPResolver: playback.authenticatedHTTPResolver
                        ),
                        onCompleted: completeLibraryChannelPlayback
                    )
                },
                onPreviousChannel: playback.previousChannel,
                onNextChannel: playback.nextChannel,
                isFavorite: playback.isFavorite,
                canToggleFavorite: playback.canToggleFavorite,
                onToggleFavorite: playback.onToggleFavorite,
                isExpanded: playback.isExpanded,
                usesNativeFullscreen: usesNativeNavigation && !playback.isMultiview,
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
                trackPreferences: library.trackPreferences,
                isAuthorized: playback.isAuthorized
            )
        }
        .id(profileID)
        .onChange(of: isActive, initial: true) { _, active in
            if !active {
                updateExpandedState(false)
            }
        }
        .onDisappear {
            guard !(isActive && usesNativeNavigation && hidesNavigation) else { return }
            updateExpandedState(false)
        }
    }

    private func updateExpandedState(_ expanded: Bool) {
        hidesNavigation = expanded && isActive
        guard isActive else { return }
        onExpandedChange(expanded)
    }
}

struct LiveTVShellSourcesDestination: View {
    let profileID: String
    let preferencesNamespace: String?
    let accountsProviders: AccountsProvidersModel
    var connectServer: (() -> Void)? = nil
    let didConfigurePlaylist: () -> Void
    var isPresented = true
    var isProfileAuthorized: @MainActor () -> Bool = { true }
    @Environment(ProfilesModel.self) private var profiles

    var body: some View {
        LiveTVCatalogStorageView(load: { try LiveTVCatalogStorage.cache(profileID: profileID) }) { cache in
            LiveTVLibraryRuntimeView(profileID: profileID, profiles: profiles, accounts: accountsProviders) { library in
                LiveTVSourcesRuntimeView(
                    profileID: profileID, namespace: preferencesNamespace,
                    profiles: profiles, accounts: accountsProviders, cache: cache,
                    isPresented: isPresented, isProfileAuthorized: isProfileAuthorized
                ) { runtime in
                    LiveTVShellSourcesContent(
                        runtime: runtime, library: library, accounts: accountsProviders,
                        connectServer: connectServer, didConfigurePlaylist: didConfigurePlaylist
                    )
                }
            }
        }
        .id(preferencesNamespace)
        .id(profileID)
    }
}

private struct LiveTVShellSourcesContent: View {
    let runtime: LiveTVSourcesRuntime
    let library: LiveTVLibraryRuntime
    let accounts: AccountsProvidersModel
    let connectServer: (() -> Void)?
    let didConfigurePlaylist: () -> Void
    @State private var managesChannels = false
    @State private var scansChannels = false
    @State private var scanOfferSourceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
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
        .navigationDestination(isPresented: $managesChannels) {
            if runtime.isCurrent {
                LibraryChannelManagementView(
                    service: library.service, history: library.history, prepareLibraries: library.prepareForEditing,
                    automaticChannels: library.automaticChannelsPresentation)
            } else {
                ContentUnavailableView(
                    "Profile access changed", systemImage: "lock",
                    description: Text("Reopen Sources to continue."))
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

private extension LiveTVLibraryRuntime {
    var automaticChannelsPresentation: LiveTVAutomaticChannelsState {
        LiveTVAutomaticChannelsState(
            enabled: automaticChannelsEnabled,
            isWorking: isPreparingAutomaticChannels,
            issue: automaticChannelsIssue,
            channelCount: automaticChannelCount,
            skippedItemCount: automaticSkippedItemCount,
            setEnabled: setAutomaticChannelsEnabled,
            retry: retry,
            unavailableSources: automaticUnavailableSources,
            preparation: automaticPreparation
        )
    }
}
#endif
