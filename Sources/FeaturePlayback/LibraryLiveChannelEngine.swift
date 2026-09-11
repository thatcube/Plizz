#if DEBUG && canImport(AVFoundation)
import CoreModels
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import AVKit
#endif

/// One retained decoder for both server streams and scheduled library programmes.
@MainActor
public final class LibraryLiveChannelEngine: LiveChannelEngine {
    public typealias LibrarySessionFactory =
        @MainActor (UUID, String, any VideoEngine) throws -> LibraryChannelPlaybackSession

    public let underlyingEngine: any LiveChannelEngine
    public private(set) var currentInput: LiveChannelInput?
    public private(set) var librarySession: LibraryChannelPlaybackSession?
    public private(set) var isWatching = false
    public var recoverableProgrammeIssue: LibraryChannelError? {
        librarySession?.recoverableProgrammeIssue
    }

    private let librarySessionFactory: LibrarySessionFactory?
    private var generation = UUID()
    private var callbackGeneration = UUID()
    private var operation: Task<Void, Error>?
    private var operationID: UUID?
    private var cleanup: Task<Void, Never>?
    private var isLoading = false
    private var initialErrorsAreThrown = false
    private var hasSource = false
    private var intendedPause = false
    private var loadFailure: AppError?
    private var outputPolicy = LiveChannelOutputPolicy()

    public init(
        engine: any LiveChannelEngine,
        librarySessionFactory: LibrarySessionFactory? = nil
    ) {
        underlyingEngine = engine
        self.librarySessionFactory = librarySessionFactory
    }

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    public var onTracksChanged: (@MainActor () -> Void)?
    public var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    public var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    public var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    public var onLiveSourceReset: (@MainActor () -> Void)?
    /// Invalidates programme-local tracks, subtitle cues and presentation timing.
    /// Unlike onLiveSourceReset, this must not request a channel retune.
    public var onProgrammeChanged: (@MainActor () -> Void)?
    #if os(iOS)
    public var onPresentationLayerChanged: (() -> Void)? {
        didSet { installPresentationCallback(stamp: generation) }
    }
    #endif

    public func loadChannel(_ input: LiveChannelInput) async throws {
        let result = await loadChannelResult(input, initialErrorsAreThrown: true)
        try result.get()
    }

    private func loadChannelResult(
        _ input: LiveChannelInput, initialErrorsAreThrown: Bool = false
    ) async -> Result<Void, Error> {
        if currentInput == input, operation == nil, let session = librarySession {
            isLoading = true
            self.initialErrorsAreThrown = initialErrorsAreThrown
            loadFailure = nil
            return await operateOnCurrentSource { [self] in
                session.retry()
                if intendedPause { session.pause() }
                try await session.waitUntilSettled()
            }
        }
        return await replaceSource(input: input, initialErrorsAreThrown: initialErrorsAreThrown) { [self] stamp in
            switch input {
            case .stream(let url, let headers):
                installCallbacks(stamp: stamp, scheduled: false)
                await underlyingEngine.loadLive(url: url, httpHeaders: headers)
            case .libraryChannel(let id, let authorizationID):
                guard !authorizationID.isEmpty else { throw LibraryChannelError.authorizationChanged }
                guard let librarySessionFactory else { throw LiveChannelInputError.unsupportedSource }
                let session = try librarySessionFactory(id, authorizationID, underlyingEngine)
                guard session.channelID == id,
                      session.engine === underlyingEngine else {
                    throw LiveChannelInputError.unsupportedSource
                }
                librarySession = session
                installCallbacks(stamp: stamp, scheduled: true)
                session.onSourceReset = { [weak self, weak session] in
                    guard let self, let session, self.generation == stamp,
                          self.librarySession === session else { return }
                    self.installCallbacks(stamp: stamp, scheduled: true)
                    self.onProgrammeChanged?()
                }
                session.onPlaybackFailure = { [weak self, weak session] error in
                    guard let self, let session, self.generation == stamp,
                          self.librarySession === session,
                          session.recoverableProgrammeIssue == nil else { return }
                    self.notifyFailure(error)
                }
                session.setWatching(isWatching)
                session.tune()
                if intendedPause { session.pause() }
                try await session.waitUntilSettled()
            }
        }
    }

