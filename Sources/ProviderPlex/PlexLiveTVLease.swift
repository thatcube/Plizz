import CoreModels
import CoreNetworking
import Foundation

extension PlexProvider: ProviderTeardown {
    public func teardown() async {
        await liveTVLeases.closeAll()
    }
}

struct PlexLiveTVLease: LiveTVStreamLease {
    let playbackSource: PlaybackSource
    let resources: PlexLiveTVResources

    func report(_ update: LiveTVPlaybackUpdate) async {
        await resources.report(update)
    }

    func close() async {
        await resources.close()
    }
}

actor PlexLiveTVLeaseStore {
    private var resources: [UUID: PlexLiveTVResources] = [:]
    private(set) var isRetired = false

    func register(_ resource: PlexLiveTVResources) -> Bool {
        guard !isRetired else { return false }
        resources[resource.id] = resource
        return true
    }

    func remove(_ id: UUID) {
        resources[id] = nil
    }

    func closeAll() async {
        isRetired = true
        let pending = Array(resources.values)
        resources.removeAll()
        for resource in pending { await resource.close() }
    }
}

/// Owns a *playback* identity, not the potentially shared tuner UUID. PMS's
/// timeline API documents X-Plex-Session-Identifier for simultaneous viewers
/// on one client. Never DELETE a live session or call admin session termination.
actor PlexLiveTVResources {
    nonisolated let id = UUID()
    private let client: PlexClient
    private let playbackID: String
    private let store: PlexLiveTVLeaseStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var sessionPath: String?
    private var ratingKey: String?
    private var state = "buffering"
    private var position: TimeInterval = 0
    private var heartbeat: Task<Void, Never>?
    private var lastReport: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?

    init(
        client: PlexClient, playbackID: String, store: PlexLiveTVLeaseStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.playbackID = playbackID
        self.store = store
        self.sleep = sleep
    }

    func adopt(sessionPath: String?, ratingKey: String?) {
        self.sessionPath = sessionPath
        self.ratingKey = ratingKey
    }

    func startHeartbeat() {
        guard heartbeat == nil, cleanup == nil else { return }
        let sleep = sleep
        heartbeat = Task { [weak self] in
            do {
                try await sleep(.seconds(3))
                while !Task.isCancelled {
                    guard self != nil else { return }
                    await self?.sendHeartbeat()
                    try await sleep(.seconds(10))
                }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.playback.error("Plex Live TV heartbeat timer failed.")
            }
        }
    }

    func report(_ update: LiveTVPlaybackUpdate) async {
        guard cleanup == nil else { return }
        let nextState = update.state == .paused ? "paused" : "playing"
        let changed = nextState != state
        state = nextState
        position = update.positionSeconds
        if changed { await sendHeartbeat() }
    }

    func sendHeartbeat() async {
        guard cleanup == nil, sessionPath != nil else { return }
        let query = timeline(state: state)
        let client = client
        let playbackID = playbackID
        let previous = lastReport
        let task = Task.detached {
            await previous?.value
            do {
                _ = try await client.liveTVSessionRequest(
                    path: "/:/timeline", method: .post, query: query, playbackID: playbackID
                )
            } catch {
                PlozzLog.playback.error("Plex Live TV heartbeat could not be confirmed.")
            }
        }
        lastReport = task
        await task.value
    }

    func close() async {
        if let cleanup {
            await cleanup.value
            return
        }
        heartbeat?.cancel()
        heartbeat = nil
        let stopped = timeline(state: "stopped")
        let previous = lastReport
        let client = client
        let playbackID = playbackID
        let store = store
        let id = id
        let task = Task.detached {
            // A stale heartbeat must never arrive after the stop and renew it.
            await previous?.value
            do {
                _ = try await client.liveTVSessionRequest(
                    path: "/:/timeline", method: .post, query: stopped, playbackID: playbackID
                )
            } catch AppError.notFound {
                // An already expired owned session needs no second stop.
            } catch {
                PlozzLog.playback.error("Plex Live TV viewer release could not be confirmed.")
            }
            do {
                _ = try await client.liveTVSessionRequest(
                    path: "/video/:/transcode/universal/stop",
                    query: [URLQueryItem(name: "session", value: playbackID)],
                    playbackID: playbackID
                )
            } catch AppError.notFound {
                // Direct consumers need not have a universal-transcoder job.
            } catch {
                PlozzLog.playback.error("Plex Live TV owned transcode release could not be confirmed.")
            }
            await store.remove(id)
        }
        cleanup = task
        await task.value
    }

    private func timeline(state: String) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: "0"),
            URLQueryItem(name: "duration", value: "0"),
            URLQueryItem(name: "playbackTime", value: String(Int64(position * 1_000))),
            URLQueryItem(name: "hasMDE", value: "1")
        ]
        if let sessionPath { query.append(URLQueryItem(name: "key", value: sessionPath)) }
        if let ratingKey { query.append(URLQueryItem(name: "ratingKey", value: ratingKey)) }
        return query
    }
}
