#if DEBUG
import Foundation
import Observation

public struct LiveTVPreviewRequest: Equatable, Sendable {
    public let channelID: String
    public let revision: UInt64
    public let focusedAt: ContinuousClock.Instant
}

/// Focus requests are committed only after the view's cancellable settling delay.
/// Opening or closing the guide changes presentation, not the active channel.
@MainActor
@Observable
public final class LiveTVPreviewController {
    public static let settlingDelay: Duration = .milliseconds(600)

    public private(set) var isExpanded = false
    public private(set) var followsFocus: Bool
    public private(set) var keepWatchingWhileBrowsing: Bool
    public private(set) var pendingRequest: LiveTVPreviewRequest?
    public private(set) var focusRestoreRequest = 0
    public private(set) var isRestoringGuideFocus = false
    public private(set) var watchOrigin: LiveTVGuideRowID?
    public private(set) var restoresPlaybackFocus = true
    public private(set) var hasRequestedInitialGuideFocus = false
    private let model: LiveTVPrototypeModel
    private var focusedChannelID: String?
    private var browsingActive = true
    private var hasExplicitPlayback = false
    private var revision: UInt64 = 0

    public var isHoldingWatchedChannel: Bool {
        keepWatchingWhileBrowsing && hasExplicitPlayback
    }

    public init(
        model: LiveTVPrototypeModel,
        followsFocus: Bool = true,
        keepWatchingWhileBrowsing: Bool = false
    ) {
        self.model = model
        self.followsFocus = followsFocus
        self.keepWatchingWhileBrowsing = keepWatchingWhileBrowsing
    }

    public func suppressesNavigation(isActive: Bool, isSearching: Bool = false) -> Bool {
        isActive && (isSearching || isExpanded || isRestoringGuideFocus)
    }

    public func requestInitialGuideFocus(isActive: Bool, hasOverlay: Bool) -> LiveTVGuideRowID? {
        guard isActive, !hasOverlay, !isExpanded, !hasRequestedInitialGuideFocus,
              let first = model.guideChannels.first?.id else { return nil }
        requestBrowsingFocus()
        return first
    }

    public func focus(_ channelID: String?) {
        guard focusedChannelID != channelID else { return }
        focusedChannelID = channelID
        schedulePreview()
    }

    public func setBrowsingActive(_ active: Bool) {
        guard browsingActive != active else { return }
        browsingActive = active
        schedulePreview()
    }

    public func setFollowsFocus(_ enabled: Bool) {
        guard followsFocus != enabled else { return }
        followsFocus = enabled
        schedulePreview()
    }

    public func setKeepWatchingWhileBrowsing(_ enabled: Bool) {
        guard keepWatchingWhileBrowsing != enabled else { return }
        keepWatchingWhileBrowsing = enabled
        schedulePreview()
    }

    @discardableResult
    public func commitPreview(_ request: LiveTVPreviewRequest) -> Bool {
        guard pendingRequest == request, canPreviewFocusedChannel else { return false }
        pendingRequest = nil
        guard model.visibleChannels.contains(where: { $0.id == request.channelID }) else { return false }
        model.tune(request.channelID)
        return !model.tuneFailed
    }

    public func watch(_ channelID: String, origin: LiveTVGuideRowID? = nil) {
        cancelPendingPreview()
        model.tune(channelID)
        guard !model.tuneFailed else { return }
        hasExplicitPlayback = true
        hasRequestedInitialGuideFocus = true
        let preferredSection = origin?.channelID == channelID ? origin?.section
            : (isExpanded ? watchOrigin?.section : nil)
        watchOrigin = model.guideRow(for: channelID, preferring: preferredSection)
        focusedChannelID = channelID
        isRestoringGuideFocus = false
        isExpanded = true
    }

    public func returnToGuide(restoresFocus: Bool = true) {
        guard isExpanded else { return }
        cancelPendingPreview()
        focusedChannelID = model.playingChannelID
        restoresPlaybackFocus = true
        isRestoringGuideFocus = restoresFocus
        isExpanded = false
        focusRestoreRequest &+= 1
        if !restoresFocus { schedulePreview() }
    }

    public func requestBrowsingFocus() {
        guard !isExpanded else { return }
        hasRequestedInitialGuideFocus = true
        cancelPendingPreview()
        restoresPlaybackFocus = false
        isRestoringGuideFocus = true
        focusRestoreRequest &+= 1
    }

    public func completeGuideFocusRestore(_ request: Int) {
        guard request == focusRestoreRequest, isRestoringGuideFocus else { return }
        isRestoringGuideFocus = false
        schedulePreview()
    }

    /// Supplies the final focus synchronously, before SwiftUI's selection observer runs.
    public func completeGuideFocusRestore(_ request: Int, focusedChannelID: String?) {
        guard request == focusRestoreRequest, isRestoringGuideFocus else { return }
        self.focusedChannelID = focusedChannelID
        completeGuideFocusRestore(request)
    }

    public func playbackEnded() {
        isExpanded = false
        isRestoringGuideFocus = false
        hasExplicitPlayback = false
        watchOrigin = nil
        cancelPendingPreview()
    }

    public func stop() {
        cancelPendingPreview()
        focusedChannelID = nil
        isExpanded = false
        isRestoringGuideFocus = false
        hasExplicitPlayback = false
        watchOrigin = nil
        model.stop()
    }

    private func schedulePreview() {
        cancelPendingPreview()
        guard canPreviewFocusedChannel,
              let focusedChannelID, focusedChannelID != model.playingChannelID else { return }
        pendingRequest = LiveTVPreviewRequest(
            channelID: focusedChannelID, revision: revision, focusedAt: ContinuousClock.now
        )
    }

    private var canPreviewFocusedChannel: Bool {
        browsingActive && followsFocus && !isExpanded && !isRestoringGuideFocus
            && !isHoldingWatchedChannel
    }

    private func cancelPendingPreview() {
        revision &+= 1
        pendingRequest = nil
    }
}
#endif
