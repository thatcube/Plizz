#if DEBUG
import CoreModels
import Foundation

extension LiveTVPrototypeImportModel {
    public static let serverGuideWarmupChannelLimit = 12
    public static let maximumServerGuideRequestDuration: TimeInterval = 48 * 3_600
    public static let maximumServerGuideChannelsPerRequest = 2_000
    private static let maximumServerGuideWindows = 128

    /// Fills only the requested native channel/window coverage. Set force for an explicit refresh.
    public func reloadServerGuides(
        channelIDs: [String], from: Date, to: Date, into model: LiveTVPrototypeModel, force: Bool = false
    ) async {
        var seen = Set<String>()
        let requestedIDs = channelIDs.filter { seen.insert($0).inserted && serverChannelReferences[$0] != nil }
        guard !requestedIDs.isEmpty else { return }
        let duration = to.timeIntervalSince(from)
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, duration > 0,
              duration <= Self.maximumServerGuideRequestDuration * Double(Self.maximumServerGuideWindows) else {
            for id in Set(requestedIDs.compactMap { serverChannelReferences[$0]?.sourceID }) {
                updateServerStatus(id) { $0.guidePhase = .failed; $0.guideFailure = .invalidGuide }
            }
            return
        }
        let request = serverRevision
        for source in configuration.servers where source.isEnabled {
            guard request == serverRevision, !Task.isCancelled else { return }
            let globalIDs = requestedIDs.filter {
                serverChannelReferences[$0]?.sourceID == source.id
                    && serverChannelReferences[$0]?.accountID == source.accountID
            }
            guard !globalIDs.isEmpty, cachedServerCatalogs[source.id] != nil,
                  serverSources.first(where: { $0.id == source.id })?.availability?.supportsGuide == true
            else { continue }
            guard let context = authorizedContext(for: source) else {
                discardUnauthorizedSource(source.id, into: model)
                continue
            }
            guard cachedServerCatalogs[source.id]?.authorizationID == context.authorizationID,
                  cachedServerCatalogs[source.id]?.kind == context.kind else {
                discardUnauthorizedSource(source.id, into: model)
                continue
            }
            let sourceRevision = serverSourceRevisions[source.id, default: 0]
            var start = from
            while start < to {
                guard currentServerRequest(source, request: request, sourceRevision: sourceRevision),
                      !Task.isCancelled else { return }
                let end = min(to, start.addingTimeInterval(Self.maximumServerGuideRequestDuration))
                guard end > start else {
                    updateServerStatus(source.id) { $0.guidePhase = .failed; $0.guideFailure = .invalidGuide }
                    return
                }
                let chunkStart = start
                start = end
                let missingIDs = globalIDs.filter {
                    if force { return true }
                    switch serverGuideState(channelID: $0, from: chunkStart, to: end) {
                    case .noListings: return false
                    case .loading:
                        return !serverGuideCoveragePhases(channelID: $0, from: chunkStart, to: end)
                            .allSatisfy { $0 == .loaded || $0 == .loading }
                    default: return true
                    }
                }
                for offset in stride(from: 0, to: missingIDs.count, by: Self.maximumServerGuideChannelsPerRequest) {
                    guard currentServerRequest(source, request: request, sourceRevision: sourceRevision),
                          !Task.isCancelled else { return }
                    let batch = Array(missingIDs[offset..<min(
                        missingIDs.count, offset + Self.maximumServerGuideChannelsPerRequest
                    )])
                    let nativeIDs = batch.compactMap { serverChannelReferences[$0]?.channelID }
                    guard nativeIDs.count == batch.count else { continue }
                    let window = beginServerGuideWindow(
                        sourceID: source.id, channelIDs: batch, from: chunkStart, to: end
                    )
                    do {
                        let nativePrograms = try await context.provider.liveTVGuide(
                            channelIDs: nativeIDs, from: chunkStart, to: end
                        )
                        try Task.checkCancellation()
                        guard activeServerGuideRequests.contains(window.id) else { return }
                        guard acceptServerResult(
                            source, context: context, request: request, sourceRevision: sourceRevision, into: model
                        ) else { return }
                        guard var catalog = cachedServerCatalogs[source.id] else { return }
                        let requested = Set(batch)
                        let programs = try catalog.mapPrograms(nativePrograms, source: source).filter {
                            requested.contains($0.channelID) && $0.end > chunkStart && $0.start < end
                        }
                        // An empty successful response replaces only this channel/window, not its whole guide.
                        var merged = Dictionary(uniqueKeysWithValues: catalog.programs.filter {
                            !requested.contains($0.channelID) || $0.end <= chunkStart || $0.start >= end
                        }.map { ($0.id, $0) })
                        for program in programs { merged[program.id] = program }
                        let previous = cachedServerCatalogs[source.id]
                        catalog.programs = merged.values.sorted {
                            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
                        }
                        cachedServerCatalogs[source.id] = catalog
                        do {
                            try validateCacheBudget()
                            try publishPlaylists(into: model)
                        } catch {
                            cachedServerCatalogs[source.id] = previous
                            throw LiveTVServerImportError.invalidGuide
                        }
                        finishServerGuideWindow(window.id, phase: .loaded)
                        updateServerStatus(source.id) {
                            $0.programCount = catalog.programs.count
                            $0.lastGuideRefresh = Date()
                        }
                    } catch {
                        guard activeServerGuideRequests.contains(window.id) else { return }
                        guard currentServerRequest(source, request: request, sourceRevision: sourceRevision) else {
                            finishServerGuideWindow(window.id, phase: .idle)
                            return
                        }
                        if isCancellation(error) {
                            finishServerGuideWindow(window.id, phase: .idle)
                            return
                        }
                        guard acceptServerResult(
                            source, context: context, request: request, sourceRevision: sourceRevision, into: model
                        ) else { return }
                        let failure = LiveTVServerImportError.sanitized(error, fallback: .serviceUnavailable)
                        if failure == .permissionDenied {
                            cachedServerCatalogs[source.id]?.programs = []
                            try? publishPlaylists(into: model)
                            removeServerGuideWindows(source.id)
                            serverGuideWindows.append(window)
                            activeServerGuideRequests.insert(window.id)
                        }
                        finishServerGuideWindow(window.id, phase: .failed, failure: failure)
                        updateServerStatus(source.id) {
                            $0.programCount = cachedServerCatalogs[source.id]?.programs.count ?? 0
                        }
                        if failure == .permissionDenied { return }
                    }
                }
            }
        }
    }

