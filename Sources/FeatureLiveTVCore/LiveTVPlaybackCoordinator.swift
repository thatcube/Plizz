#if DEBUG
import CoreModels
import Foundation
import Observation

public struct LiveTVWatchFailure: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let channelID: String
    public let error: LiveTVPlaybackPreparationError
    public let isGuideOnly: Bool
    public let currentToStop: UUID?

    public var message: LocalizedStringResource {
        if isGuideOnly {
            return "This server provides channel listings, but its Live TV playback mode isn't supported yet. You can browse the guide or watch from another source."
        }
        return error.userDescription
    }
}

/// Serializes playback intent, not player presentation. Preview and Watch share
/// one preparation owner; only deliberate Watch can expand the persistent player.
@MainActor
@Observable
public final class LiveTVPlaybackCoordinator {
    public private(set) var preparation: LiveTVPlaybackPreparation
    public private(set) var pendingWatchChannelID: String?
    public private(set) var watchFailure: LiveTVWatchFailure?
    public private(set) var isActive = true
    public private(set) var isInteractionActive = true
    public private(set) var acceptedWatchID: UUID?
    public private(set) var presentationID = UUID()
    private var cleanupCount = 0
    private var suppressedPreviewChannelID: String?

    public var isCleaningUp: Bool { cleanupCount > 0 }
    public var canAutoPreview: Bool {
        isActive && isInteractionActive && !isCleaningUp
            && pendingWatchChannelID == nil && watchFailure == nil
            && suppressedPreviewChannelID == nil
    }

    @ObservationIgnored private let model: LiveTVPrototypeModel
    @ObservationIgnored private let preview: LiveTVPreviewController
    @ObservationIgnored private let reference: @MainActor (String) -> LiveTVServerChannelReference?
    @ObservationIgnored private let authorizes: @MainActor @Sendable (
        LiveTVPrototypeChannel, LiveTVServerChannelReference?
    ) -> Bool
    @ObservationIgnored private let guideOnly: @MainActor (String) -> Bool
    @ObservationIgnored private var watchID: UUID?
    @ObservationIgnored private var watchTask: Task<Bool, Never>?
    @ObservationIgnored private var previewTask: Task<Bool, Never>?
    @ObservationIgnored private var previewTaskID: UUID?
    @ObservationIgnored private var previewTaskChannelID: String?
    @ObservationIgnored private var focusedChannelID: String?
    @ObservationIgnored private var pendingTarget: Target?
    @ObservationIgnored private var failedTarget: Target?
    @ObservationIgnored private var failedWatchID: UUID?
    @ObservationIgnored private var reportTail: Task<Void, Never>?
    @ObservationIgnored private var reportID: UUID?
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var interactionRevision = UUID()
    @ObservationIgnored private var hasPlayerPresentation = false

    private struct Target {
        let channel: LiveTVPrototypeChannel
        let reference: LiveTVServerChannelReference?
        let origin: LiveTVGuideRowID?
    }

    public init(
        model: LiveTVPrototypeModel,
        preview: LiveTVPreviewController,
        preparation: LiveTVPlaybackPreparation,
        reference: @escaping @MainActor (String) -> LiveTVServerChannelReference?,
        isAuthorized: @escaping @MainActor @Sendable (
            LiveTVPrototypeChannel, LiveTVServerChannelReference?
        ) -> Bool,
        isGuideOnly: @escaping @MainActor (String) -> Bool = { _ in false }
    ) {
        self.model = model
        self.preview = preview
        self.preparation = preparation
        self.reference = reference
        self.authorizes = isAuthorized
        self.guideOnly = isGuideOnly
    }

