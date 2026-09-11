#if DEBUG
import CoreModels
import Foundation

extension LiveTVPrototypeImportModel {
    public func setServerEnabled(
        _ sourceID: String, enabled: Bool, into model: LiveTVPrototypeModel
    ) throws {
        guard let index = configuration.servers.firstIndex(where: { $0.id == sourceID }) else {
            throw LiveTVSourcesValidationError.invalidSourceID
        }
        var updated = configuration
        updated.servers[index].isEnabled = enabled
        try applyConfiguration(updated, into: model)
    }

    /// Replacing the active-profile resolver synchronously removes catalogs whose authorization expired.
    public func setServerProviderResolver(
        _ resolver: @escaping LiveTVServerProviderResolver, into model: LiveTVPrototypeModel
    ) throws {
        serverRevision &+= 1
        cancelServerGuideRequests()
        serverProviderResolver = resolver
        for index in serverSources.indices {
            if serverSources[index].phase == .loading { serverSources[index].phase = .idle }
            if serverSources[index].guidePhase == .loading { serverSources[index].guidePhase = .idle }
            let source = serverSources[index].source
            guard source.isEnabled else { continue }
            let context = authorizedContext(for: source)
            if context == nil || cachedServerCatalogs[source.id].map({
                $0.authorizationID != context?.authorizationID || $0.kind != context?.kind
            }) == true {
                cachedServerCatalogs[source.id] = nil
                removeServerGuideWindows(source.id)
                serverSources[index] = LiveTVServerSourceStatus(source: source)
                if context == nil {
                    serverSources[index].phase = .failed
                    serverSources[index].failure = .accountUnavailable
                }
            }
        }
        try publishPlaylists(into: model)
    }

    public func reloadServers(into model: LiveTVPrototypeModel) async {
        serverRevision &+= 1
        cancelServerGuideRequests()
        let request = serverRevision
        do { try configuration.validate() }
        catch {
            for index in serverSources.indices {
                serverSources[index].phase = .failed
                serverSources[index].failure = .invalidCatalog
                serverSources[index].guidePhase = .idle
            }
            return
        }
        for index in serverSources.indices {
            if serverSources[index].phase == .loading { serverSources[index].phase = .idle }
            if serverSources[index].guidePhase == .loading { serverSources[index].guidePhase = .idle }
        }
        let sources = serverSources.map(\.source).filter(\.isEnabled)
        for source in sources {
            guard request == serverRevision, !Task.isCancelled else { return }
            let sourceRevision = serverSourceRevisions[source.id, default: 0]
            guard configuration.servers.contains(where: {
                $0.id == source.id && $0.accountID == source.accountID && $0.isEnabled
            }) else { continue }
            guard let context = authorizedContext(for: source) else {
                discardUnauthorizedSource(source.id, into: model)
                continue
            }
            if let cached = cachedServerCatalogs[source.id],
               cached.authorizationID != context.authorizationID || cached.kind != context.kind {
                cachedServerCatalogs[source.id] = nil
                removeServerGuideWindows(source.id)
                try? publishPlaylists(into: model)
            }
            updateServerStatus(source.id) {
                $0.phase = .loading
                $0.failure = nil
                $0.guideFailure = nil
                $0.guidePhase = .idle
            }
            do {
                let availability = try await context.provider.liveTVAvailability()
                try Task.checkCancellation()
                guard acceptServerResult(
                    source, context: context, request: request, sourceRevision: sourceRevision, into: model
                ) else { continue }
                updateServerStatus(source.id) { $0.availability = availability }
                switch availability.status {
                case .notConfigured, .noChannels, .permissionDenied, .subscriptionRequired,
                     .serviceUnavailable, .unsupportedAPI:
                    if availability.status != .serviceUnavailable {
                        cachedServerCatalogs[source.id] = nil
                        removeServerGuideWindows(source.id)
                    }
                    updateServerStatus(source.id) {
                        $0.channelCount = cachedServerCatalogs[source.id]?.channels.count ?? 0
                        $0.programCount = cachedServerCatalogs[source.id]?.programs.count ?? 0
                        $0.lastRefresh = Date()
                        switch availability.status {
                        case .permissionDenied: $0.failure = .permissionDenied
                        case .subscriptionRequired: $0.failure = .subscriptionRequired
                        case .serviceUnavailable: $0.failure = .serviceUnavailable
                        case .unsupportedAPI: $0.failure = .unsupportedAPI
                        default: $0.failure = nil
                        }
                        $0.phase = $0.failure == nil ? .loaded : .failed
                    }
                    try publishPlaylists(into: model)
                    continue
                case .available, .unsupportedPlaybackMode:
                    break
                }
                let channels = try await context.provider.liveTVChannels()
                try Task.checkCancellation()
                guard acceptServerResult(
                    source, context: context, request: request, sourceRevision: sourceRevision, into: model
                ) else { continue }
                var catalog = try LiveTVServerCatalog(source: source, context: context, channels: channels)
                let previous = cachedServerCatalogs[source.id]
                if let previous {
                    let known = Set(catalog.channels.map(\.id))
                    var programs = Dictionary(uniqueKeysWithValues: previous.programs.filter {
                        known.contains($0.channelID)
                    }.map { ($0.id, $0) })
                    for program in catalog.programs { programs[program.id] = program }
                    catalog.programs = programs.values.sorted { $0.id < $1.id }
                }
                cachedServerCatalogs[source.id] = catalog
                do {
                    try validateCacheBudget()
                    try publishPlaylists(into: model)
                } catch {
                    cachedServerCatalogs[source.id] = previous
                    throw LiveTVServerImportError.invalidCatalog
                }
                retainServerGuideChannels(Set(catalog.channels.map(\.id)), sourceID: source.id)
                updateServerStatus(source.id) {
                    $0.phase = .loaded
                    if channels.isEmpty {
                        $0.availability = ServerLiveTVAvailability(
                            status: .noChannels, supportsGuide: availability.supportsGuide
                        )
                    }
                    $0.channelCount = channels.count
                    $0.programCount = catalog.programs.count
                    $0.lastRefresh = Date()
                    $0.guideFailure = catalog.inlineGuideFailure
                }
                guard availability.supportsGuide, !channels.isEmpty else { continue }
                let warmup = context.kind == .plex
                    ? Array(catalog.channels.prefix(Self.serverGuideWarmupChannelLimit)) : catalog.channels
                await reloadServerGuides(
                    channelIDs: warmup.map(\.id), from: model.now, to: model.now.addingTimeInterval(21_600),
                    into: model, force: true
                )
            } catch {
                guard currentServerRequest(source, request: request, sourceRevision: sourceRevision) else {
                    continue
                }
                if isCancellation(error) {
                    updateServerStatus(source.id) { $0.phase = .idle; $0.guidePhase = .idle }
                    return
                }
                guard acceptServerResult(
                    source, context: context, request: request, sourceRevision: sourceRevision, into: model
                ) else { continue }
                let failure = LiveTVServerImportError.sanitized(error, fallback: .serviceUnavailable)
                if failure == .permissionDenied || failure == .subscriptionRequired || failure == .accountUnavailable {
                    cachedServerCatalogs[source.id] = nil
                    removeServerGuideWindows(source.id)
                    try? publishPlaylists(into: model)
                }
                updateServerStatus(source.id) {
                    $0.phase = .failed
                    $0.failure = failure
                    $0.channelCount = cachedServerCatalogs[source.id]?.channels.count ?? 0
                }
            }
        }
    }

