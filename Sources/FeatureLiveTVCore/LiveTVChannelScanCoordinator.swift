#if DEBUG
import CoreModels
import Foundation
import Observation

public enum LiveTVChannelScanError: Error, Equatable, Sendable {
    case ineligibleChannel
    case invalidCatalog
    case sourceUnavailable
    case healthLoadFailed
    case healthSaveFailed
}

/// A catalog entry that cannot be requested under the current transport policy.
/// Its locator and headers are hashed, not retained in health/result data.
public struct LiveTVChannelScanUnprobeable: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sourceID: String
    public let streamIdentity: String
    public let reason: LiveTVChannelHealthReason

    fileprivate init(
        channel: LiveTVPrototypeChannel, sourceIdentity: String,
        reason: LiveTVChannelHealthReason, allowsHTTP: Bool, allowsLocalNetwork: Bool
    ) {
        id = channel.id
        name = channel.name
        sourceID = channel.playlistSourceID ?? ""
        self.reason = reason
        let headers = channel.httpHeaders.sorted {
            let left = $0.key.lowercased()
            let right = $1.key.lowercased()
            return left == right ? $0.key < $1.key : left < right
        }
            .flatMap { [$0.key.lowercased(), $0.value] }
        streamIdentity = LiveTVChannelHealthIdentity.digest(
            [sourceIdentity, reason.rawValue, channel.streamURL?.absoluteString ?? "",
             String(allowsHTTP), String(allowsLocalNetwork)] + headers
        )
    }
}

extension LiveTVChannelScanUnprobeable: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVChannelScanUnprobeable(\(streamIdentity), \(reason.rawValue))" }
    public var debugDescription: String { description }
}

public struct LiveTVChannelScanSource: Sendable {
    public let id: String
    /// Opaque catalog/stream revision. Change it when refreshing or editing a
    /// source; stable content fingerprints also allow health across app launches.
    public let generation: String
    public let targets: [LiveTVChannelScanTarget]
    public let unprobeableChannels: [LiveTVChannelScanUnprobeable]
    public var channelCount: Int { targets.count + unprobeableChannels.count }
    fileprivate let signature: String
    fileprivate var channelIdentities: [(id: String, streamIdentity: String)] {
        targets.map { ($0.id, $0.streamIdentity) } + unprobeableChannels.map { ($0.id, $0.streamIdentity) }
    }
    fileprivate var channelNames: [String] { targets.map(\.name) + unprobeableChannels.map(\.name) }

    public init(id: String, generation: String, targets: [LiveTVChannelScanTarget]) throws {
        try self.init(id: id, generation: generation, targets: targets, unprobeableChannels: [])
    }

    private init(
        id: String, generation: String, targets: [LiveTVChannelScanTarget],
        unprobeableChannels: [LiveTVChannelScanUnprobeable]
    ) throws {
        let ids = targets.map(\.id) + unprobeableChannels.map(\.id)
        guard !id.isEmpty, !generation.isEmpty, ids.count <= 50_000,
              targets.allSatisfy({ $0.sourceID == id }),
              unprobeableChannels.allSatisfy({ $0.sourceID == id }),
              Set(ids).count == ids.count else {
            throw LiveTVChannelScanError.invalidCatalog
        }
        self.id = id
        self.generation = generation
        self.targets = targets
        self.unprobeableChannels = unprobeableChannels
        signature = LiveTVChannelHealthIdentity.digest(
            [id, generation] + targets.flatMap { [$0.id, $0.streamIdentity] } +
                unprobeableChannels.flatMap { [$0.id, $0.streamIdentity] }
        )
    }

