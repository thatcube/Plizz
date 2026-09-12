#if DEBUG && canImport(AVFoundation)
import CoreModels
import Foundation
import Observation
import TraktService

public enum LibraryChannelPlaybackState: Equatable, Sendable {
    case idle, loading, playing, paused
    case unavailable(LibraryChannelError)
}

public typealias LibraryChannelCompletionSink =
    @MainActor @Sendable (LibraryChannelItem, MediaItem, UUID) async throws -> Void

public enum LibraryChannelHistoryReporting: Sendable {
    /// The application sink owns every origin, tracker, cross-server and UI mutation.
    /// Revalidate the supplied opt-in token and profile at any asynchronous commit.
    case externalCompletion(LibraryChannelCompletionSink)
    /// Compatibility path for callers without the application's mutation pipeline.
    case sourceAndTrakt(
        scrobbler: any TraktScrobbling,
        onCompleted: @MainActor @Sendable (LibraryChannelItem, MediaItem, UUID) async -> Void
    )
}

/// VOD decoder with broadcast scheduling, deliberately not PlayerViewModel:
/// no ordinary resume/progress reporting, automatic next episode or teardown scrobble.
@MainActor
@Observable
public final class LibraryChannelPlaybackSession {
    public let channelID: UUID
    public let engine: any VideoEngine
    public private(set) var state: LibraryChannelPlaybackState = .idle
    public private(set) var currentSlot: LibraryChannelSlot?
    public private(set) var isDelayed = false
    public private(set) var isWatching = false
    public private(set) var historyIssue = false
    public private(set) var secondsWatched: TimeInterval = 0
    /// Reset pane-derived tracks/cues; this notification must not request another tune.
    @ObservationIgnored public var onSourceReset: (@MainActor () -> Void)?
    @ObservationIgnored public var onPlaybackFailure: (@MainActor (LibraryChannelError) -> Void)?
    @ObservationIgnored private let schedule: @MainActor @Sendable () -> LibraryChannelSchedule?
    @ObservationIgnored private let provider: @MainActor @Sendable (LibraryChannelItem) -> (any LibraryChannelPlaybackProviding)?
    @ObservationIgnored private let authorization: @MainActor @Sendable () -> String?
    @ObservationIgnored private let historyAuthorization: @MainActor @Sendable () -> UUID?
    @ObservationIgnored private let historyReporting: LibraryChannelHistoryReporting
    @ObservationIgnored private let clock: @MainActor @Sendable () -> Date
    @ObservationIgnored private let uptime: @MainActor @Sendable () -> TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerID: UUID?
    @ObservationIgnored private var historyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var request: PlaybackRequest?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeAuthorization: String?
    @ObservationIgnored private var coverage = LibraryChannelWatchCoverage(duration: 0)
    @ObservationIgnored private var coverageSlotID: String?
    @ObservationIgnored private var historyToken: UUID?
    @ObservationIgnored private var reportedCompletion = false
    @ObservationIgnored private var pausedCursor: Date?
    @ObservationIgnored private var preparedCursor: Date?
    @ObservationIgnored private var pendingReconciliation = false
    @ObservationIgnored private var intendedPause = false
    @ObservationIgnored private var completionProvider: (any LibraryChannelPlaybackProviding)?
    @ObservationIgnored private var preferredAudioLanguages: [String] = []
    @ObservationIgnored private var preferredSubtitleLanguages: [String] = []
    @ObservationIgnored private var loadingStarted: TimeInterval?

    public convenience init(
        channelID: UUID, engine: any VideoEngine,
        schedule: @escaping @MainActor @Sendable () -> LibraryChannelSchedule?,
        provider: @escaping @MainActor @Sendable (LibraryChannelItem) -> (any LibraryChannelPlaybackProviding)?,
        authorization: @escaping @MainActor @Sendable () -> String?,
        historyAuthorization: @escaping @MainActor @Sendable () -> UUID?,
        scrobbler: any TraktScrobbling,
        onCompleted: @escaping @MainActor @Sendable (LibraryChannelItem, MediaItem, UUID) async -> Void,
        clock: @escaping @MainActor @Sendable () -> Date = { Date() },
        uptime: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(
            channelID: channelID, engine: engine, schedule: schedule, provider: provider,
            authorization: authorization, historyAuthorization: historyAuthorization,
            historyReporting: .sourceAndTrakt(scrobbler: scrobbler, onCompleted: onCompleted),
            clock: clock, uptime: uptime
        )
    }