    /// Loaded empty coverage is distinct from a channel/window which has never been requested.
    public func serverGuideState(channelID: String, from: Date, to: Date) -> LiveTVGuideGapState {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, from < to else {
            return .failed
        }
        guard let reference = serverChannelReferences[channelID],
              let status = serverSources.first(where: { $0.id == reference.sourceID }) else { return .unrequested }
        if status.failure != nil || status.guideFailure == .permissionDenied { return .failed }
        if status.availability?.supportsGuide == false { return .disabled }
        var state = LiveTVGuideGapState.noListings
        for phase in serverGuideCoveragePhases(channelID: channelID, from: from, to: to) {
            switch phase {
            case .loading: return .loading
            case .failed: state = .failed
            case .idle, nil:
                if state != .failed { state = .unrequested }
            case .loaded: break
            }
        }
        return state
    }

    private func serverGuideCoveragePhases(
        channelID: String, from: Date, to: Date
    ) -> [LiveTVImportPhase?] {
        guard let reference = serverChannelReferences[channelID] else { return [nil] }
        let windows = serverGuideWindows.filter {
            $0.sourceID == reference.sourceID && $0.channelIDs.contains(channelID) && $0.from < to && $0.to > from
        }
        let boundaries = Set([from, to] + windows.flatMap { [max(from, $0.from), min(to, $0.to)] }).sorted()
        return zip(boundaries, boundaries.dropFirst()).map { start, end in
            windows.last { $0.from <= start && $0.to >= end }?.phase
        }
    }