    /// The view owns the cancellable 600 ms focus-settling delay.
    @discardableResult
    public func preparePreview(_ request: LiveTVPreviewRequest) async -> Bool {
        guard canAutoPreview, !Task.isCancelled,
              preview.pendingRequest == request, !guideOnly(request.channelID),
              let channel = model.channel(id: request.channelID) else { return false }
        cancelPreviewPreparation()
        let serverReference = reference(channel.id)
        let boundary = lifecycle
        let interaction = interactionRevision
        let id = UUID()
        previewTaskID = id
        previewTaskChannelID = request.channelID
        let task = Task { @MainActor [weak self] in
            guard let self, self.canAutoPreview, self.previewTaskID == id,
                  self.interactionRevision == interaction, !Task.isCancelled else { return false }
            return await self.preparation.prepare(
                channel, serverReference: serverReference,
                isAuthorized: self.authorization(for: channel, reference: serverReference, boundary: boundary)
            ) { [weak self] in
                guard let self, self.canAutoPreview, self.previewTaskID == id,
                      self.lifecycle == boundary, self.interactionRevision == interaction,
                      !Task.isCancelled else { return false }
                let committed = self.preview.commitPreview(request)
                if !committed { self.model.clearTuneFailure() }
                return committed
            }
        }
        previewTask = task
        let accepted = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if previewTaskID == id {
            previewTask = nil
            previewTaskID = nil
            previewTaskChannelID = nil
        }
        synchronizePlayerState()
        return accepted
    }

    @discardableResult
    public func watch(
        _ channelID: String,
        origin: LiveTVGuideRowID? = nil
    ) -> Task<Bool, Never> {
        cancelWatch()
        guard isActive, isInteractionActive, let channel = model.channel(id: channelID) else {
            return Task { false }
        }
        cancelPreviewPreparation()
        suppressedPreviewChannelID = nil
        return beginWatch(Target(
            channel: channel, reference: reference(channelID), origin: origin
        ))
    }

    /// Explicit recovery only. A stale alert never stops a replacement stream.
    @discardableResult
    public func stopCurrentAndRetry(_ failure: LiveTVWatchFailure) -> Task<Bool, Never> {
        guard failure.id == failedWatchID, failure.error == .tunerUnavailable,
              let currentID = failure.currentToStop, preparation.current?.id == currentID,
              let target = failedTarget, isActive, isInteractionActive,
              authorizes(target.channel, target.reference) else { return Task { false } }
        cancelWatch()
        cancelPreviewPreparation()
        suppressedPreviewChannelID = nil
        return beginWatch(target, stopping: currentID)
    }

    public func dismissFailure() {
        watchFailure = nil
    }

    public func cancelWatch() {
        suppressPreview(of: pendingWatchChannelID)
        watchID = nil
        pendingWatchChannelID = nil
        pendingTarget = nil
        watchTask?.cancel()
        watchTask = nil
        dismissFailure()
        failedTarget = nil
        failedWatchID = nil
    }

    /// Only a different channel is fresh focus. Losing focus or moving between
    /// programmes on the same channel cannot resurrect a cancelled request.
    public func focus(_ channelID: String?) {
        if let channelID, channelID != focusedChannelID {
            focusedChannelID = channelID
            if isInteractionActive { suppressedPreviewChannelID = nil }
        }
        preview.focus(channelID)
    }

    /// Temporary inactivity cancels interaction, not the retained playing lease.
    /// Current authority/reporting intentionally does not depend on this gate.
    public func setInteractionActive(_ active: Bool) {
        guard isInteractionActive != active else { return }
        isInteractionActive = active
        interactionRevision = UUID()
        if !active {
            suppressPreview(of: pendingWatchChannelID ?? previewTaskChannelID ?? preview.pendingRequest?.channelID)
            cancelWatch()
            cancelPreviewPreparation()
            preview.setBrowsingActive(false)
        }
    }