    public init(
        channelID: UUID, engine: any VideoEngine,
        schedule: @escaping @MainActor @Sendable () -> LibraryChannelSchedule?,
        provider: @escaping @MainActor @Sendable (LibraryChannelItem) -> (any LibraryChannelPlaybackProviding)?,
        authorization: @escaping @MainActor @Sendable () -> String?,
        historyAuthorization: @escaping @MainActor @Sendable () -> UUID?,
        historyReporting: LibraryChannelHistoryReporting,
        clock: @escaping @MainActor @Sendable () -> Date = { Date() },
        uptime: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.channelID = channelID
        self.engine = engine
        self.schedule = schedule
        self.provider = provider
        self.authorization = authorization
        self.historyAuthorization = historyAuthorization
        self.historyReporting = historyReporting
        self.clock = clock
        self.uptime = uptime
    }

    deinit {
        task?.cancel()
        timer?.cancel()
        for task in historyTasks.values { task.cancel() }
    }

    public func setTrackPreferences(audioLanguages: [String], subtitleLanguages: [String]) {
        preferredAudioLanguages = audioLanguages
        preferredSubtitleLanguages = subtitleLanguages
    }

    public func setWatching(_ watching: Bool) {
        guard watching != isWatching else { return }
        sampleHistory()
        coverage.discontinuity()
        isWatching = watching
    }

    public var behindLiveSeconds: TimeInterval? {
        guard let slot = currentSlot else { return nil }
        let cursor = pausedCursor ?? slot.start.addingTimeInterval(engine.currentTime)
        return max(0, clock().timeIntervalSince(cursor))
    }

    /// The source remains valid and its timer will advance at the next immutable
    /// boundary. A live-pane owner must not turn this into whole-source teardown.
    public var recoverableProgrammeIssue: LibraryChannelError? {
        guard activeAuthorization != nil, authorization() == activeAuthorization,
              schedule() != nil, let slot = currentSlot, provider(slot.item) != nil,
              case .unavailable(let error) = state else { return nil }
        switch error {
        case .mediaChanged, .incompatiblePlaybackMode, .unableToJoinLive, .playbackFailed, .sourceUnavailable:
            return error
        default:
            return nil
        }
    }

    /// Follows internal boundary/seek replacements, not a captured load task.
    /// An owner cancellation still retires its own source through stopAndDrain.
    public func waitUntilSettled() async throws {
        let started = uptime()
        while true {
            try Task.checkCancellation()
            guard activeAuthorization != nil, authorization() == activeAuthorization else {
                cancelHistoryTasks()
                stop()
                fail(.authorizationChanged)
                throw LibraryChannelError.authorizationChanged
            }
            if let item = currentSlot?.item, provider(item) == nil {
                cancelHistoryTasks()
                stop()
                fail(.sourceUnavailable)
                throw LibraryChannelError.sourceUnavailable
            }
            switch state {
            case .playing where engine.status == .ready:
                return
            case .paused where loadingStarted == nil && engine.status == .ready:
                return
            case .unavailable(let error):
                throw error
            case .idle:
                throw CancellationError()
            case .playing, .paused, .loading:
                break
            }
            if uptime() - started >= 45 {
                generation = UUID()
                task?.cancel()
                engine.stop(preserveDisplayMode: true)
                pendingReconciliation = false
                loadingStarted = nil
                fail(.unableToJoinLive)
                throw LibraryChannelError.unableToJoinLive
            }
            try await Task.sleep(for: .milliseconds(50))
            tick()
        }
    }

    public func tune() {
        let date = clock()
        activeAuthorization = authorization()
        isDelayed = intendedPause
        pausedCursor = intendedPause ? date : nil
        startTimer()
        prepare(at: date)
    }

    public func pause() {
        guard !intendedPause else { return }
        sampleHistory()
        coverage.discontinuity()
        if let currentSlot {
            pausedCursor = state == .loading
                ? (isDelayed ? pausedCursor ?? preparedCursor ?? clock() : clock())
                : currentSlot.start.addingTimeInterval(engine.currentTime)
        } else {
            pausedCursor = clock()
        }
        isDelayed = true
        intendedPause = true
        engine.pause()
        if state != .idle { state = .paused }
    }