    /// Build from an already-authorized imported catalog. Stable content, not
    /// download timestamps or channel order, scopes durable reachability.
    public init(
        source: LiveTVPlaylistSource,
        channels: [LiveTVPrototypeChannel],
        additionalAllowedOrigins: Set<NetworkOrigin> = [],
        allowsHTTP: Bool = false,
        allowsLocalNetwork: Bool = false,
        hasCredentialedSourceContext: Bool = false
    ) throws {
        try source.validate()
        guard source.isEnabled else { throw LiveTVChannelScanError.sourceUnavailable }
        let credentialedSource = hasCredentialedSourceContext ||
            LiveTVScanCredentialContext.mayRequireCredentials(source.playlistURL)
        let sourceIdentity = LiveTVChannelHealthIdentity.digest(
            [source.id, source.playlistURL.absoluteString, String(credentialedSource)]
        )
        var targets: [LiveTVChannelScanTarget] = []
        var unprobeable: [LiveTVChannelScanUnprobeable] = []
        for channel in channels where channel.source == .iptv && channel.playlistSourceID == source.id {
            guard let url = channel.streamURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                unprobeable.append(LiveTVChannelScanUnprobeable(
                    channel: channel, sourceIdentity: sourceIdentity, reason: .unsupportedMedia,
                    allowsHTTP: allowsHTTP, allowsLocalNetwork: allowsLocalNetwork
                ))
                continue
            }
            do {
                let policy = try LiveTVScanOriginPolicy(
                    streamURL: url, headers: channel.httpHeaders,
                    additionalAllowedOrigins: additionalAllowedOrigins,
                    allowsHTTP: allowsHTTP, allowsLocalNetwork: allowsLocalNetwork
                )
                targets.append(try LiveTVChannelScanTarget(
                    channel: channel, policy: policy, sourceIdentity: sourceIdentity,
                    hasCredentialedSourceContext: credentialedSource
                ))
            } catch LiveTVScanTransportError.unsafeOrigin {
                unprobeable.append(LiveTVChannelScanUnprobeable(
                    channel: channel, sourceIdentity: sourceIdentity, reason: .unsafeOrigin,
                    allowsHTTP: allowsHTTP, allowsLocalNetwork: allowsLocalNetwork
                ))
            }
        }
        let identities = targets.map { ($0.id, $0.streamIdentity) } + unprobeable.map { ($0.id, $0.streamIdentity) }
        let revision = LiveTVChannelHealthIdentity.digest(
            [sourceIdentity] + identities.sorted { $0.0 < $1.0 }.flatMap { [$0.0, $0.1] }
        )
        try self.init(id: source.id, generation: revision, targets: targets, unprobeableChannels: unprobeable)
    }
}

extension LiveTVChannelScanSource: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVChannelScanSource(channels: \(channelCount))" }
    public var debugDescription: String { description }
}

public struct LiveTVChannelScanProgress: Equatable, Sendable {
    public let sourceID: String
    public let total: Int
    public var completed: Int
    public var reachable: Int
    public var unavailable: Int
    public var uncertain: Int
    public var isCancelled: Bool
    public var isFinished: Bool

    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// Runtime presentation only; channel names and IDs never enter health storage.
public struct LiveTVChannelScanRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: LiveTVChannelHealthStatus
    public let reason: LiveTVChannelHealthReason
    public let isScanHidden: Bool
}

@MainActor
@Observable
public final class LiveTVChannelScanCoordinator {
    public private(set) var progress: LiveTVChannelScanProgress?
    public private(set) var scanHiddenChannelIDs: Set<String> = []
    public private(set) var issue: LiveTVChannelScanError?
    public private(set) var sourceIDs: Set<String> = []
    public private(set) var resultsRevision = 0
    public var isScanning: Bool { progress.map { !$0.isFinished && !$0.isCancelled } ?? false }

    @ObservationIgnored private let store: any LiveTVChannelHealthStoring
    @ObservationIgnored private let probe: any LiveTVChannelProbing
    @ObservationIgnored private let limits: LiveTVChannelScanLimits
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var profileID: String?
    @ObservationIgnored private var sources: [String: LiveTVChannelScanSource] = [:]
    @ObservationIgnored private var healthIdentities: [String: [String: LiveTVChannelHealthIdentity]] = [:]
    @ObservationIgnored private var records: [LiveTVChannelHealthIdentity: LiveTVChannelHealthRecord] = [:]
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingWrites = 0
    @ObservationIgnored private var restoredDuringRun: Set<LiveTVChannelHealthIdentity> = []