    public func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { stop() }
    }

    public func stop() {
        lifecycle = UUID()
        suppressPreview(of: pendingWatchChannelID ?? previewTaskChannelID)
        cancelWatch()
        cancelPreviewPreparation()
        preparation.stop()
        preview.stop()
        retirePresentation()
    }

    /// Multiview promotes an already playing owner; no stream is reopened.
    @discardableResult
    public func adoptPreparation(_ replacement: LiveTVPlaybackPreparation) -> Bool {
        guard isActive else { return false }
        replacement.validateAuthorization()
        if let current = replacement.current, !authorizes(current.channel, current.serverReference) {
            replacement.failCurrent(id: current.id, reason: .sourceUnavailable)
        }
        cancelWatch()
        cancelPreviewPreparation()
        preparation = replacement
        reportTail = nil
        reportID = nil
        suppressedPreviewChannelID = nil
        if let current = replacement.current { preview.watch(current.channel.id) }
        synchronizePlayerState()
        acceptedWatchID = UUID()
        return replacement.current != nil
    }

    private func suppressPreview(of channelID: String?) {
        guard let channelID else { return }
        suppressedPreviewChannelID = channelID
        focusedChannelID = channelID
    }

    private func cancelPreviewPreparation() {
        previewTask?.cancel()
        previewTask = nil
        previewTaskID = nil
        previewTaskChannelID = nil
    }

    public func validateAuthorization() {
        preparation.validateAuthorization()
        if let pendingTarget, !authorizes(pendingTarget.channel, pendingTarget.reference) {
            cancelWatch()
        }
        if let failedTarget, !authorizes(failedTarget.channel, failedTarget.reference) {
            dismissFailure()
            self.failedTarget = nil
            failedWatchID = nil
        }
        synchronizePlayerState()
    }

    /// Enqueue synchronously on MainActor before crossing any async boundary.
    /// Every queued callback rechecks local ownership, never a server handle.
    @discardableResult
    public func report(_ update: LiveTVPlaybackUpdate, for id: UUID) -> Task<Void, Never> {
        guard isActive, preparation.current?.id == id else { return Task {} }
        if reportID != id {
            reportTail = nil
            reportID = id
        }
        let previous = reportTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.isActive, self.preparation.current?.id == id else { return }
            await self.preparation.report(update, for: id)
            self.synchronizePlayerState()
        }
        reportTail = task
        return task
    }

    public func playbackFailed(_ id: UUID) {
        guard let current = preparation.current, current.id == id else { return }
        let notify = preview.isExpanded && watchID == nil && !preparation.isPreparing
        preparation.failCurrent(id: id)
        synchronizePlayerState()
        if notify {
            watchFailure = LiveTVWatchFailure(
                id: UUID(), channelID: current.channel.id, error: .playbackFailed,
                isGuideOnly: false, currentToStop: nil
            )
        }
    }

    public func confirmWatching(_ id: UUID) {
        validateAuthorization()
        guard isActive, preview.isExpanded, let current = preparation.current,
              current.id == id else { return }
        _ = model.recordWatched(current.channel.id)
    }

    public func synchronizePlayerState() {
        guard preparation.current == nil else {
            hasPlayerPresentation = true
            return
        }
        if hasPlayerPresentation { retirePresentation() }
        model.stop()
        // A terminal old player callback must not cancel a different candidate.
        if watchID == nil && !preparation.isPreparing && preview.pendingRequest == nil {
            preview.playbackEnded()
        }
    }

    /// Native fullscreen may retain its presentation-time dismissal callback.
    /// Normal channel changes keep this identity; retiring the host invalidates it.
    public func ownsPlayerPresentation(_ id: UUID) -> Bool {
        isActive && preparation.current != nil && presentationID == id
    }

    private func retirePresentation() {
        presentationID = UUID()
        hasPlayerPresentation = false
    }

    private func beginWatch(_ target: Target, stopping currentID: UUID? = nil) -> Task<Bool, Never> {
        let id = UUID()
        let boundary = lifecycle
        let interaction = interactionRevision
        watchID = id
        pendingWatchChannelID = target.channel.id
        pendingTarget = target
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                self.finishWatch(id)
                self.synchronizePlayerState()
            }
            guard self.watchID == id, self.isActive, self.isInteractionActive,
                  self.interactionRevision == interaction, !Task.isCancelled else { return false }
            let authorized = self.authorization(
                for: target.channel, reference: target.reference, boundary: boundary
            )
            if let currentID {
                guard self.preparation.current?.id == currentID,
                      let accountID = target.reference?.accountID, authorized() else {
                    self.finishWatch(id)
                    return false
                }
                let stopped = await self.stopCurrentAndWait(currentID: currentID, accountID: accountID)
                self.synchronizePlayerState()
                guard stopped, self.watchID == id, self.isInteractionActive,
                      self.interactionRevision == interaction, authorized(), !Task.isCancelled else { return false }
            }
            let isGuideOnly = self.guideOnly(target.channel.id)
            let committed: Bool
            if isGuideOnly {
                committed = false
            } else {
                committed = await self.preparation.prepare(
                    target.channel, serverReference: target.reference, isAuthorized: authorized
                ) { [weak self] in
                    guard let self, self.watchID == id, self.isActive, self.isInteractionActive,
                          self.lifecycle == boundary, self.interactionRevision == interaction,
                          !Task.isCancelled else { return false }
                    self.preview.watch(target.channel.id, origin: target.origin)
                    guard !self.model.tuneFailed else {
                        self.model.clearTuneFailure()
                        return false
                    }
                    return true
                }
            }
            guard self.watchID == id else { return false }
            self.finishWatch(id)
            if committed { self.acceptedWatchID = id }
            if !committed, !Task.isCancelled, self.isInteractionActive,
               self.interactionRevision == interaction, authorized() {
                let error = isGuideOnly ? .unsupportedPlaybackMode
                    : (self.preparation.failure ?? .preparationFailed)
                self.failedTarget = target
                self.failedWatchID = id
                self.watchFailure = LiveTVWatchFailure(
                    id: id, channelID: target.channel.id, error: error, isGuideOnly: isGuideOnly,
                    currentToStop: error == .tunerUnavailable ? self.relevantCurrent(for: target) : nil
                )
            }
            self.synchronizePlayerState()
            return committed
        }
        watchTask = task
        return task
    }

    private func stopCurrentAndWait(currentID: UUID, accountID: String) async -> Bool {
        cleanupCount += 1
        defer { cleanupCount -= 1 }
        // This scope outlives cancelWatch: cancellation must not reopen preview
        // while the server's consented cleanup is still draining.
        return await preparation.stopAndWait(currentID: currentID, accountID: accountID)
    }

    private func finishWatch(_ id: UUID) {
        guard watchID == id else { return }
        watchID = nil
        pendingWatchChannelID = nil
        pendingTarget = nil
        watchTask = nil
    }

    private func authorization(
        for channel: LiveTVPrototypeChannel,
        reference: LiveTVServerChannelReference?,
        boundary: UUID
    ) -> @MainActor @Sendable () -> Bool {
        { [weak self] in
            guard let self, self.isActive, self.lifecycle == boundary else { return false }
            return self.authorizes(channel, reference)
        }
    }

    private func relevantCurrent(for target: Target) -> UUID? {
        guard let current = preparation.current, let active = current.serverReference,
              let candidate = target.reference,
              current.channel.source == target.channel.source,
              active.accountID == candidate.accountID,
              active.authorizationID == candidate.authorizationID else { return nil }
        return current.id
    }
}