    public func loadLive(url: URL, httpHeaders: [String: String]) async {
        _ = await loadChannelResult(.stream(url: url, httpHeaders: httpHeaders))
    }

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        _ = await replaceSource(input: nil) { [self] stamp in
            installCallbacks(stamp: stamp, scheduled: false)
            await underlyingEngine.load(request: request, startPosition: startPosition)
        }
    }

    private func replaceSource(
        input: LiveChannelInput?,
        initialErrorsAreThrown: Bool = false,
        load: @escaping @MainActor (UUID) async throws -> Void
    ) async -> Result<Void, Error> {
        let barrier = invalidateSource(preserveDisplayMode: true)
        let stamp = generation
        currentInput = input
        hasSource = true
        isLoading = true
        self.initialErrorsAreThrown = initialErrorsAreThrown
        let next = Task { @MainActor [weak self] in
            await barrier.value
            guard let self else { throw CancellationError() }
            try self.check(stamp)
            try await load(stamp)
            try self.checkCompletion(stamp)
        }
        let id = UUID()
        operationID = id
        operation = next
        return await finishOperation(next, stamp: stamp, id: id)
    }

    /// Initial typed loads return their original error without a generic callback
    /// preempting the caller's typed catch. Legacy Void APIs and later failures
    /// publish once through status/onFailure; cancellation and gaps are nonfatal.
    private func finishOperation(
        _ next: Task<Void, Error>, stamp: UUID, id: UUID
    ) async -> Result<Void, Error> {
        do {
            try await withTaskCancellationHandler {
                try await next.value
                try Task.checkCancellation()
            } onCancel: {
                next.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == stamp else { return }
                    self.stop()
                }
            }
            try check(stamp)
            if intendedPause { pause() }
            isLoading = false
            if operationID == id {
                operation = nil
                operationID = nil
            }
            return .success(())
        } catch {
            guard generation == stamp else { return .failure(CancellationError()) }
            let publishesFailure = !isLoading || !initialErrorsAreThrown
            isLoading = false
            if operationID == id {
                operation = nil
                operationID = nil
            }
            if Self.isCancellation(error) {
                stop()
                return .failure(CancellationError())
            } else if recoverableProgrammeIssue == nil {
                notifyFailure(error, publish: publishesFailure)
            }
            return .failure(error)
        }
    }

    /// Every source waits for the preceding load AND teardown, including loads
    /// whose provider ignores cancellation. No old task can stop a newer pane.
    @discardableResult
    private func invalidateSource(preserveDisplayMode: Bool) -> Task<Void, Never> {
        generation = UUID()
        let previous = operation
        let previousCleanup = cleanup
        let session = librarySession
        let hadSource = hasSource
        previous?.cancel()
        operation = nil
        operationID = nil
        librarySession = nil
        currentInput = nil
        hasSource = false
        isLoading = false
        initialErrorsAreThrown = false
        loadFailure = nil
        clearCallbacks()
        if let session {
            session.onSourceReset = nil
            session.onPlaybackFailure = nil
            session.setWatching(false)
            session.stop()
        } else if hadSource {
            underlyingEngine.stop(preserveDisplayMode: preserveDisplayMode || outputPolicy.sharesAudioSession)
        }
        let engine = underlyingEngine
        let preserve = preserveDisplayMode || outputPolicy.sharesAudioSession
        let barrier = Task { @MainActor in
            if let previousCleanup { await previousCleanup.value }
            if let previous { _ = await previous.result }
            if let session {
                await session.stopAndDrain()
            } else if hadSource {
                engine.stop(preserveDisplayMode: preserve)
                await engine.drainTransport()
            }
        }
        cleanup = barrier
        return barrier
    }

    private func check(_ stamp: UUID) throws {
        try Task.checkCancellation()
        guard generation == stamp, hasSource else { throw CancellationError() }
    }

    private func checkCompletion(_ stamp: UUID) throws {
        try check(stamp)
        guard librarySession == nil else { return }
        if let loadFailure { throw loadFailure }
        if case .failed(let error) = underlyingEngine.status { throw error }
    }

    public func play() {
        intendedPause = false
        if let librarySession { librarySession.resume() }
        else if hasSource { underlyingEngine.play() }
    }

    public func pause() {
        intendedPause = true
        if let librarySession { librarySession.pause() }
        else if hasSource { underlyingEngine.pause() }
    }

    public func stop() { stop(preserveDisplayMode: false) }

    public func stop(preserveDisplayMode: Bool) {
        invalidateSource(preserveDisplayMode: preserveDisplayMode)
        intendedPause = false
    }

    public func drainTransport() async {
        if let cleanup { await cleanup.value }
    }

    public func reloadAfterForeground() async throws {
        let result = await operateOnCurrentSource { [self] in
            if let librarySession {
                librarySession.foreground()
                if intendedPause { librarySession.pause() }
                try await librarySession.waitUntilSettled()
            } else {
                try await underlyingEngine.reloadAfterForeground()
            }
        }
        try result.get()
    }

    public func seekToLiveEdge() async {
        _ = await operateOnCurrentSource { [self] in
            if let librarySession {
                librarySession.goLive()
                if intendedPause { librarySession.pause() }
                try await librarySession.waitUntilSettled()
            } else {
                await underlyingEngine.seekToLiveEdge()
            }
        }
    }

    // Library schedules own their cursor; a VOD seek is not a broadcast DVR.
    public func seek(to seconds: TimeInterval) async {
        guard hasSource, librarySession == nil else { return }
        _ = await operateOnCurrentSource { [self] in
            await underlyingEngine.seek(to: seconds)
        }
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        guard hasSource, librarySession == nil else { return }
        _ = await operateOnCurrentSource { [self] in
            await underlyingEngine.seek(to: seconds, kind: kind)
        }
    }

    private func operateOnCurrentSource(
        _ action: @escaping @MainActor () async throws -> Void
    ) async -> Result<Void, Error> {
        guard hasSource else { return .success(()) }
        let stamp = generation
        let previous = operation
        let next = Task { @MainActor [weak self] in
            if let previous { _ = await previous.result }
            guard let self else { throw CancellationError() }
            try self.check(stamp)
            try await action()
            try self.checkCompletion(stamp)
        }
        let id = UUID()
        operationID = id
        operation = next
        return await finishOperation(next, stamp: stamp, id: id)
    }

    public func setWatching(_ isWatching: Bool) {
        self.isWatching = isWatching
        librarySession?.setWatching(isWatching)
        underlyingEngine.setWatching(isWatching)
    }

    public var supportsConcurrentPlayback: Bool { underlyingEngine.supportsConcurrentPlayback }

    public func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {
        outputPolicy = policy
        underlyingEngine.configureLiveOutput(policy)
    }

    public var liveSnapshot: LiveChannelEngineSnapshot {
        guard hasSource else { return .init() }
        guard let librarySession else {
            if loadFailure != nil { return .init(phase: .failed) }
            return isLoading ? .init(phase: .loading) : underlyingEngine.liveSnapshot
        }
        let decoder = underlyingEngine.liveSnapshot
        let phase: LiveChannelEnginePhase
        switch librarySession.state {
        case .idle: phase = .idle
        case .loading: phase = .loading
        case .unavailable: phase = .failed
        case .paused: phase = .paused
        case .playing: phase = decoder.phase
        }
        let mayPresent = librarySession.state == .playing || librarySession.state == .paused
        return .init(
            phase: phase,
            firstFrameReady: !isLoading && mayPresent && decoder.firstFrameReady,
            position: decoder.position,
            bufferedPosition: decoder.bufferedPosition,
            seekableRange: nil,
            behindLiveSeconds: librarySession.behindLiveSeconds,
            route: decoder.route
        )
    }

    public var status: VideoEngineStatus {
        guard hasSource else { return .idle }
        if let librarySession {
            switch librarySession.state {
            case .idle: return .idle
            case .loading: return .loading
            case .unavailable(let error): return .failed(Self.appError(error))
            case .playing, .paused: return underlyingEngine.status
            }
        }
        if let loadFailure { return .failed(loadFailure) }
        return isLoading ? .loading : underlyingEngine.status
    }

    private static func appError(_ error: any Error) -> AppError {
        if let error = error as? AppError { return error }
        if let error = error as? LibraryChannelError {
            return .unknown(String(localized: error.message))
        }
        return .invalidResponse
    }

    private func notifyFailure(_ error: any Error, publish: Bool? = nil) {
        if Self.isCancellation(error) {
            stop()
            return
        }
        let mapped = Self.appError(error)
        guard loadFailure != mapped else { return }
        loadFailure = mapped
        if publish ?? (!isLoading || !initialErrorsAreThrown) {
            onFailure?(mapped)
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AppError) == .cancelled
    }

    private func installCallbacks(stamp: UUID, scheduled: Bool) {
        callbackGeneration = UUID()
        let callbackStamp = callbackGeneration
        #if os(iOS)
        installPresentationCallback(stamp: stamp)
        #endif
        underlyingEngine.onProgress = { [weak self] in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onProgress?()
        }
        underlyingEngine.onTracksChanged = { [weak self] in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onTracksChanged?()
        }
        underlyingEngine.onProbedSourceFactsChanged = { [weak self] facts in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onProbedSourceFactsChanged?(facts)
        }
        underlyingEngine.onSubtitleCues = { [weak self] cues in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onSubtitleCues?(cues)
        }
        underlyingEngine.onSecondarySubtitleCues = { [weak self] cues in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onSecondarySubtitleCues?(cues)
        }
        underlyingEngine.onLiveSourceReset = { [weak self] in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            if scheduled { self.librarySession?.retry() }
            else { self.onLiveSourceReset?() }
        }
        if !scheduled {
            underlyingEngine.onFailure = { [weak self] error in
                guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
                self.notifyFailure(error)
            }
            underlyingEngine.onEnded = { [weak self] in
                guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
                self.onEnded?()
            }
        }
    }

    private func clearCallbacks() {
        underlyingEngine.onProgress = nil
        underlyingEngine.onFailure = nil
        underlyingEngine.onEnded = nil
        underlyingEngine.onTracksChanged = nil
        underlyingEngine.onProbedSourceFactsChanged = nil
        underlyingEngine.onSubtitleCues = nil
        underlyingEngine.onSecondarySubtitleCues = nil
        underlyingEngine.onLiveSourceReset = nil
        #if os(iOS)
        presentationEngine?.onPresentationLayerChanged = nil
        #endif
    }

    public var displayName: String { underlyingEngine.displayName }
    public var capabilities: PlayerEngineCapabilities { underlyingEngine.capabilities }
    public var isPaused: Bool { !hasSource || intendedPause || underlyingEngine.isPaused }
    public var preventsDisplaySleep: Bool {
        hasSource && !isLoading && !isPaused
            && liveSnapshot.phase == .playing && underlyingEngine.preventsDisplaySleep
    }
    public var currentTime: TimeInterval { hasSource ? underlyingEngine.currentTime : 0 }
    public var duration: TimeInterval { librarySession == nil ? underlyingEngine.duration : 0 }
    public var furthestObservedPosition: TimeInterval { underlyingEngine.furthestObservedPosition }
    public var bufferedPosition: TimeInterval { underlyingEngine.bufferedPosition }
    public var liveTelemetry: EngineLiveTelemetry? { underlyingEngine.liveTelemetry }
    public var probedSourceFacts: EngineProbedSourceFacts? { underlyingEngine.probedSourceFacts }
    public var videoAspectRatio: Double? { underlyingEngine.videoAspectRatio }
    public var audioTracks: [MediaTrack] { underlyingEngine.audioTracks }
    public var subtitleTracks: [MediaTrack] { underlyingEngine.subtitleTracks }
    public var currentAudioTrackID: Int? { underlyingEngine.currentAudioTrackID }
    public func selectAudioTrack(_ track: MediaTrack?) { underlyingEngine.selectAudioTrack(track) }
    public func selectSubtitleTrack(_ track: MediaTrack?) { underlyingEngine.selectSubtitleTrack(track) }
    public func selectSecondarySubtitleTrack(_ track: MediaTrack?) { underlyingEngine.selectSecondarySubtitleTrack(track) }
    public func setPlaybackSpeed(_ rate: Double) { underlyingEngine.setPlaybackSpeed(rate) }
    public func setAudioDelay(_ seconds: TimeInterval) { underlyingEngine.setAudioDelay(seconds) }
    public func setSubtitleDelay(_ seconds: TimeInterval) { underlyingEngine.setSubtitleDelay(seconds) }
    public func updateSubtitleStyle(_ style: SubtitleStyle) { underlyingEngine.updateSubtitleStyle(style) }
    public func setDialogEnhanceEnabled(_ enabled: Bool) { underlyingEngine.setDialogEnhanceEnabled(enabled) }
    public func setScrubRefreshBoost(_ enabled: Bool) { underlyingEngine.setScrubRefreshBoost(enabled) }
    #if canImport(UIKit)
    public func makeVideoOutputView() -> UIView { underlyingEngine.makeVideoOutputView() }
    #endif
}