    public func resume() {
        guard let cursor = pausedCursor else { return }
        guard state != .idle else {
            intendedPause = false
            isDelayed = false
            pausedCursor = nil
            return
        }
        guard cursor >= clock().addingTimeInterval(-86_400) else {
            fail(.historyExpired)
            return
        }
        intendedPause = false
        coverage.discontinuity()
        if case .paused = state, (currentSlot?.end ?? .distantPast) > cursor, engine.status == .ready {
            engine.play()
            state = .playing
        } else {
            prepare(at: cursor)
        }
        pausedCursor = nil
    }

    public func goLive() {
        isDelayed = false
        intendedPause = false
        pausedCursor = nil
        prepare(at: clock())
    }

    public func foreground() {
        guard state != .idle else { return }
        if !isDelayed { goLive() }
        else if let cursor = pausedCursor, cursor < clock().addingTimeInterval(-86_400) {
            engine.pause()
            fail(.historyExpired)
        } else if let cursor = pausedCursor ?? currentSlot?.start.addingTimeInterval(engine.currentTime) {
            prepare(at: cursor)
        }
    }

    public func retry() {
        let cursor = pausedCursor ?? (isDelayed ? currentSlot?.start.addingTimeInterval(engine.currentTime) : nil)
        prepare(at: cursor ?? clock())
    }

    public func stop() {
        sampleHistory()
        generation = UUID()
        let previous = task
        previous?.cancel()
        timer?.cancel()
        timer = nil
        timerID = nil
        loadingStarted = nil
        pendingReconciliation = false
        intendedPause = false
        pausedCursor = nil
        preparedCursor = nil
        isDelayed = false
        engine.onEnded = nil
        engine.onFailure = nil
        engine.stop()
        let engine = self.engine
        task = Task { @MainActor in
            if let previous { await previous.value }
            engine.stop()
            await engine.drainTransport()
        }
        currentSlot = nil
        request = nil
        completionProvider = nil
        state = .idle
    }

    public func stopAndDrain() async {
        if state != .idle { stop() }
        let cleanup = task
        if let cleanup { await cleanup.value }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let id = UUID()
        timerID = id
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, self.timerID == id, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// Internal for deterministic clock/engine fixtures.
    func tick() {
        guard state != .idle else { return }
        guard activeAuthorization != nil, authorization() == activeAuthorization else {
            cancelHistoryTasks()
            stop()
            fail(.authorizationChanged)
            return
        }
        if let item = currentSlot?.item, provider(item) == nil {
            cancelHistoryTasks()
            stop()
            fail(.sourceUnavailable)
            return
        }
        sampleHistory()
        if !intendedPause, !isDelayed, let slot = currentSlot,
           clock() >= slot.end || clock() < slot.start {
            prepare(at: clock())
            return
        }
        if let loadingStarted, uptime() - loadingStarted >= 45 {
            generation = UUID()
            task?.cancel()
            engine.stop(preserveDisplayMode: true)
            pendingReconciliation = false
            self.loadingStarted = nil
            fail(.unableToJoinLive)
            return
        }
        if pendingReconciliation {
            guard engine.status == .ready else { return }
            pendingReconciliation = false
            reconcileLoaded()
            return
        }
        guard !intendedPause, let currentSlot else { return }
        if !isDelayed, state == .playing, engine.status == .ready,
           !engine.isPaused, engine.preventsDisplaySleep,
           abs(engine.currentTime - currentSlot.offset(at: clock())) > 3 {
            state = .loading
            loadingStarted = uptime()
            reconcileLoaded()
            return
        }
        if isDelayed, currentSlot.start.addingTimeInterval(engine.currentTime) < clock().addingTimeInterval(-86_400) {
            engine.pause()
            fail(.historyExpired)
        }
    }

    private func prepare(at date: Date) {
        let previous = task
        previous?.cancel()
        generation = UUID()
        let stamp = generation
        coverage.discontinuity()
        pendingReconciliation = false
        state = .loading
        loadingStarted = uptime()
        preparedCursor = date
        do {
            guard let schedule = schedule() else { throw LibraryChannelError.snapshotUnavailable }
            guard generation == stamp else { return }
            currentSlot = try schedule.slot(at: date)
            if let slot = currentSlot, coverageSlotID != slot.id {
                coverage = LibraryChannelWatchCoverage(duration: Double(slot.item.durationSeconds))
                secondsWatched = 0
                reportedCompletion = false
                coverageSlotID = slot.id
            }
            request = nil
            completionProvider = nil
        } catch {
            loadingStarted = nil
            engine.stop(preserveDisplayMode: true)
            fail(Self.playbackIssue(error))
            return
        }
        engine.onEnded = nil
        engine.onFailure = nil
        engine.pause()
        onSourceReset?()
        guard generation == stamp else { return }
        task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, !Task.isCancelled, self.generation == stamp else { return }
            await self.load(at: date, stamp: stamp)
        }
    }

