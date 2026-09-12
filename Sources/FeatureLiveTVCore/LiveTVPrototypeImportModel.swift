#if DEBUG
import CoreModels
import Foundation
import Observation

public protocol LiveTVSourceLoading: Sendable {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport
    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport
}

public protocol LiveTVIndexedSourceLoading: LiveTVSourceLoading {
    func loadIndexedGuide(
        from url: URL, sourceID: String, channels: [LiveTVPrototypeChannel], now: Date,
        cache: LiveTVIndexedCache, lookbackDays: Int, lookaheadDays: Int
    ) async throws -> LiveTVGuideImport
}

public enum LiveTVImportPhase: Equatable, Sendable {
    case idle, loading, loaded, failed
}

public struct LiveTVGuideSourceStatus: Identifiable, Equatable, Sendable {
    public let source: LiveTVGuideSource
    public let playlistSourceID: String
    public var id: String { source.id }
    public fileprivate(set) var phase: LiveTVImportPhase = .idle
    public fileprivate(set) var failure: LiveTVSourceImportError?
    public fileprivate(set) var matchedChannelCount = 0
    public fileprivate(set) var programCount = 0
    public fileprivate(set) var lastRefresh: Date?
}

public struct LiveTVPlaylistSourceStatus: Identifiable, Equatable, Sendable {
    public let source: LiveTVPlaylistSource
    public var id: String { source.id }
    public fileprivate(set) var phase: LiveTVImportPhase = .idle
    public fileprivate(set) var failure: LiveTVSourceImportError?
    public fileprivate(set) var entryCount = 0
    public fileprivate(set) var skippedEntryCount = 0
    public fileprivate(set) var channelCount = 0
    public fileprivate(set) var lastRefresh: Date?
}

public enum LiveTVGuideGapState: Equatable, Sendable {
    case loading, disabled, failed, unmatched, noListings, unrequested

    public var title: LocalizedStringResource {
        switch self {
        case .loading: "Loading guide..."
        case .disabled: "No program guide available"
        case .failed: "Guide update failed"
        case .unmatched: "No matching program guide"
        case .noListings: "No listings for this time"
        case .unrequested: "Guide not loaded for this time"
        }
    }
}

@MainActor
@Observable
private final class LiveTVImportGuideCoverage {
    var guideChannelCount = 0
    var matchedChannelCount = 0
    var programCount = 0
    var coverageStart: Date?
    var coverageEnd: Date?
    var lastGuideRefresh: Date?
}

public typealias LiveTVGeneratedProgramLoader =
    @MainActor (Set<String>, DateInterval) throws -> [LiveTVPrototypeProgram]