#if os(iOS)
extension LibraryLiveChannelEngine: PictureInPicturePresentingEngine {
    private var presentationEngine: (any PictureInPicturePresentingEngine)? {
        underlyingEngine as? any PictureInPicturePresentingEngine
    }
    public func pictureInPicturePlayerLayer() -> AVPlayerLayer? {
        presentationEngine?.pictureInPicturePlayerLayer()
    }
    public func setPictureInPictureActive(_ active: Bool) {
        presentationEngine?.setPictureInPictureActive(active)
    }
    public var continuesPlaybackInBackground: Bool {
        presentationEngine?.continuesPlaybackInBackground ?? false
    }
    public var externalPlaybackRouteName: String? { presentationEngine?.externalPlaybackRouteName }
    private func installPresentationCallback(stamp: UUID) {
        guard onPresentationLayerChanged != nil else {
            presentationEngine?.onPresentationLayerChanged = nil
            return
        }
        let callbackStamp = callbackGeneration
        presentationEngine?.onPresentationLayerChanged = { [weak self] in
            guard let self, self.generation == stamp, self.callbackGeneration == callbackStamp else { return }
            self.onPresentationLayerChanged?()
        }
    }
    public func setNativeSubtitlesActive(_ active: Bool) {
        presentationEngine?.setNativeSubtitlesActive(active)
    }
}
#endif
#endif