    private func load(at requestedDate: Date, stamp: UUID) async {
        do {
            try check(stamp)
            guard requestedDate >= clock().addingTimeInterval(-86_400) else { throw LibraryChannelError.historyExpired }
            guard let schedule = schedule() else { throw LibraryChannelError.snapshotUnavailable }
            try check(stamp)
            let slot = try schedule.slot(at: requestedDate)
            currentSlot = slot
            guard let provider = provider(slot.item) else { throw LibraryChannelError.sourceUnavailable }
            try check(stamp)
            engine.onEnded = nil
            engine.onFailure = nil
            engine.stop(preserveDisplayMode: true)
            await engine.drainTransport()
            try check(stamp)
            var resolved = try await provider.libraryChannelPlayback(for: slot.item)
            try check(stamp)
            guard self.provider(slot.item) != nil else { throw LibraryChannelError.sourceUnavailable }
            guard !resolved.isTranscoding, resolved.deliveryMode == .directPlay else {
                throw LibraryChannelError.incompatiblePlaybackMode
            }
            let target = isDelayed ? pausedCursor ?? requestedDate : clock()
            let resolvedSlot = try schedule.slot(at: target)
            if resolvedSlot.id != slot.id {
                prepare(at: target)
                return
            }
            resolved.startPosition = slot.offset(at: target)
            resolved.suppressOrdinaryWatchReporting = true
            resolved.preferredAudioLanguages = preferredAudioLanguages
            resolved.preferredSubtitleLanguages = preferredSubtitleLanguages
            request = resolved
            completionProvider = provider
            engine.onEnded = { [weak self] in
                guard let self, self.generation == stamp,
                      self.authorization() == self.activeAuthorization else { return }
                self.ended()
            }
            engine.onFailure = { [weak self] error in
                guard let self, self.generation == stamp,
                      self.authorization() == self.activeAuthorization else { return }
                self.coverage.discontinuity()
                self.pendingReconciliation = false
                self.loadingStarted = nil
                self.fail(Self.playbackIssue(error))
            }
            await engine.load(request: resolved, startPosition: resolved.startPosition)
            try check(stamp)
            if case .unavailable = state { return }
            if case .failed(let error) = engine.status { throw Self.playbackIssue(error) }
            pendingReconciliation = true
            if engine.status == .ready { reconcileLoaded() }
        } catch is CancellationError {
        } catch {
            guard stamp == generation else { return }
            engine.stop(preserveDisplayMode: true)
            loadingStarted = nil
            fail(Self.playbackIssue(error))
        }
    }