@MainActor
@Observable
public final class LiveTVPrototypeImportModel {
    public private(set) var configuration: LiveTVSourcesConfiguration
    public private(set) var playlistSources: [LiveTVPlaylistSourceStatus]
    public internal(set) var serverSources: [LiveTVServerSourceStatus] = []
    public internal(set) var serverGuideWindows: [LiveTVServerGuideWindowStatus] = []
    public var playlistURL: URL? { configuration.playlists.first?.playlistURL }
    public private(set) var guideSources: [LiveTVGuideSourceStatus]
    public private(set) var enabledSourceIDs: Set<String>
    public private(set) var selectedSourceByChannel: [String: String] = [:]
    public private(set) var playlistSourceIDByChannel: [String: String] = [:]
    public private(set) var configuredSourceIDByChannel: [String: String] = [:]
    public private(set) var serverChannelReferences: [String: LiveTVServerChannelReference] = [:]
    public private(set) var playlistPhase: LiveTVImportPhase = .idle
    public private(set) var guidePhase: LiveTVImportPhase = .idle
    public private(set) var playlistFailure: LiveTVSourceImportError?
    public private(set) var guideFailure: LiveTVSourceImportError?
    public var entryCount: Int {
        playlistSources.filter(\.source.isEnabled).reduce(0) { $0 + $1.entryCount }
    }
    public var skippedEntryCount: Int {
        playlistSources.filter(\.source.isEnabled).reduce(0) { $0 + $1.skippedEntryCount }
    }
    private let guideCoverage = LiveTVImportGuideCoverage()
    public private(set) var guideChannelCount: Int {
        get { guideCoverage.guideChannelCount }
        set { guideCoverage.guideChannelCount = newValue }
    }
    public private(set) var matchedChannelCount: Int {
        get { guideCoverage.matchedChannelCount }
        set { guideCoverage.matchedChannelCount = newValue }
    }
    public private(set) var programCount: Int {
        get { guideCoverage.programCount }
        set { guideCoverage.programCount = newValue }
    }
    public var retainedProgramCount: Int {
        _ = catalogRevision
        return guideSources.filter { enabledSourceIDs.contains($0.id) }
            .reduce(0) { $0 + (cachedGuides[$1.id]?.programCount ?? 0) }
            + serverSources.filter(\.source.isEnabled).reduce(0) { $0 + (cachedServerCatalogs[$1.id]?.programs.count ?? 0) }
            + generatedPrograms.count
    }
    public private(set) var coverageStart: Date? {
        get { guideCoverage.coverageStart }
        set { guideCoverage.coverageStart = newValue }
    }
    public private(set) var coverageEnd: Date? {
        get { guideCoverage.coverageEnd }
        set { guideCoverage.coverageEnd = newValue }
    }
    public private(set) var lastGuideRefresh: Date? {
        get { guideCoverage.lastGuideRefresh }
        set { guideCoverage.lastGuideRefresh = newValue }
    }
    public private(set) var identityReviews: [String: [LiveTVIdentityReview]] = [:]
    public private(set) var guideDiscoveryFailures: [String: LiveTVSourceImportError] = [:]
    public private(set) var cacheFailure: LiveTVSourceImportError?
    public private(set) var catalogRevision = 0
    public private(set) var mappingOverrides: [String: LiveTVGuideMappingOverride] = [:]
    public var supportsDurableCatalog: Bool { cache != nil }
    public var portableGuideMappings: [String: LiveTVPortableGuideMapping] {
        guard catalogIsAuthorized() else { return [:] }
        var result: [String: LiveTVPortableGuideMapping] = [:]
        for (channelID, override) in mappingOverrides {
            guard let sourceID = playlistSourceIDByChannel[channelID],
                  let source = configuration.playlists.first(where: { $0.id == sourceID && $0.isEnabled }) else { continue }
            let candidates = guideSources.filter {
                $0.playlistSourceID == sourceID && $0.id == override.guideSourceID
                    && enabledSourceIDs.contains($0.id)
            }
            guard candidates.count == 1,
                  cachedGuides[candidates[0].id]?.guideChannels[override.guideChannelID] != nil else { continue }
            let mapping = LiveTVPortableGuideMapping(
                guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: candidates[0].source.url),
                guideChannelID: override.guideChannelID
            )
            if mapping.isSafe { result[channelID] = mapping }
        }
        return result
    }
    public var portableIdentityHints: [String: LiveTVPortableChannelIdentityHint] {
        _ = catalogRevision
        guard catalogIsAuthorized() else { return [:] }
        var result: [String: LiveTVPortableChannelIdentityHint] = [:]
        for (sourceID, playlist) in cachedPlaylists {
            let hints = playlist.channels.compactMap { channel -> (String, LiveTVPortableChannelIdentityHint)? in
                guard let nativeID = LiveTVChannelIdentity.portableNativeID(for: channel) else { return nil }
                let hint = LiveTVPortableChannelIdentityHint(sourceID: sourceID, nativeID: nativeID)
                return hint.isSafe ? (channel.id, hint) : nil
            }
            let counts = Dictionary(grouping: hints, by: { $0.1.nativeID }).mapValues(\.count)
            for (id, hint) in hints where counts[hint.nativeID] == 1 { result[id] = hint }
        }
        return result
    }

    @discardableResult
    public func applyPortableGuideState(
        mappings: [String: LiveTVPortableGuideMapping?],
        identityHints: [String: LiveTVPortableChannelIdentityHint?],
        into model: LiveTVPrototypeModel
    ) async throws -> Set<String> {
        guard ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        guard let cache else { throw LiveTVSourceImportError.cacheFailed }
        let request = revision
        try await cache.applyPortableIdentityHints(identityHints)
        guard request == revision, ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        let applied = try await cache.applyPortableGuideMappings(mappings, configuration: configuration)
        let overrides = try await cache.mappingOverrides()
        guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else {
            throw CancellationError()
        }
        replaceMappingOverrides(overrides)
        try publishGuides(into: model)
        await reload(into: model)
        return applied
    }

    @ObservationIgnored private let loader: any LiveTVSourceLoading
    @ObservationIgnored private let cache: LiveTVIndexedCache?
    @ObservationIgnored private let catalogIsAuthorized: @MainActor () -> Bool
    @ObservationIgnored public var beforeCatalogPublication:
        (@MainActor (LiveTVSourcesConfiguration, [LiveTVPrototypeChannel]) -> Void)?
    @ObservationIgnored public var beforeSourceRefresh: (@MainActor (Set<String>) -> Void)?
    @ObservationIgnored public var generatedProgramLoader: LiveTVGeneratedProgramLoader?
    @ObservationIgnored private var cachedGuideWindows: [String: [LiveTVPrototypeProgram]] = [:]
    @ObservationIgnored private var windowRevision = 0
    @ObservationIgnored private var requestedGuideWindow: (channelIDs: [String], range: DateInterval)?
    @ObservationIgnored private weak var publishedModel: LiveTVPrototypeModel?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var cachedGuides: [String: LiveTVGuideImport] = [:]
    @ObservationIgnored private var cachedPlaylists: [String: LiveTVPlaylistImport] = [:]
    @ObservationIgnored private var disabledGuideIDs: Set<String> = []
    @ObservationIgnored private var legacySourceID: String?
    @ObservationIgnored private var sourceChannels: [LiveTVPrototypeChannel] = []
    @ObservationIgnored private var generatedChannels: [LiveTVPrototypeChannel] = []
    @ObservationIgnored private var generatedPrograms: [LiveTVPrototypeProgram] = []
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored var serverRevision = 0
    @ObservationIgnored var serverSourceRevisions: [String: Int] = [:]
    @ObservationIgnored var cachedServerCatalogs: [String: LiveTVServerCatalog] = [:]
    @ObservationIgnored var serverProviderResolver: LiveTVServerProviderResolver = { _ in nil }
    @ObservationIgnored var activeServerGuideRequests: Set<UUID> = []

    public var isLoading: Bool {
        playlistPhase == .loading || guidePhase == .loading
            || serverSources.contains { $0.phase == .loading || $0.guidePhase == .loading }
    }
    public var catalogPhase: LiveTVImportPhase {
        let phases = playlistSources.filter(\.source.isEnabled).map(\.phase)
            + serverSources.filter(\.source.isEnabled).map(\.phase)
        if phases.contains(.loading) { return .loading }
        if phases.contains(.loaded) { return .loaded }
        if phases.contains(.failed) { return .failed }
        return .idle
    }
    public var failedSourceCount: Int {
        guideSources.filter { enabledSourceIDs.contains($0.id) && $0.phase == .failed }.count
    }
    public var completedSourceCount: Int {
        guideSources.filter {
            enabledSourceIDs.contains($0.id) && ($0.phase == .loaded || $0.phase == .failed)
        }.count
    }

    public init(
        configuration: LiveTVSourcesConfiguration = .empty,
        loader: any LiveTVSourceLoading = LiveTVSourceLoader(),
        serverProviderResolver: @escaping LiveTVServerProviderResolver = { _ in nil },
        cache: LiveTVIndexedCache? = nil,
        catalogIsAuthorized: @escaping @MainActor () -> Bool = { true },
        generatedProgramLoader: LiveTVGeneratedProgramLoader? = nil
    ) {
        self.configuration = configuration
        playlistSources = configuration.playlists.map { LiveTVPlaylistSourceStatus(source: $0) }
        serverSources = configuration.servers.map { LiveTVServerSourceStatus(source: $0) }
        let sources = configuration.playlists.flatMap { playlist in
            LiveTVConfiguredSources.guides(for: playlist).map {
                LiveTVGuideSourceStatus(source: $0, playlistSourceID: playlist.id)
            }
        }
        guideSources = sources
        let enabledPlaylists = Set(configuration.playlists.filter(\.isEnabled).map(\.id))
        enabledSourceIDs = Set(sources.filter { enabledPlaylists.contains($0.playlistSourceID) }.map(\.id))
        self.loader = loader
        self.serverProviderResolver = serverProviderResolver
        self.cache = cache
        self.catalogIsAuthorized = catalogIsAuthorized
        self.generatedProgramLoader = generatedProgramLoader
    }

    /// Legacy fixture/prototype initializer. Production must pass explicit profile configuration.
    public init(
        playlistURL: URL,
        guideURL: URL? = nil,
        sources: [LiveTVGuideSource] = [],
        loader: any LiveTVSourceLoading = LiveTVSourceLoader()
    ) {
        let sources = guideURL.map {
            [LiveTVGuideSource(id: "guide", name: "XMLTV", url: $0, provider: LiveTVGuideSource.provider(for: $0))]
        } ?? sources
        precondition(Set(sources.map(\.id)).count == sources.count, "Guide source IDs must be unique.")
        let playlist = LiveTVPlaylistSource(
            id: "prototype", name: "IPTV", playlistURL: playlistURL,
            guideURLs: sources.map(\.url), guideSourceIDs: sources.map(\.id)
        )
        configuration = LiveTVSourcesConfiguration(playlists: [playlist])
        playlistSources = [LiveTVPlaylistSourceStatus(source: playlist)]
        legacySourceID = playlist.id
        guideSources = sources.map { LiveTVGuideSourceStatus(source: $0, playlistSourceID: playlist.id) }
        enabledSourceIDs = Set(sources.map(\.id))
        self.loader = loader
        self.cache = nil
        self.catalogIsAuthorized = { true }
    }

    public func applyConfiguration(
        _ configuration: LiveTVSourcesConfiguration, into model: LiveTVPrototypeModel
    ) throws {
        try configuration.validate()
        guard ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        guard self.configuration != configuration || legacySourceID != nil
            || (configuration.playlists.allSatisfy({ !$0.isEnabled })
                && configuration.servers.allSatisfy({ !$0.isEnabled })) else { return }
        let oldSources = Dictionary(self.configuration.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newSources = Dictionary(uniqueKeysWithValues: configuration.playlists.map { ($0.id, $0) })
        let changedSourceIDs = Set(oldSources.keys).union(newSources.keys).filter { oldSources[$0] != newSources[$0] }
        let oldServers = Dictionary(self.configuration.servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newServers = Dictionary(uniqueKeysWithValues: configuration.servers.map { ($0.id, $0) })
        let changedServerIDs = Set(oldServers.keys).union(newServers.keys).filter { oldServers[$0] != newServers[$0] }
        beforeSourceRefresh?(Set(changedSourceIDs).union(changedServerIDs))
        reloadGeneration &+= 1
        applyServerConfiguration(configuration.servers)
        let enabledConfiguredIDs = Set(
            configuration.playlists.filter(\.isEnabled).map(\.id)
                + configuration.servers.filter(\.isEnabled).map(\.id)
        )
        if let selected = model.configuredSourceID, !enabledConfiguredIDs.contains(selected) {
            model.configuredSourceID = nil
        }
        if self.configuration.playlists == configuration.playlists, legacySourceID == nil {
            self.configuration = configuration
            try publishPlaylists(into: model)
            return
        }
        revision &+= 1
        let previousPlaylists = playlistSources.reduce(into: [String: LiveTVPlaylistSourceStatus]()) {
            $0[$1.id] = $1
        }
        let previousGuides = guideSources.reduce(into: [String: LiveTVGuideSourceStatus]()) {
            $0[$1.id] = $1
        }
        let retainedIDs = Set(configuration.playlists.filter {
            $0.isEnabled && previousPlaylists[$0.id]?.source.playlistURL == $0.playlistURL
                && $0.id != legacySourceID
        }.map(\.id))
        let retainedGuideOwnerIDs = Set(configuration.playlists.filter {
            retainedIDs.contains($0.id)
                && previousPlaylists[$0.id]?.source.guideLookbackDays == $0.guideLookbackDays
                && previousPlaylists[$0.id]?.source.guideLookaheadDays == $0.guideLookaheadDays
        }.map(\.id))
        cachedPlaylists = cachedPlaylists.filter { retainedIDs.contains($0.key) }
        identityReviews = identityReviews.filter { retainedIDs.contains($0.key) }
        guideDiscoveryFailures = guideDiscoveryFailures.filter { retainedIDs.contains($0.key) }
        self.configuration = configuration
        legacySourceID = nil
        playlistSources = configuration.playlists.map { source in
            var status = LiveTVPlaylistSourceStatus(source: source)
            if retainedIDs.contains(source.id), let previous = previousPlaylists[source.id] {
                status.phase = previous.phase == .loading ? .idle : previous.phase
                status.failure = previous.failure
                status.entryCount = previous.entryCount
                status.skippedEntryCount = previous.skippedEntryCount
                status.channelCount = previous.channelCount
                status.lastRefresh = previous.lastRefresh
            }
            return status
        }
        guideSources = configuration.playlists.flatMap { playlist in
            LiveTVConfiguredSources.guides(for: playlist).map { source in
                var status = LiveTVGuideSourceStatus(source: source, playlistSourceID: playlist.id)
                if retainedGuideOwnerIDs.contains(playlist.id), let previous = previousGuides[source.id],
                   previous.source.url == source.url {
                    status.phase = previous.phase == .loading ? .idle : previous.phase
                    status.failure = previous.failure
                    status.matchedChannelCount = previous.matchedChannelCount
                    status.programCount = previous.programCount
                    status.lastRefresh = previous.lastRefresh
                }
                return status
            }
        }
        let enabledPlaylists = Set(configuration.playlists.filter(\.isEnabled).map(\.id))
        disabledGuideIDs.formIntersection(Set(guideSources.map(\.id)))
        enabledSourceIDs = Set(guideSources.filter {
            enabledPlaylists.contains($0.playlistSourceID) && !disabledGuideIDs.contains($0.id)
        }.map(\.id))
        let retainedGuides = Set(guideSources.filter {
            retainedGuideOwnerIDs.contains($0.playlistSourceID) && enabledSourceIDs.contains($0.id)
                && previousGuides[$0.id]?.source.url == $0.source.url
        }.map(\.id))
        cachedGuides = cachedGuides.filter { retainedGuides.contains($0.key) }
        cachedGuideWindows = cachedGuideWindows.filter { retainedGuides.contains($0.key) }
        lastGuideRefresh = guideSources.filter { cachedGuides[$0.id] != nil }.compactMap(\.lastRefresh).max()
        playlistFailure = nil
        guideFailure = nil
        try publishPlaylists(into: model)
        updatePhases()
    }

    public func setPlaylistEnabled(
        _ sourceID: String, enabled: Bool, into model: LiveTVPrototypeModel
    ) throws {
        guard let index = configuration.playlists.firstIndex(where: { $0.id == sourceID }) else {
            throw LiveTVSourcesValidationError.invalidSourceID
        }
        var updated = configuration
        updated.playlists[index].isEnabled = enabled
        try applyConfiguration(updated, into: model)
    }

    public func setSourceEnabled(_ sourceID: String, enabled: Bool, into model: LiveTVPrototypeModel) throws {
        guard let source = guideSources.first(where: { $0.id == sourceID }),
              !enabled || configuration.playlists.contains(where: { $0.id == source.playlistSourceID && $0.isEnabled })
        else {
            throw LiveTVSourceImportError.invalidGuide
        }
        guard enabledSourceIDs.contains(sourceID) != enabled else { return }
        if enabled {
            enabledSourceIDs.insert(sourceID)
            disabledGuideIDs.remove(sourceID)
        }
        else {
            enabledSourceIDs.remove(sourceID)
            disabledGuideIDs.insert(sourceID)
            cachedGuides.removeValue(forKey: sourceID)
        }
        // Fence in-flight results immediately, before SwiftUI starts the replacement task.
        revision &+= 1
        for index in playlistSources.indices where playlistSources[index].phase == .loading {
            playlistSources[index].phase = .idle
        }
        if playlistPhase == .loading { playlistPhase = .idle }
        for index in guideSources.indices where guideSources[index].phase == .loading {
            guideSources[index].phase = .idle
        }
        guidePhase = enabledSourceIDs.isEmpty ? .idle : .loading
        try publishGuides(into: model)
    }

    public func gapState(for channel: LiveTVPrototypeChannel) -> LiveTVGuideGapState {
        if let reference = serverChannelReferences[channel.id],
           let status = serverSources.first(where: { $0.id == reference.sourceID }) {
            if status.phase == .loading { return .loading }
            if status.failure != nil || status.guideFailure == .permissionDenied { return .failed }
            if status.availability?.supportsGuide == false { return .disabled }
            guard let window = serverGuideWindows.last(where: {
                $0.sourceID == reference.sourceID && $0.channelIDs.contains(channel.id)
            }) else { return .unrequested }
            return serverGuideState(channelID: channel.id, from: window.from, to: window.to)
        }
        let owner = playlistSourceIDByChannel[channel.id]
        let enabledGuides = guideSources.filter {
            enabledSourceIDs.contains($0.id) && (owner == nil || $0.playlistSourceID == owner)
        }
        if enabledGuides.isEmpty { return .disabled }
        if selectedSourceByChannel[channel.id] != nil { return .noListings }
        if playlistPhase == .idle || playlistPhase == .loading || guidePhase == .loading { return .loading }
        let provider = LiveTVStreamIdentity(url: channel.streamURL).provider
        let relevant = enabledGuides.filter { $0.source.provider == provider }
        if relevant.contains(where: { $0.phase == .failed }) { return .failed }
        return .unmatched
    }

    public func reload(into model: LiveTVPrototypeModel) async {
        publishedModel = model
        guard ensureCatalogAuthorization(into: model) else { return }
        beforeSourceRefresh?(Set(
            configuration.playlists.filter(\.isEnabled).map(\.id)
                + configuration.servers.filter(\.isEnabled).map(\.id)
        ))
        reloadGeneration &+= 1
        let request = reloadGeneration
        await restoreCachedCatalog(into: model, now: model.now)
        guard request == reloadGeneration, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
        await reloadPlaylists(into: model)
        guard request == reloadGeneration, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
        await reloadServers(into: model)
    }

    private func reloadPlaylists(into model: LiveTVPrototypeModel) async {
        revision &+= 1
        let request = revision
        do {
            try configuration.validate()
        } catch {
            playlistPhase = .failed
            playlistFailure = .invalidPlaylist
            guidePhase = .idle
            return
        }
        let enabledPlaylists = playlistSources.filter { $0.source.isEnabled }
        guard !enabledPlaylists.isEmpty else {
            cachedPlaylists = [:]
            cachedGuides = [:]
            playlistFailure = nil
            guideFailure = nil
            lastGuideRefresh = nil
            do { try publishPlaylists(into: model) }
            catch { playlistFailure = .invalidPlaylist }
            playlistPhase = .idle
            guidePhase = .idle
            return
        }
        guidePhase = enabledSourceIDs.isEmpty ? .idle : .loading
        for index in guideSources.indices where guideSources[index].phase == .loading {
            guideSources[index].phase = .idle
        }
        playlistPhase = .loading
        playlistFailure = nil
        guideFailure = nil
        for index in playlistSources.indices {
            playlistSources[index].phase = .idle
            playlistSources[index].failure = nil
        }
        for index in playlistSources.indices where playlistSources[index].source.isEnabled {
            guard revision == request, ensureCatalogAuthorization(into: model) else { return }
            let source = playlistSources[index].source
            playlistSources[index].phase = .loading
            do {
                try Task.checkCancellation()
                let imported: LiveTVPlaylistImport
                if let importedID = source.importedPlaylistID {
                    guard let cache else { throw LiveTVSourceImportError.cacheFailed }
                    imported = try await cache.importedPlaylist(id: importedID)
                } else {
                    imported = try await loader.loadPlaylist(from: source.playlistURL)
                }
                try Task.checkCancellation()
                guard revision == request, ensureCatalogAuthorization(into: model) else { return }
                let playlist: LiveTVPlaylistImport
                if let cache, source.id != legacySourceID {
                    let resolution = try await cache.reconcile(imported, sourceID: source.id)
                    let updatedMappings = try await cache.mappingOverrides()
                    guard revision == request, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                    replaceMappingOverrides(updatedMappings)
                    guard model.migrateChannelIDs(resolution.migratedIDs) else {
                        throw LiveTVSourceImportError.cacheFailed
                    }
                    migrateGuideWindowChannelIDs(resolution.migratedIDs)
                    playlist = resolution.playlist
                    identityReviews[source.id] = resolution.reviews
                    try await cache.storePlaylist(playlist, source: source, now: Date())
                    guard revision == request, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                } else {
                    playlist = source.id == legacySourceID ? imported : LiveTVConfiguredSources.scope(
                        imported, to: source.id, preservesChannelIDs: preservesChannelIDs(for: source.id)
                    )
                }
                let previous = cachedPlaylists[source.id]
                cachedPlaylists[source.id] = playlist
                do {
                    try publishPlaylists(into: model)
                } catch {
                    cachedPlaylists[source.id] = previous
                    throw error
                }
                playlistSources[index].entryCount = playlist.entryCount
                playlistSources[index].skippedEntryCount = playlist.skippedEntryCount
                playlistSources[index].channelCount = playlist.channels.count
                playlistSources[index].lastRefresh = Date()
                playlistSources[index].phase = .loaded
                try await discoverGuides(in: playlist, source: source)
            } catch {
                guard revision == request else { return }
                if isCancellation(error) {
                    playlistSources[index].phase = .idle
                    playlistPhase = .idle
                    guidePhase = .idle
                    return
                }
                let failure = error as? LiveTVSourceImportError ?? (cache == nil ? .invalidPlaylist : .cacheFailed)
                playlistSources[index].failure = failure
                playlistSources[index].phase = .failed
                playlistFailure = failure
            }
        }
        playlistPhase = playlistSources.contains { $0.source.isEnabled && $0.phase == .loaded }
            ? .loaded : .failed

        let loadedPlaylists = Set(playlistSources.filter { $0.source.isEnabled && cachedPlaylists[$0.id] != nil }.map(\.id))
        for index in guideSources.indices {
            guideSources[index].phase = cachedGuides[guideSources[index].id] == nil ? .idle : .loaded
            guideSources[index].failure = nil
        }
        let now = model.now
        for index in guideSources.indices where enabledSourceIDs.contains(guideSources[index].id)
            && loadedPlaylists.contains(guideSources[index].playlistSourceID) {
            guard revision == request, ensureCatalogAuthorization(into: model) else { return }
            let source = guideSources[index].source
            let owner = guideSources[index].playlistSourceID
            let channels = cachedPlaylists[owner]?.channels ?? []
            guideSources[index].phase = .loading
            do {
                try Task.checkCancellation()
                let imported: LiveTVGuideImport
                if let cache, let indexedLoader = loader as? any LiveTVIndexedSourceLoading {
                    let settings = configuration.playlists.first { $0.id == owner }
                    imported = try await indexedLoader.loadIndexedGuide(
                        from: source.url, sourceID: source.id, channels: channels, now: now,
                        cache: cache, lookbackDays: settings?.guideLookbackDays ?? 1,
                        lookaheadDays: settings?.guideLookaheadDays ?? 7
                    )
                } else {
                    imported = try await loader.loadGuide(from: source.url, channels: channels, now: now)
                }
                try Task.checkCancellation()
                guard revision == request, ensureCatalogAuthorization(into: model) else { return }
                let guide = preservesChannelIDs(for: owner)
                    ? imported : LiveTVConfiguredSources.scope(imported, to: owner)
                let previous = cachedGuides[source.id]
                let previousWindow = cachedGuideWindows[source.id]
                cachedGuides[source.id] = guide
                do {
                    try validateCacheBudget()
                    if let cache, guide.programs.isEmpty {
                        let window = requestedGuideWindow ?? (
                            channelIDs: Array(model.visibleChannels.prefix(LiveTVIndexedCache.maximumWindowChannels).map(\.id)),
                            range: DateInterval(start: model.now, duration: 3 * 3_600)
                        )
                        let windowRequest = windowRevision
                        let programs = try await cache.programs(
                            sourceID: source.id,
                            channelIDs: window.channelIDs.filter { playlistSourceIDByChannel[$0] == owner },
                            range: window.range, sourceURL: source.url
                        )
                        guard revision == request, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                        if windowRevision == windowRequest { cachedGuideWindows[source.id] = programs }
                    } else {
                        cachedGuideWindows[source.id] = nil
                    }
                    try publishGuides(into: model)
                } catch {
                    cachedGuides[source.id] = previous
                    cachedGuideWindows[source.id] = previousWindow
                    throw error
                }
                guideSources[index].matchedChannelCount = guide.matchedChannelCount
                guideSources[index].programCount = guide.programCount
                guideSources[index].lastRefresh = Date()
                guideSources[index].phase = .loaded
                lastGuideRefresh = guideSources[index].lastRefresh
            } catch {
                guard revision == request else { return }
                if isCancellation(error) {
                    guideSources[index].phase = .idle
                    guidePhase = .idle
                    return
                }
                let failure = error as? LiveTVSourceImportError ?? (cache == nil ? .invalidGuide : .cacheFailed)
                guideSources[index].failure = failure
                guideSources[index].phase = .failed
                guideFailure = failure
            }
        }
        updateGuidePhase()
        if cache != nil {
            let window = requestedGuideWindow ?? (
                channelIDs: Array(model.visibleChannels.prefix(LiveTVIndexedCache.maximumWindowChannels).map(\.id)),
                range: DateInterval(start: model.now, duration: 3 * 3_600)
            )
            await loadGuideWindow(
                channelIDs: window.channelIDs, range: window.range, into: model
            )
        }
    }

    private func preservesChannelIDs(for sourceID: String) -> Bool {
        sourceID == legacySourceID || sourceID == "free-us"
    }

    func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? LiveTVSourceImportError) == .cancelled
    }

    private func updatePhases() {
        let enabled = playlistSources.filter { $0.source.isEnabled }
        if enabled.contains(where: { $0.phase == .loaded }) { playlistPhase = .loaded }
        else if !enabled.isEmpty, enabled.allSatisfy({ $0.phase == .failed }) { playlistPhase = .failed }
        else { playlistPhase = .idle }
        updateGuidePhase()
    }

    private func updateGuidePhase() {
        let enabled = guideSources.filter { enabledSourceIDs.contains($0.id) }
        if enabled.contains(where: { $0.phase == .loaded }) { guidePhase = .loaded }
        else if enabled.contains(where: { $0.phase == .failed }) { guidePhase = .failed }
        else { guidePhase = .idle }
    }

    func publishPlaylists(into model: LiveTVPrototypeModel) throws {
        publishedModel = model
        let playlists = playlistSources.filter(\.source.isEnabled).compactMap { status in
            cachedPlaylists[status.id].map { (status.id, $0) }
        }
        let servers = serverSources.filter(\.source.isEnabled).compactMap { cachedServerCatalogs[$0.id] }
        guard playlists.reduce(0, { $0 + $1.1.channels.count }) + servers.reduce(0, { $0 + $1.channels.count })
            + generatedChannels.count
            <= LiveTVPlaylistParser.maximumEntries else {
            throw LiveTVSourceImportError.responseTooLarge
        }
        let channels = playlists.flatMap { $0.1.channels } + servers.flatMap(\.channels) + generatedChannels
        guard Set(channels.map(\.id)).count == channels.count else { throw LiveTVPrototypeDataError.duplicateChannelID }
        let previousChannels = sourceChannels
        let previousPlaylistReferences = playlistSourceIDByChannel
        let previousServerReferences = serverChannelReferences
        let previousConfiguredReferences = configuredSourceIDByChannel
        sourceChannels = channels
        playlistSourceIDByChannel = Dictionary(uniqueKeysWithValues: playlists.flatMap { sourceID, playlist in
            playlist.channels.map { ($0.id, sourceID) }
        })
        serverChannelReferences = servers.reduce(into: [:]) { result, catalog in
            result.merge(catalog.references) { current, _ in current }
        }
        configuredSourceIDByChannel = playlistSourceIDByChannel.merging(
            serverChannelReferences.mapValues(\.sourceID)
        ) { current, _ in current }
        for channel in generatedChannels { configuredSourceIDByChannel[channel.id] = channel.configuredSourceID }
        do {
            try publishGuides(into: model)
        } catch {
            if catalogIsAuthorized() {
                sourceChannels = previousChannels
                playlistSourceIDByChannel = previousPlaylistReferences
                serverChannelReferences = previousServerReferences
                configuredSourceIDByChannel = previousConfiguredReferences
            }
            throw error
        }
    }

    private func publishGuides(into model: LiveTVPrototypeModel) throws {
        guard ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        let channelIDs = Set(sourceChannels.map(\.id))
        var chosen: [String: (
            sourceID: String, method: LiveTVGuideMatchMethod,
            programs: [LiveTVPrototypeProgram], hasUpcomingListings: Bool
        )] = [:]
        var channelCount = 0
        let localGuideIDsByPlaylist = Dictionary(grouping: guideSources, by: \.playlistSourceID)
            .mapValues { Set($0.map(\.id)) }
        for status in guideSources where enabledSourceIDs.contains(status.id) {
            guard let guide = cachedGuides[status.id] else { continue }
            channelCount += guide.guideChannelCount
            let grouped = Dictionary(grouping: cachedGuideWindows[status.id] ?? guide.programs, by: \.channelID)
            let ownedChannelIDs = channelIDs.filter { playlistSourceIDByChannel[$0] == status.playlistSourceID }
            let matchedIDs = Set(guide.matches.keys).union(grouped.keys).intersection(ownedChannelIDs)
            for channelID in matchedIDs {
                if let manual = mappingOverrides[channelID],
                   localGuideIDsByPlaylist[status.playlistSourceID]?.contains(manual.guideSourceID) == true {
                    guard manual.guideSourceID == status.id,
                          guide.matches[channelID]?.guideChannelID == manual.guideChannelID else { continue }
                }
                let method = guide.matches[channelID]?.method ?? .displayName
                let programs = grouped[channelID] ?? []
                let upcoming = programs.contains { $0.end > model.now }
                // Explicit guide order is priority; a lower priority feed fills only an
                // entirely empty interval. Never interleave two feeds' programme intervals.
                if let existing = chosen[channelID] {
                    if existing.method == .userConfirmed || (method != .userConfirmed
                        && (existing.hasUpcomingListings || !upcoming)) { continue }
                }
                chosen[channelID] = (status.id, method, programs, upcoming)
            }
        }
        let nativePrograms = serverSources.filter(\.source.isEnabled)
            .compactMap { cachedServerCatalogs[$0.id] }.flatMap(\.programs) + generatedPrograms
        let programs = chosen.values.flatMap(\.programs) + nativePrograms
        guard programs.count <= LiveTVXMLTVParser.maximumRetainedPrograms else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        guard Set(programs.map(\.id)).count == programs.count, programs.allSatisfy({
            channelIDs.contains($0.channelID) && $0.start.timeIntervalSince1970.isFinite
                && $0.end.timeIntervalSince1970.isFinite && $0.start < $0.end
        }) else { throw LiveTVPrototypeDataError.invalidProgram }
        beforeCatalogPublication?(configuration, sourceChannels)
        guard ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        try model.replaceCatalog(channels: sourceChannels, programs: programs)
        model.setKnownGuideChannels(
            Set(chosen.keys).union(nativePrograms.map(\.channelID)).union(generatedChannels.map(\.id))
        )
        selectedSourceByChannel = chosen.mapValues(\.sourceID)
        guideChannelCount = channelCount
        matchedChannelCount = chosen.count + Set(nativePrograms.map(\.channelID)).count
        programCount = programs.count
        let activeGuides = guideSources.filter { enabledSourceIDs.contains($0.id) }.compactMap { cachedGuides[$0.id] }
        coverageStart = (activeGuides.compactMap(\.coverageStart) + nativePrograms.map(\.start)).min()
        coverageEnd = (activeGuides.compactMap(\.coverageEnd) + nativePrograms.map(\.end)).max()
        catalogRevision &+= 1
    }

    public func restoreCachedCatalog(into model: LiveTVPrototypeModel, now: Date = Date()) async {
        publishedModel = model
        guard ensureCatalogAuthorization(into: model), let cache else { return }
        do {
            try configuration.validate()
        } catch {
            cacheFailure = .cacheFailed
            return
        }
        cacheFailure = nil
        let allowedSources = Dictionary(uniqueKeysWithValues: configuration.playlists
            .filter(\.isEnabled).map { ($0.id, $0) })
        cachedPlaylists = cachedPlaylists.filter { allowedSources[$0.key] != nil }
        let allowedGuideIDs = Set(guideSources.filter {
            allowedSources[$0.playlistSourceID] != nil && enabledSourceIDs.contains($0.id)
        }.map(\.id))
        cachedGuides = cachedGuides.filter { allowedGuideIDs.contains($0.key) }
        cachedGuideWindows = cachedGuideWindows.filter { allowedGuideIDs.contains($0.key) }
        let request = revision
        do {
            let overrides = try await cache.mappingOverrides()
            guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
            replaceMappingOverrides(overrides)
            for source in configuration.playlists where source.isEnabled && cachedPlaylists[source.id] == nil {
                guard request == revision, ensureCatalogAuthorization(into: model) else { return }
                let playlist = try await cache.playlist(source: source)
                let freshness = try await cache.freshness(kind: "playlist", sourceID: source.id)
                guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                guard let playlist else { continue }
                let reviews = try await cache.identityReviews(for: playlist, sourceID: source.id)
                guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                cachedPlaylists[source.id] = playlist
                identityReviews[source.id] = reviews
                if let index = playlistSources.firstIndex(where: { $0.id == source.id }) {
                    playlistSources[index].phase = .loaded
                    playlistSources[index].entryCount = playlist.entryCount
                    playlistSources[index].skippedEntryCount = playlist.skippedEntryCount
                    playlistSources[index].channelCount = playlist.channels.count
                    playlistSources[index].lastRefresh = freshness?.refreshedAt
                }
            }
            for source in configuration.playlists where source.isEnabled {
                guard request == revision, ensureCatalogAuthorization(into: model) else { return }
                guard let playlist = cachedPlaylists[source.id] else { continue }
                let configuredIDs = Set(LiveTVConfiguredSources.guides(for: source).map(\.id))
                if !guideSources.contains(where: {
                    $0.playlistSourceID == source.id && !configuredIDs.contains($0.id)
                }) {
                    try await discoverGuides(in: playlist, source: source)
                }
            }
            for status in guideSources where enabledSourceIDs.contains(status.id) && cachedGuides[status.id] == nil {
                guard request == revision, ensureCatalogAuthorization(into: model) else { return }
                guard let source = allowedSources[status.playlistSourceID],
                      cachedPlaylists[source.id] != nil else { continue }
                let guide = try await cache.guide(
                    sourceID: status.id, sourceURL: status.source.url, provider: status.source.provider,
                    lookbackDays: source.guideLookbackDays, lookaheadDays: source.guideLookaheadDays
                )
                let freshness = try await cache.freshness(kind: "guide", sourceID: status.id)
                guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else { return }
                guard let guide else { continue }
                cachedGuides[status.id] = guide
                if let index = guideSources.firstIndex(where: { $0.id == status.id }) {
                    guideSources[index].phase = .loaded
                    guideSources[index].programCount = guide.programCount
                    guideSources[index].matchedChannelCount = guide.matchedChannelCount
                    guideSources[index].lastRefresh = freshness?.refreshedAt
                }
            }
            try publishPlaylists(into: model)
            let window = requestedGuideWindow ?? (
                channelIDs: Array(model.visibleChannels.prefix(LiveTVIndexedCache.maximumWindowChannels).map(\.id)),
                range: DateInterval(start: now, duration: 3 * 3_600)
            )
            await loadGuideWindow(
                channelIDs: window.channelIDs, range: window.range, into: model
            )
            updatePhases()
        } catch {
            if !isCancellation(error) { cacheFailure = .cacheFailed }
        }
    }

    private func migrateGuideWindowChannelIDs(_ migration: [String: String]) {
        guard !migration.isEmpty, let window = requestedGuideWindow else { return }
        var seen: Set<String> = []
        let channelIDs = window.channelIDs.map { migration[$0] ?? $0 }
            .filter { seen.insert($0).inserted }
        guard channelIDs != window.channelIDs else { return }
        // Retain the user's scrolled time range, but fence requests still using
        // retired channel IDs before publishing the reconciled catalog.
        windowRevision &+= 1
        requestedGuideWindow = (channelIDs, window.range)
    }

    public func loadGuideWindow(
        channelIDs: [String], range: DateInterval, into model: LiveTVPrototypeModel
    ) async {
        guard ensureCatalogAuthorization(into: model), let cache, !channelIDs.isEmpty else { return }
        windowRevision &+= 1
        requestedGuideWindow = (channelIDs, range)
        let windowRequest = windowRevision
        let catalogRequest = revision
        do {
            var windows: [String: [LiveTVPrototypeProgram]] = [:]
            for status in guideSources where enabledSourceIDs.contains(status.id) {
                guard cachedGuides[status.id] != nil, cachedPlaylists[status.playlistSourceID] != nil else { continue }
                let owned = channelIDs.filter { playlistSourceIDByChannel[$0] == status.playlistSourceID }
                if let inMemory = cachedGuides[status.id]?.programs, !inMemory.isEmpty {
                    let ids = Set(owned)
                    windows[status.id] = inMemory.filter {
                        ids.contains($0.channelID) && $0.start < range.end && $0.end > range.start
                    }
                } else {
                    windows[status.id] = try await cache.programs(
                        sourceID: status.id, channelIDs: owned, range: range, sourceURL: status.source.url
                    )
                }
                guard windowRequest == windowRevision, catalogRequest == revision, !Task.isCancelled,
                      ensureCatalogAuthorization(into: model) else { return }
            }
            cachedGuideWindows = windows
            try publishGuides(into: model)
            cacheFailure = nil
        } catch {
            if !isCancellation(error) { cacheFailure = .cacheFailed }
        }
    }

    public func searchPrograms(
        query: String, range: DateInterval, limit: Int = 100,
        allowedChannelIDs: Set<String>? = nil, catalog: LiveTVPrototypeModel? = nil
    ) async throws -> [LiveTVPrototypeProgram] {
        guard catalogIsAuthorized() else { throw CancellationError() }
        let matcher = LiveTVProgramSearchMatcher(query)
        guard limit > 0, !matcher.tokens.isEmpty else { return [] }
        guard range.duration > 0, range.duration <= 32 * 86_400,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite else {
            throw LiveTVCacheError.invalidRange
        }
        let request = revision
        let searchRevision = catalogRevision
        let catalog = catalog ?? publishedModel
        let modelRevision = catalog?.catalogRevision
        let known = Set((catalog?.channels ?? sourceChannels).map(\.id))
        let eligible = catalog?.programmeSearchChannelIDs ?? known
        let allowed = (allowedChannelIDs ?? eligible).intersection(known).intersection(eligible)
        guard !allowed.isEmpty else { return [] }
        var results = LiveTVProgramSearchResults(limit: limit)
        let generatedIDs = Set((catalog?.channels ?? sourceChannels).filter { $0.source == .plozz }.map(\.id))
        let requestedGeneratedIDs = allowed.intersection(generatedIDs)
        let cachedNativeIDs = generatedProgramLoader == nil ? allowed : allowed.subtracting(generatedIDs)
        if let catalog {
            for program in catalog.cachedNativePrograms(
                matching: matcher, range: range, limit: limit, allowedChannelIDs: cachedNativeIDs
            ) {
                results.insert(program)
            }
        }
        func matches(_ program: LiveTVPrototypeProgram) -> Bool {
            allowed.contains(program.channelID) && program.start < range.end && program.end > range.start
                && matcher.matches(program.title)
        }
        for (source, guide) in cachedGuides where enabledSourceIDs.contains(source) {
            for program in guide.programs where
                selectedSourceByChannel[program.channelID] == source && matches(program) {
                results.insert(program)
            }
        }
        for status in serverSources where status.source.isEnabled {
            for program in cachedServerCatalogs[status.id]?.programs ?? [] where matches(program) {
                results.insert(program)
            }
        }
        if let generatedProgramLoader, !requestedGeneratedIDs.isEmpty {
            let programs = try generatedProgramLoader(requestedGeneratedIDs, range)
            guard programs.count <= LiveTVXMLTVParser.maximumRetainedPrograms,
                  programs.allSatisfy({
                      requestedGeneratedIDs.contains($0.channelID)
                          && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                          && $0.start < $0.end
                  }) else { throw LiveTVPrototypeDataError.invalidProgram }
            for program in programs where matches(program) { results.insert(program) }
        } else if generatedProgramLoader == nil {
            for program in generatedPrograms where matches(program) { results.insert(program) }
        }
        if let cache {
            let indexed = try await cache.searchPrograms(
                query: query, sourceIDs: enabledSourceIDs, range: range, limit: limit,
                selectedSourceByChannel: selectedSourceByChannel, allowedChannelIDs: allowed,
                sourceURLs: Dictionary(uniqueKeysWithValues: guideSources.filter {
                    enabledSourceIDs.contains($0.id) && cachedPlaylists[$0.playlistSourceID] != nil
                }.map { ($0.id, $0.source.url) })
            )
            for program in indexed { results.insert(program) }
        }
        guard revision == request, searchRevision == catalogRevision, modelRevision == catalog?.catalogRevision,
              !Task.isCancelled, catalogIsAuthorized() else { throw CancellationError() }
        return results.sorted
    }

    public func isProgramSearchResultAvailable(
        _ program: LiveTVPrototypeProgram, catalog: LiveTVPrototypeModel
    ) -> Bool {
        guard catalogIsAuthorized(), !catalog.effectiveHiddenChannelIDs.contains(program.channelID),
              let channel = catalog.channel(id: program.channelID) else { return false }
        guard channel.source == .iptv else { return true }
        guard let source = channel.playlistSourceID,
              configuration.playlists.contains(where: { $0.id == source && $0.isEnabled }),
              let guide = selectedSourceByChannel[channel.id] else { return false }
        return enabledSourceIDs.contains(guide)
    }

    /// Composition supplies only library channels authorized for the active profile.
    /// This keeps playlist/server refreshes from discarding generated schedules.
    public func setGeneratedCatalog(
        channels: [LiveTVPrototypeChannel], programs: [LiveTVPrototypeProgram], into model: LiveTVPrototypeModel
    ) throws {
        guard ensureCatalogAuthorization(into: model) else { throw CancellationError() }
        let ids = Set(channels.map(\.id))
        guard ids.count == channels.count, channels.allSatisfy({ $0.source == .plozz }),
              programs.count <= LiveTVXMLTVParser.maximumRetainedPrograms,
              Set(programs.map(\.id)).count == programs.count,
              programs.allSatisfy({
                  ids.contains($0.channelID) && $0.start.timeIntervalSince1970.isFinite
                      && $0.end.timeIntervalSince1970.isFinite && $0.start < $0.end
              }) else {
            throw LiveTVPrototypeDataError.invalidProgram
        }
        if channels != generatedChannels {
            beforeSourceRefresh?(Set((generatedChannels + channels).compactMap(\.configuredSourceID)))
        }
        let previousChannels = generatedChannels
        let previousPrograms = generatedPrograms
        generatedChannels = channels
        generatedPrograms = programs
        do {
            try publishPlaylists(into: model)
        } catch {
            if catalogIsAuthorized() {
                generatedChannels = previousChannels
                generatedPrograms = previousPrograms
            }
            throw error
        }
    }

    public func importPlaylistFile(
        at url: URL, id: UUID, baseURL: URL? = nil
    ) async throws -> LiveTVPlaylistImport {
        guard let cache else { throw LiveTVSourceImportError.cacheFailed }
        return try await cache.importPlaylistFile(at: url, id: id, baseURL: baseURL)
    }

    public func removeImportedPlaylistFile(id: UUID) async throws {
        guard let cache else { throw LiveTVSourceImportError.cacheFailed }
        try await cache.removeImportedPlaylist(id: id)
    }

    public func mappingChannels(playlistSourceID: String, query: String = "") -> [LiveTVPrototypeChannel] {
        _ = catalogRevision
        guard catalogIsAuthorized() else { return [] }
        return Array(sourceChannels.lazy.filter {
            $0.playlistSourceID == playlistSourceID
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.prefix(200))
    }

    public func identityCandidateName(_ channelID: String) -> String {
        guard catalogIsAuthorized() else { return "Previously saved channel" }
        return publishedModel?.favoriteChannels.first(where: { $0.id == channelID })?.name
            ?? publishedModel?.hiddenChannels.first(where: { $0.id == channelID })?.name
            ?? "Previously saved channel"
    }

    public func confirmIdentity(sourceID: String, channelID: String, previousChannelID: String) async throws {
        guard catalogIsAuthorized(), let cache, let model = publishedModel,
              sourceChannels.contains(where: { $0.id == channelID && $0.playlistSourceID == sourceID }),
              identityReviews[sourceID]?.contains(where: {
                  $0.channelID == channelID && $0.candidateIDs.contains(previousChannelID)
              }) == true, !sourceChannels.contains(where: { $0.id == previousChannelID }) else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        let request = revision
        try await cache.confirmIdentity(sourceID: sourceID, channelID: channelID, previousChannelID: previousChannelID)
        guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else {
            throw CancellationError()
        }
        guard model.migrateChannelIDs([channelID: previousChannelID]) else { throw LiveTVSourceImportError.cacheFailed }
        await reload(into: model)
    }

    public func recoverUnavailableFavorite(previousID: String, channelID: String) async throws {
        guard catalogIsAuthorized(), let cache, let model = publishedModel, model.favoriteIDs.contains(previousID),
              model.channel(id: previousID) == nil, let channel = model.channel(id: channelID),
              let sourceID = playlistSourceIDByChannel[channelID],
              configuration.playlists.contains(where: { $0.id == sourceID && $0.isEnabled }),
              !model.effectiveHiddenChannelIDs.contains(channel.id) else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        let request = revision
        try await cache.associateLegacyID(sourceID: sourceID, channelID: channelID, legacyID: previousID)
        guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else {
            throw CancellationError()
        }
        guard model.migrateChannelIDs([previousID: channelID]) else { throw LiveTVSourceImportError.cacheFailed }
    }

    public func guideChannelOptions(sourceID: String, query: String = "") async throws -> [LiveTVGuideChannelOption] {
        guard catalogIsAuthorized() else { throw CancellationError() }
        let request = revision
        guard guideSources.contains(where: { $0.id == sourceID && enabledSourceIDs.contains(sourceID) }) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        if let cache, let source = guideSources.first(where: { $0.id == sourceID })?.source {
            let indexed = try await cache.guideChannels(sourceID: sourceID, query: query, sourceURL: source.url)
            guard request == revision, !Task.isCancelled, catalogIsAuthorized() else { throw CancellationError() }
            if !indexed.isEmpty { return indexed }
        }
        return Array((cachedGuides[sourceID]?.guideChannels ?? [:]).map {
            LiveTVGuideChannelOption(id: $0.key, name: $0.value.first ?? $0.key)
        }.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.displayID?.localizedCaseInsensitiveContains(query) ?? false)
        }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }.prefix(100))
    }

    public func setGuideMapping(
        channelID: String, guideSourceID: String?, guideChannelID: String?
    ) async throws {
        guard catalogIsAuthorized() else { throw CancellationError() }
        guard let cache, let model = publishedModel,
              let channel = sourceChannels.first(where: { $0.id == channelID }) else {
            throw LiveTVSourceImportError.cacheFailed
        }
        let mapping: LiveTVGuideMappingOverride?
        if let guideSourceID, let guideChannelID {
            guard guideSources.contains(where: {
                $0.id == guideSourceID && $0.playlistSourceID == channel.playlistSourceID && enabledSourceIDs.contains($0.id)
            }), !guideChannelID.isEmpty, guideChannelID.utf8.count <= 4_096 else {
                throw LiveTVSourceImportError.invalidGuide
            }
            mapping = LiveTVGuideMappingOverride(guideSourceID: guideSourceID, guideChannelID: guideChannelID)
        } else {
            guard guideSourceID == nil, guideChannelID == nil else { throw LiveTVSourceImportError.invalidGuide }
            mapping = nil
        }
        guard mappingOverrides[channelID] != mapping else { return }
        let request = revision
        try await cache.setMapping(mapping, channelID: channelID)
        guard request == revision, !Task.isCancelled, ensureCatalogAuthorization(into: model) else {
            throw CancellationError()
        }
        var overrides = mappingOverrides
        overrides[channelID] = mapping
        replaceMappingOverrides(overrides)
        try publishGuides(into: model)
        await reload(into: model)
    }

    private func replaceMappingOverrides(_ overrides: [String: LiveTVGuideMappingOverride]) {
        let changedChannels = Set(mappingOverrides.keys).union(overrides.keys).filter {
            mappingOverrides[$0] != overrides[$0]
        }
        let affectedGuides = Set(changedChannels.flatMap {
            [mappingOverrides[$0]?.guideSourceID, overrides[$0]?.guideSourceID].compactMap { $0 }
        })
        for id in affectedGuides {
            cachedGuides[id] = nil
            cachedGuideWindows[id] = nil
            if let index = guideSources.firstIndex(where: { $0.id == id }) {
                guideSources[index].phase = .idle
                guideSources[index].programCount = 0
                guideSources[index].matchedChannelCount = 0
                guideSources[index].lastRefresh = nil
            }
        }
        mappingOverrides = overrides
    }

    @discardableResult
    private func ensureCatalogAuthorization(into model: LiveTVPrototypeModel) -> Bool {
        guard !catalogIsAuthorized() else { return true }
        revision &+= 1
        reloadGeneration &+= 1
        windowRevision &+= 1
        serverRevision &+= 1
        cancelServerGuideRequests()
        configuration = .empty
        playlistSources = []
        guideSources = []
        serverSources = []
        serverGuideWindows = []
        enabledSourceIDs = []
        playlistPhase = .idle
        guidePhase = .idle
        playlistFailure = nil
        guideFailure = nil
        cachedPlaylists = [:]
        cachedGuides = [:]
        cachedGuideWindows = [:]
        requestedGuideWindow = nil
        cachedServerCatalogs = [:]
        generatedChannels = []
        generatedPrograms = []
        sourceChannels = []
        playlistSourceIDByChannel = [:]
        configuredSourceIDByChannel = [:]
        serverChannelReferences = [:]
        selectedSourceByChannel = [:]
        identityReviews = [:]
        mappingOverrides = [:]
        guideDiscoveryFailures = [:]
        guideChannelCount = 0
        matchedChannelCount = 0
        programCount = 0
        coverageStart = nil
        coverageEnd = nil
        lastGuideRefresh = nil
        beforeCatalogPublication?(.empty, [])
        model.setScanHiddenChannelIDs([])
        do {
            try model.replaceCatalog(channels: [], programs: [])
            model.setKnownGuideChannels([])
        } catch {
            cacheFailure = .cacheFailed
        }
        catalogRevision &+= 1
        return false
    }

    private func discoverGuides(in playlist: LiveTVPlaylistImport, source: LiveTVPlaylistSource) async throws {
        let request = revision
        guideDiscoveryFailures[source.id] = nil
        let configuredGuideIDs = Set(LiveTVConfiguredSources.guides(for: source).map(\.id))
        let oldDiscoveredIDs = Set(guideSources.filter {
            $0.playlistSourceID == source.id && !configuredGuideIDs.contains($0.id)
        }.map(\.id))
        let previousURLs = Dictionary(uniqueKeysWithValues: guideSources.filter {
            oldDiscoveredIDs.contains($0.id)
        }.map { ($0.id, $0.source.url) })
        guideSources.removeAll { oldDiscoveredIDs.contains($0.id) }
        enabledSourceIDs.subtract(oldDiscoveredIDs)
        guard source.discoversPlaylistGuides else {
            for id in oldDiscoveredIDs { cachedGuides[id] = nil; cachedGuideWindows[id] = nil }
            return
        }
        for (index, url) in playlist.declaredGuideURLs.enumerated() {
            guard !source.guideURLs.contains(where: { LiveTVPlaylistSource.guideURLsShareIdentity($0, url) }) else { continue }
            guard !guideSources.contains(where: { $0.playlistSourceID == source.id && $0.source.url == url }) else { continue }
            guard guideSources.filter({ $0.playlistSourceID == source.id }).count < 32 else {
                guideDiscoveryFailures[source.id] = .guideTooLarge
                continue
            }
            guard LiveTVSourceOriginPolicy.permits(url, from: playlist.originURL ?? source.playlistURL) else {
                guideDiscoveryFailures[source.id] = .unsafeGuideOrigin
                continue
            }
            let id: String
            if let cache {
                id = try await cache.discoveredGuideSourceID(sourceID: source.id, url: url)
                guard request == revision, !Task.isCancelled else { throw CancellationError() }
            } else {
                id = "\(source.id).declared.\(index)"
            }
            guard !guideSources.contains(where: { $0.id == id }) else { continue }
            if let previousURL = previousURLs[id], previousURL != url {
                cachedGuides[id] = nil
                cachedGuideWindows[id] = nil
            }
            let guide = LiveTVGuideSource(
                id: id, name: "\(source.name) · Playlist guide \(index + 1)", url: url,
                provider: LiveTVGuideSource.provider(for: url)
            )
            guideSources.append(LiveTVGuideSourceStatus(source: guide, playlistSourceID: source.id))
            if !disabledGuideIDs.contains(id) { enabledSourceIDs.insert(id) }
        }
        let retainedIDs = Set(guideSources.map(\.id))
        for id in oldDiscoveredIDs.subtracting(retainedIDs) {
            cachedGuides[id] = nil
            cachedGuideWindows[id] = nil
        }
    }

    func validateCacheBudget() throws {
        var count = 0
        var textBytes = 0
        let sources = cachedGuides.values.map(\.programs) + cachedServerCatalogs.values.map(\.programs)
        for programs in sources {
            count += programs.count
            guard count <= LiveTVXMLTVParser.maximumRetainedPrograms else {
                throw LiveTVSourceImportError.guideTooLarge
            }
            for program in programs {
                textBytes += program.title.utf8.count + program.subtitle.utf8.count
                guard textBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                    throw LiveTVSourceImportError.guideTooLarge
                }
            }
        }
    }
}
#endif