    func applyServerConfiguration(_ sources: [LiveTVServerSource]) {
        let previous = serverSources.reduce(into: [String: LiveTVServerSourceStatus]()) { $0[$1.id] = $1 }
        let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for id in Set(previous.keys).union(current.keys) {
            if previous[id]?.source.accountID != current[id]?.accountID
                || previous[id]?.source.isEnabled != current[id]?.isEnabled {
                serverSourceRevisions[id, default: 0] &+= 1
                removeServerGuideWindows(id)
            }
        }
        let retained = Set(sources.filter {
            $0.isEnabled && previous[$0.id]?.source.accountID == $0.accountID
        }.map(\.id))
        cachedServerCatalogs = cachedServerCatalogs.filter { retained.contains($0.key) }
        serverSources = sources.map { source in
            var status = LiveTVServerSourceStatus(source: source)
            if retained.contains(source.id), let old = previous[source.id] {
                status.phase = old.phase
                status.guidePhase = old.guidePhase
                status.availability = old.availability
                status.failure = old.failure
                status.guideFailure = old.guideFailure
                status.channelCount = old.channelCount
                status.programCount = old.programCount
                status.lastRefresh = old.lastRefresh
                status.lastGuideRefresh = old.lastGuideRefresh
            }
            return status
        }
    }

    func authorizedContext(for source: LiveTVServerSource) -> LiveTVAuthorizedServerProvider? {
        guard let context = serverProviderResolver(source.accountID), context.accountID == source.accountID,
              !context.authorizationID.isEmpty, [.jellyfin, .plex, .emby].contains(context.kind)
        else { return nil }
        return context
    }

    func currentServerRequest(_ source: LiveTVServerSource, request: Int, sourceRevision: Int) -> Bool {
        request == serverRevision && serverSourceRevisions[source.id, default: 0] == sourceRevision
            && configuration.servers.contains { $0.id == source.id && $0.accountID == source.accountID && $0.isEnabled }
    }

    func acceptServerResult(
        _ source: LiveTVServerSource, context: LiveTVAuthorizedServerProvider,
        request: Int, sourceRevision: Int, into model: LiveTVPrototypeModel
    ) -> Bool {
        guard currentServerRequest(source, request: request, sourceRevision: sourceRevision) else { return false }
        guard let current = authorizedContext(for: source),
              current.authorizationID == context.authorizationID, current.kind == context.kind else {
            discardUnauthorizedSource(source.id, into: model)
            return false
        }
        return true
    }

    func discardUnauthorizedSource(_ id: String, into model: LiveTVPrototypeModel) {
        cachedServerCatalogs[id] = nil
        removeServerGuideWindows(id)
        updateServerStatus(id) {
            $0.phase = .failed
            $0.guidePhase = .idle
            $0.availability = nil
            $0.failure = .accountUnavailable
            $0.guideFailure = nil
            $0.channelCount = 0
            $0.programCount = 0
        }
        try? publishPlaylists(into: model)
    }

    func updateServerStatus(_ id: String, _ update: (inout LiveTVServerSourceStatus) -> Void) {
        guard let index = serverSources.firstIndex(where: { $0.id == id }) else { return }
        update(&serverSources[index])
    }
}
#endif