/// Playback authority comes from the entire live catalog and source membership,
/// not search, Favorites, hidden-channel, or guide-row visibility.
@MainActor
public enum LiveTVPlaybackCatalogAuthorization {
    public static func allows(
        _ channel: LiveTVPrototypeChannel,
        reference: LiveTVServerChannelReference?,
        model: LiveTVPrototypeModel,
        imports: LiveTVPrototypeImportModel,
        configuration: LiveTVSourcesConfiguration,
        libraryService: LibraryChannelService? = nil
    ) -> Bool {
        guard let live = model.channel(id: channel.id),
              live.source == channel.source, live.configuredSourceID == channel.configuredSourceID,
              live.streamURL == channel.streamURL, live.httpHeaders == channel.httpHeaders else { return false }
        if channel.source == .plozz {
            return reference == nil && libraryService?.channels.contains {
                $0.id == channel.id && $0.configuredSourceID == channel.configuredSourceID
            } == true
        }
        guard let sourceID = imports.configuredSourceIDByChannel[channel.id] else { return false }
        if let reference {
            return reference.sourceID == sourceID
                && imports.serverChannelReferences[channel.id] == reference
                && configuration.servers.contains {
                    $0.id == sourceID && $0.accountID == reference.accountID && $0.isEnabled
                }
        }
        guard imports.serverChannelReferences[channel.id] == nil,
              let source = configuration.playlists.first(where: { $0.id == sourceID && $0.isEnabled }),
              let imported = imports.configuration.playlists.first(where: { $0.id == sourceID })
        else { return false }
        return source.playlistURL == imported.playlistURL
    }
}
#endif