    public func gapState(
        for channel: LiveTVPrototypeChannel, from: Date, to: Date
    ) -> LiveTVGuideGapState {
        if serverChannelReferences[channel.id] != nil {
            return serverGuideState(channelID: channel.id, from: from, to: to)
        }
        return gapState(for: channel)
    }

    func cancelServerGuideRequests() {
        for index in serverGuideWindows.indices where activeServerGuideRequests.contains(serverGuideWindows[index].id) {
            serverGuideWindows[index].phase = serverGuideWindows[index].lastRefresh == nil ? .idle : .loaded
            serverGuideWindows[index].failure = nil
        }
        activeServerGuideRequests.removeAll()
    }

    func removeServerGuideWindows(_ sourceID: String) {
        for window in serverGuideWindows where window.sourceID == sourceID {
            activeServerGuideRequests.remove(window.id)
        }
        serverGuideWindows.removeAll { $0.sourceID == sourceID }
    }

    func retainServerGuideChannels(_ channelIDs: Set<String>, sourceID: String) {
        let removed = Set(serverGuideWindows.filter {
            $0.sourceID == sourceID && !channelIDs.isSuperset(of: $0.channelIDs)
        }.map(\.id))
        guard !removed.isEmpty else { return }
        activeServerGuideRequests.subtract(removed)
        serverGuideWindows.removeAll { removed.contains($0.id) }
        updateServerGuidePhase(sourceID)
    }

    private func beginServerGuideWindow(
        sourceID: String, channelIDs: [String], from: Date, to: Date
    ) -> LiveTVServerGuideWindowStatus {
        let orderedIDs = channelIDs.sorted()
        let requested = Set(orderedIDs)
        let previous = serverGuideWindows.last {
            $0.sourceID == sourceID && $0.channelIDs == orderedIDs && $0.from == from && $0.to == to
        }
        for index in serverGuideWindows.indices {
            let old = serverGuideWindows[index]
            guard old.sourceID == sourceID, old.from < to, old.to > from,
                  !requested.isDisjoint(with: old.channelIDs), activeServerGuideRequests.contains(old.id) else { continue }
            activeServerGuideRequests.remove(old.id)
            serverGuideWindows[index].phase = old.lastRefresh == nil ? .idle : .loaded
        }
        if let previous { serverGuideWindows.removeAll { $0.id == previous.id } }
        var window = LiveTVServerGuideWindowStatus(
            sourceID: sourceID, channelIDs: orderedIDs, from: from, to: to, lastRefresh: previous?.lastRefresh
        )
        window.phase = .loading
        serverGuideWindows.append(window)
        activeServerGuideRequests.insert(window.id)
        while serverGuideWindows.count > Self.maximumServerGuideWindows {
            let evicted = serverGuideWindows.removeFirst()
            activeServerGuideRequests.remove(evicted.id)
            updateServerGuidePhase(evicted.sourceID)
        }
        updateServerStatus(sourceID) { $0.guidePhase = .loading; $0.guideFailure = nil }
        return window
    }

    private func finishServerGuideWindow(
        _ id: UUID, phase: LiveTVImportPhase, failure: LiveTVServerImportError? = nil
    ) {
        activeServerGuideRequests.remove(id)
        guard let index = serverGuideWindows.firstIndex(where: { $0.id == id }) else { return }
        serverGuideWindows[index].phase = phase == .idle && serverGuideWindows[index].lastRefresh != nil
            ? .loaded : phase
        serverGuideWindows[index].failure = failure
        if phase == .loaded { serverGuideWindows[index].lastRefresh = Date() }
        updateServerGuidePhase(serverGuideWindows[index].sourceID)
    }

    private func updateServerGuidePhase(_ sourceID: String) {
        let windows = serverGuideWindows.filter { $0.sourceID == sourceID }
        let latest = windows.last
        updateServerStatus(sourceID) {
            $0.guidePhase = windows.contains(where: { $0.phase == .loading }) ? .loading : latest?.phase ?? .idle
            $0.guideFailure = latest?.failure
        }
    }
}
#endif