    private func reconcileLoaded() {
        guard let slot = currentSlot else { return }
        pendingReconciliation = false
        if !isDelayed, clock() >= slot.end {
            prepare(at: clock())
            return
        }
        if intendedPause {
            engine.pause()
            let target = slot.offset(at: pausedCursor ?? preparedCursor ?? clock())
            if abs(engine.currentTime - target) > 1 {
                let stamp = generation
                task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.coverage.discontinuity()
                    await self.engine.seek(to: target, kind: .exact)
                    guard !Task.isCancelled, self.generation == stamp else { return }
                    guard self.authorization() == self.activeAuthorization else {
                        self.stop()
                        self.fail(.authorizationChanged)
                        return
                    }
                    if case .unavailable = self.state { return }
                    self.loadingStarted = nil
                    if self.intendedPause { self.engine.pause(); self.state = .paused }
                    else { self.engine.play(); self.state = .playing }
                }
            } else {
                state = .paused
                loadingStarted = nil
            }
            return
        }
        let target = isDelayed ? engine.currentTime : slot.offset(at: clock())
        if abs(engine.currentTime - target) > 1 {
            let stamp = generation
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                self.coverage.discontinuity()
                var desired = target
                for attempt in 0..<3 {
                    await self.engine.seek(to: desired, kind: .exact)
                    guard !Task.isCancelled, self.generation == stamp else { return }
                    guard self.authorization() == self.activeAuthorization else {
                        self.stop()
                        self.fail(.authorizationChanged)
                        return
                    }
                    if !self.isDelayed, self.clock() >= slot.end { self.prepare(at: self.clock()); return }
                    let latest = self.isDelayed ? desired : slot.offset(at: self.clock())
                    if abs(latest - self.engine.currentTime) <= 2 { break }
                    if attempt == 2 {
                        self.engine.pause()
                        self.fail(.unableToJoinLive)
                        return
                    }
                    desired = latest
                }
                self.loadingStarted = nil
                if self.intendedPause {
                    self.engine.pause()
                    self.state = .paused
                } else if case .unavailable = self.state {
                    self.engine.pause()
                } else {
                    self.engine.play()
                    self.state = .playing
                }
            }
        } else {
            engine.play()
            state = .playing
            loadingStarted = nil
        }
    }

    private func ended() {
        sampleHistory()
        coverage.discontinuity()
        guard let slot = currentSlot else { return }
        if isDelayed { prepare(at: slot.end) }
        else if clock() >= slot.end { prepare(at: clock()) }
        else {
            // A shortened/missing cut does not shift the virtual broadcast.
            engine.pause()
            fail(.mediaChanged)
        }
    }

    private func check(_ stamp: UUID) throws {
        try Task.checkCancellation()
        guard stamp == generation, activeAuthorization != nil,
              authorization() == activeAuthorization else { throw LibraryChannelError.authorizationChanged }
    }

    private func sampleHistory() {
        let currentToken = historyAuthorization()
        if currentToken != historyToken {
            cancelHistoryTasks()
            coverage = LibraryChannelWatchCoverage(duration: Double(currentSlot?.item.durationSeconds ?? 0))
            secondsWatched = 0
            historyToken = currentToken
            reportedCompletion = false
        }
        guard currentToken != nil else { return }
        coverage.sample(
            position: engine.currentTime, instant: uptime(),
            isPlaying: isWatching && state == .playing && engine.status == .ready
                && !engine.isPaused && engine.preventsDisplaySleep
        )
        secondsWatched = coverage.secondsWatched
        guard isWatching, state == .playing, coverage.isComplete, !reportedCompletion, let token = currentToken,
              let request, let scheduledItem = currentSlot?.item, let provider = completionProvider else { return }
        guard historyTasks.count < 4 else { historyIssue = true; return }
        reportedCompletion = true
        let percent = coverage.watchedPercent
        let id = UUID()
        let expectedAuthorization = activeAuthorization
        historyTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.historyTasks[id] = nil }
            guard !Task.isCancelled, self.historyAuthorization() == token,
                  expectedAuthorization != nil, self.authorization() == expectedAuthorization else { return }
            do {
                switch self.historyReporting {
                case .externalCompletion(let sink):
                    try await sink(scheduledItem, request.item, token)
                case .sourceAndTrakt(let scrobbler, let onCompleted):
                    try await provider.recordLibraryChannelCompletion(itemID: request.item.id)
                    guard !Task.isCancelled, self.historyAuthorization() == token,
                          self.authorization() == expectedAuthorization else { return }
                    await scrobbler.scrobble(item: request.item, progress: percent, event: .stop)
                    guard !Task.isCancelled, self.historyAuthorization() == token,
                          self.authorization() == expectedAuthorization else { return }
                    await onCompleted(scheduledItem, request.item, token)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, self.historyAuthorization() == token,
                   self.authorization() == expectedAuthorization { self.historyIssue = true }
            }
        }
    }

    private func cancelHistoryTasks() {
        for task in historyTasks.values { task.cancel() }
        historyTasks.removeAll()
    }

    private func fail(_ error: LibraryChannelError) {
        guard state != .unavailable(error) else { return }
        state = .unavailable(error)
        onPlaybackFailure?(error)
    }

    private static func playbackIssue(_ error: any Error) -> LibraryChannelError {
        if let error = error as? LibraryChannelError { return error }
        switch error as? AppError {
        case .unauthorized, .invalidCredentials: return .authorizationChanged
        case .serverUnreachable, .rateLimited: return .sourceUnavailable
        case .notFound: return .mediaChanged
        default: return .playbackFailed
        }
    }
}
#endif