    public init(
        store: any LiveTVChannelHealthStoring = LiveTVChannelHealthStore(),
        probe: (any LiveTVChannelProbing)? = nil,
        limits: LiveTVChannelScanLimits = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.probe = probe ?? LiveTVChannelProbe(limits: limits, now: now)
        self.limits = limits
        self.now = now
    }

    deinit { run?.cancel() }

    /// Call before publishing any source/profile/catalog replacement. This
    /// never reads or mutates the browser model, playback, favorites or mappings.
    public func bind(profileID: String, sources: [LiveTVChannelScanSource]) throws {
        guard !profileID.isEmpty, Set(sources.map(\.id)).count == sources.count,
              sources.reduce(0, { $0 + $1.channelCount }) <= 50_000,
              Set(sources.flatMap { $0.channelIdentities.map(\.id) }).count == sources.reduce(0, { $0 + $1.channelCount })
        else {
            deactivate()
            issue = .invalidCatalog
            throw LiveTVChannelScanError.invalidCatalog
        }
        let newSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let unchanged = self.profileID == profileID &&
            self.sources.mapValues(\.signature) == newSources.mapValues(\.signature)
        if unchanged && loaded {
            let renamed = self.sources.mapValues(\.channelNames) != newSources.mapValues(\.channelNames)
            self.sources = newSources
            if renamed { resultsRevision += 1 }
            return
        }
        cancel()
        progress = nil
        self.profileID = profileID
        self.sources = newSources
        healthIdentities = newSources.mapValues { source in
            Dictionary(uniqueKeysWithValues: source.channelIdentities.map { channel in
                (channel.id, Self.makeIdentity(
                    profileID: profileID, source: source,
                    channelID: channel.id, streamIdentity: channel.streamIdentity
                ))
            })
        }
        sourceIDs = Set(newSources.keys)
        scanHiddenChannelIDs = []
        do {
            let saved = try store.load()
            guard Set(saved.map(\.identity)).count == saved.count else {
                throw LiveTVChannelScanError.healthLoadFailed
            }
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.identity, $0) })
            pendingWrites = 0
            loaded = true
            issue = nil
            refreshHidden()
        } catch {
            records = [:]
            pendingWrites = 0
            loaded = false
            issue = .healthLoadFailed
            resultsRevision += 1
            throw LiveTVChannelScanError.healthLoadFailed
        }
        resultsRevision += 1
    }

    /// Fence immediately when refresh/edit/removal starts, not when it finishes.
    public func invalidate(sourceID: String) {
        if progress?.sourceID == sourceID { cancel() }
        sources.removeValue(forKey: sourceID)
        healthIdentities.removeValue(forKey: sourceID)
        sourceIDs.remove(sourceID)
        refreshHidden()
        resultsRevision += 1
    }

    public func deactivate() {
        cancel()
        profileID = nil
        sources = [:]
        healthIdentities = [:]
        sourceIDs = []
        records = [:]
        pendingWrites = 0
        progress = nil
        scanHiddenChannelIDs = []
        loaded = false
        resultsRevision += 1
    }

    public func canScan(sourceID: String) -> Bool {
        _ = resultsRevision
        return loaded && (sources[sourceID]?.channelCount ?? 0) > 0
    }

    public func hasResults(sourceID: String) -> Bool { !results(sourceID: sourceID).isEmpty }

    @discardableResult
    public func start(sourceID: String) -> Bool {
        guard loaded, let profileID, let source = sources[sourceID], source.channelCount > 0 else {
            issue = loaded ? .sourceUnavailable : .healthLoadFailed
            return false
        }
        cancel()
        guard issue != .healthSaveFailed else { return false }
        issue = nil
        let token = UUID()
        runID = token
        restoredDuringRun = []
        for channel in source.unprobeableChannels {
            let key = identity(profileID: profileID, source: source, unprobeable: channel)
            records[key] = LiveTVChannelHealthRecord(
                identity: key, status: .uncertain, reason: channel.reason,
                checkedAt: now(), isScanHidden: false
            )
            pendingWrites += 1
        }
        progress = LiveTVChannelScanProgress(
            sourceID: sourceID, total: source.channelCount, completed: source.unprobeableChannels.count,
            reachable: 0, unavailable: 0, uncertain: source.unprobeableChannels.count,
            isCancelled: false, isFinished: false
        )
        if !source.unprobeableChannels.isEmpty { resultsRevision += 1 }
        let probe = self.probe
        let concurrency = limits.concurrentChannels
        run = Task { [weak self] in
            var interrupted = false
            await withTaskGroup(of: (LiveTVChannelScanTarget, LiveTVChannelProbeResult?).self) { group in
                var index = 0
                for _ in 0..<min(concurrency, source.targets.count) {
                    let target = source.targets[index]
                    index += 1
                    group.addTask { (target, await Self.check(target, probe: probe)) }
                }
                while let (target, result) = await group.next() {
                    guard !Task.isCancelled,
                          self?.accepts(token: token, profileID: profileID, source: source) == true else {
                        group.cancelAll()
                        return
                    }
                    guard let result else {
                        interrupted = true
                        group.cancelAll()
                        return
                    }
                    self?.accept(result, target: target, source: source, profileID: profileID)
                    if self?.issue == .healthSaveFailed {
                        group.cancelAll()
                        self?.finish(token: token, cancelled: true)
                        return
                    }
                    if index < source.targets.count {
                        let next = source.targets[index]
                        index += 1
                        group.addTask { (next, await Self.check(next, probe: probe)) }
                    }
                }
            }
            self?.finish(token: token, cancelled: Task.isCancelled || interrupted)
        }
        return true
    }

    public func cancel() {
        runID = UUID()
        run?.cancel()
        run = nil
        if isScanning { progress?.isCancelled = true }
        flush()
    }

    public func waitUntilFinished() async {
        await run?.value
    }

    /// Restores only scanner state. A manually hidden favorite stays hidden.
    public func restore(channelID: String) {
        guard let profileID else { return }
        for source in sources.values {
            guard let target = source.targets.first(where: { $0.id == channelID }) else { continue }
            let key = identity(profileID: profileID, source: source, target: target)
            restoredDuringRun.insert(key)
            if let record = records[key], record.isScanHidden {
                records[key] = record.restored()
                pendingWrites += 1
            }
        }
        flush()
    }

    public func restoreAll(sourceID: String) {
        guard let profileID, let source = sources[sourceID] else { return }
        for target in source.targets {
            let key = identity(profileID: profileID, source: source, target: target)
            restoredDuringRun.insert(key)
            if let record = records[key], record.isScanHidden {
                records[key] = record.restored()
                pendingWrites += 1
            }
        }
        flush()
    }

    public func results(sourceID: String) -> [LiveTVChannelScanRow] {
        _ = resultsRevision
        guard let profileID, let source = sources[sourceID] else { return [] }
        let probed: [LiveTVChannelScanRow] = source.targets.compactMap { target in
            let key = identity(profileID: profileID, source: source, target: target)
            guard let record = records[key] else { return nil }
            return LiveTVChannelScanRow(
                id: target.id, name: target.name, status: record.status,
                reason: record.reason, isScanHidden: scanHiddenChannelIDs.contains(target.id)
            )
        }
        let unprobeable: [LiveTVChannelScanRow] = source.unprobeableChannels.compactMap { channel in
            let key = identity(profileID: profileID, source: source, unprobeable: channel)
            guard let record = records[key] else { return nil }
            return LiveTVChannelScanRow(
                id: channel.id, name: channel.name, status: record.status,
                reason: record.reason, isScanHidden: false
            )
        }
        return probed + unprobeable
    }

    public func dismissIssue() { issue = nil }
    public func retrySaving() { flush() }

    nonisolated private static func check(
        _ target: LiveTVChannelScanTarget, probe: any LiveTVChannelProbing
    ) async -> LiveTVChannelProbeResult? {
        do { return try await probe.probe(target) }
        catch is CancellationError { return nil }
        catch { return LiveTVChannelProbeResult(status: .uncertain, reason: .networkUnavailable) }
    }

    private func accepts(token: UUID, profileID: String, source: LiveTVChannelScanSource) -> Bool {
        runID == token && self.profileID == profileID && sources[source.id]?.signature == source.signature
    }

    private func accept(
        _ result: LiveTVChannelProbeResult, target: LiveTVChannelScanTarget,
        source: LiveTVChannelScanSource, profileID: String
    ) {
        let key = identity(profileID: profileID, source: source, target: target)
        // Uncertainty is visible, not hidden by a prior scan's verdict.
        records[key] = LiveTVChannelHealthRecord(
            identity: key, status: result.status, reason: result.reason, checkedAt: now(),
            isScanHidden: result.status == .unavailable && !restoredDuringRun.contains(key)
        )
        pendingWrites += 1
        progress?.completed += 1
        switch result.status {
        case .reachable: progress?.reachable += 1
        case .unavailable: progress?.unavailable += 1
        case .uncertain: progress?.uncertain += 1
        }
        resultsRevision += 1
        if pendingWrites >= 128 { flush() }
    }

    private func finish(token: UUID, cancelled: Bool) {
        guard runID == token else { return }
        flush()
        progress?.isCancelled = cancelled || issue == .healthSaveFailed
        progress?.isFinished = !cancelled && issue != .healthSaveFailed
        run = nil
    }

    private func flush() {
        guard loaded, pendingWrites > 0 else { return }
        do {
            try store.save(Array(records.values))
            pendingWrites = 0
            if issue == .healthSaveFailed { issue = nil }
            refreshHidden()
            resultsRevision += 1
        } catch {
            issue = .healthSaveFailed
        }
    }

    private func refreshHidden() {
        guard let profileID, loaded else { scanHiddenChannelIDs = []; return }
        scanHiddenChannelIDs = Set(sources.values.flatMap { source in
            source.targets.compactMap { target in
                records[identity(profileID: profileID, source: source, target: target)]?.isScanHidden == true ? target.id : nil
            }
        })
    }

    private func identity(
        profileID: String, source: LiveTVChannelScanSource, target: LiveTVChannelScanTarget
    ) -> LiveTVChannelHealthIdentity {
        if let cached = healthIdentities[source.id]?[target.id] { return cached }
        return Self.makeIdentity(
            profileID: profileID, source: source, channelID: target.id, streamIdentity: target.streamIdentity
        )
    }

    private func identity(
        profileID: String, source: LiveTVChannelScanSource, unprobeable: LiveTVChannelScanUnprobeable
    ) -> LiveTVChannelHealthIdentity {
        if let cached = healthIdentities[source.id]?[unprobeable.id] { return cached }
        return Self.makeIdentity(
            profileID: profileID, source: source,
            channelID: unprobeable.id, streamIdentity: unprobeable.streamIdentity
        )
    }

    private static func makeIdentity(
        profileID: String, source: LiveTVChannelScanSource, channelID: String, streamIdentity: String
    ) -> LiveTVChannelHealthIdentity {
        LiveTVChannelHealthIdentity(
            profileID: profileID, sourceID: source.id, channelID: channelID,
            streamIdentity: LiveTVChannelHealthIdentity.digest([source.generation, streamIdentity])
        )
    }
}
#endif
