#if DEBUG
@_exported import CoreModels
import Foundation
import Observation

@MainActor
@Observable
public final class LiveTVMultiviewPane: Identifiable {
    public let id: UUID
    public let preparation: LiveTVPlaybackPreparation
    public fileprivate(set) var requestedChannel: LiveTVPrototypeChannel?
    public fileprivate(set) var hasPresentedFrame = false
    public fileprivate(set) var playPauseRequest = 0
    public fileprivate(set) var videoAspectRatio: Double?
    fileprivate var retired = false
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var reportTail: Task<Void, Never>?
    @ObservationIgnored fileprivate var requestID = UUID()

    public var channel: LiveTVPrototypeChannel? {
        preparation.current?.channel ?? requestedChannel
    }

    fileprivate init(preparation: LiveTVPlaybackPreparation, id: UUID = UUID()) {
        self.id = id
        self.preparation = preparation
    }
}

/// Pane identity, prepared streams and audible selection survive every layout change.
@MainActor
@Observable
public final class LiveTVMultiviewCoordinator {
    public private(set) var panes: [LiveTVMultiviewPane]
    public private(set) var isEnabled = false
    public private(set) var isEditingLayout = false
    public private(set) var audiblePaneID: UUID
    public private(set) var primaryPaneID: UUID
    public private(set) var expandedPaneID: UUID?
    public var layout: LiveTVMultiviewLayout = .sideBySide
    public var corner: LiveTVMultiviewCorner = .bottomTrailing
    public var insetSize: LiveTVMultiviewInsetSize = .medium
    public private(set) var issue: LocalizedStringResource?
    public private(set) var isClosing = false
    public let maximumPanes = LiveTVMultiviewFavorite.maximumChannelCount

    @ObservationIgnored private let makePreparation: @MainActor () -> LiveTVPlaybackPreparation
    @ObservationIgnored private let reference: @MainActor (String) -> LiveTVServerChannelReference?
    @ObservationIgnored private let authorizes: @MainActor @Sendable (
        LiveTVPrototypeChannel, LiveTVServerChannelReference?
    ) -> Bool
    @ObservationIgnored private let recordWatched: @MainActor (String) -> Void
    @ObservationIgnored private var active = true
    @ObservationIgnored private var cleanupCount = 0
    @ObservationIgnored private var cleanups: [UUID: Task<Void, Never>] = [:]

    public init(
        primary: LiveTVPlaybackPreparation,
        makePreparation: @escaping @MainActor () -> LiveTVPlaybackPreparation,
        reference: @escaping @MainActor (String) -> LiveTVServerChannelReference?,
        authorizes: @escaping @MainActor @Sendable (
            LiveTVPrototypeChannel, LiveTVServerChannelReference?
        ) -> Bool,
        recordWatched: @escaping @MainActor (String) -> Void
    ) {
        let pane = LiveTVMultiviewPane(preparation: primary)
        self.panes = [pane]
        self.audiblePaneID = pane.id
        self.primaryPaneID = pane.id
        self.makePreparation = makePreparation
        self.reference = reference
        self.authorizes = authorizes
        self.recordWatched = recordWatched
    }

    public var canAdd: Bool { isEnabled && !isClosing && panes.count < maximumPanes }
    public var audiblePane: LiveTVMultiviewPane? { panes.first { $0.id == audiblePaneID } }

    @discardableResult
    public func begin() -> Bool {
        guard active, panes.first?.preparation.current != nil else {
            issue = "Start a channel before opening Multiview."
            return false
        }
        issue = nil
        isEnabled = true
        isEditingLayout = true
        panes[0].requestedChannel = panes[0].preparation.current?.channel
        return true
    }

    public func dismissIssue() { issue = nil }

    private var orderedPanes: [LiveTVMultiviewPane] {
        panes.filter { $0.id == primaryPaneID } + panes.filter { $0.id != primaryPaneID }
    }

    public func favoriteSnapshot() -> LiveTVMultiviewFavorite? {
        let channels = orderedPanes.compactMap { $0.preparation.current?.channel }
        guard isEnabled, channels.count == panes.count, !channels.isEmpty,
              !panes.contains(where: { $0.preparation.isPreparing }) else { return nil }
        return LiveTVMultiviewFavorite(
            name: String(channels.map(\.name).joined(separator: " + ").prefix(240)),
            channelIDs: channels.map(\.id), layout: layout, corner: corner, insetSize: insetSize)
    }

    public func matches(_ favorite: LiveTVMultiviewFavorite) -> Bool {
        let ids = orderedPanes.compactMap { $0.channel?.id }
        guard isEnabled, ids.count == panes.count else { return false }
        return ids == favorite.channelIDs && layout == favorite.layout
            && (layout != .corner || (corner == favorite.corner && insetSize == favorite.insetSize))
    }

    @discardableResult
    public func restore(_ favorite: LiveTVMultiviewFavorite, from channels: [LiveTVPrototypeChannel]) -> Bool {
        guard active, !isEnabled, !isClosing, panes.count == 1 else {
            issue = "Close the current Multiview before opening a favorite."
            return false
        }
        guard favorite.isValid, favorite.channelIDs.count <= maximumPanes else {
            issue = "This Multiview favorite has an unsupported configuration."
            return false
        }
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = favorite.channelIDs.compactMap { byID[$0] }
        guard resolved.count == favorite.channelIDs.count,
              resolved.allSatisfy({ authorizes($0, reference($0.id)) }) else {
            issue = "Some channels in this Multiview are unavailable. Check its sources and try again."
            return false
        }
        issue = nil
        isEnabled = true
        isEditingLayout = false
        expandedPaneID = nil
        layout = favorite.layout
        corner = favorite.corner
        insetSize = favorite.insetSize
        let retained = panes[0]
        let retainedChannelID = retained.preparation.current?.channel.id
        let retainedIndex = resolved.firstIndex { $0.id == retainedChannelID } ?? 0
        // Reuse the current renderer even when it belongs in the saved side column.
        panes = resolved.enumerated().map { index, channel in
            let pane = index == retainedIndex ? retained : LiveTVMultiviewPane(preparation: makePreparation())
            pane.requestedChannel = channel
            return pane
        }
        primaryPaneID = panes[0].id
        audiblePaneID = primaryPaneID
        for (pane, channel) in zip(panes, resolved) {
            if pane.preparation.current?.channel.id != channel.id {
                _ = prepare(channel, in: pane)
            }
        }
        return true
    }

    public func beginEditingLayout() {
        guard isEnabled else { return }
        expandedPaneID = nil
        isEditingLayout = true
    }

    public func finishEditingLayout() { isEditingLayout = false }

    public func updateVideoAspectRatio(_ ratio: Double?, paneID: UUID, preparedID: UUID) {
        guard let pane = panes.first(where: { $0.id == paneID }),
              pane.preparation.current?.id == preparedID else { return }
        pane.videoAspectRatio = ratio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public func selectAudio(_ id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        audiblePaneID = id
    }

    public func promote(_ id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        primaryPaneID = id
    }

    public func expand(_ id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        isEditingLayout = false
        expandedPaneID = id
    }

    public func collapse() { expandedPaneID = nil }

    public func requestPlayPause() {
        audiblePane?.playPauseRequest &+= 1
    }

    @discardableResult
    public func add(_ channel: LiveTVPrototypeChannel) -> Task<Void, Never>? {
        if let existing = panes.first(where: { $0.channel?.id == channel.id || $0.requestedChannel?.id == channel.id }) {
            if existing.preparation.current != nil { selectAudio(existing.id) }
            return nil
        }
        guard canAdd else {
            issue = isClosing ? "Wait for the previous channel to close."
                : "Multiview supports \(maximumPanes) channels at a time. Replace a channel to watch another."
            return nil
        }
        let pane = LiveTVMultiviewPane(preparation: makePreparation())
        panes.append(pane)
        return prepare(channel, in: pane)
    }

    @discardableResult
    public func replace(_ id: UUID, with channel: LiveTVPrototypeChannel) -> Task<Void, Never>? {
        guard isEnabled, let pane = panes.first(where: { $0.id == id }) else { return nil }
        if let existing = panes.first(where: {
            $0.id != id && ($0.channel?.id == channel.id || $0.requestedChannel?.id == channel.id)
        }) {
            if existing.preparation.current != nil { selectAudio(existing.id) }
            return nil
        }
        return prepare(channel, in: pane)
    }

    @discardableResult
    public func retry(_ id: UUID) -> Task<Void, Never>? {
        guard let pane = panes.first(where: { $0.id == id }),
              let channel = pane.requestedChannel ?? pane.channel else { return nil }
        return prepare(channel, in: pane)
    }

    public func remove(_ id: UUID) {
        guard panes.count > 1, let pane = panes.first(where: { $0.id == id }) else { return }
        panes.removeAll { $0.id == id }
        if audiblePaneID == id { audiblePaneID = panes[0].id }
        if primaryPaneID == id { primaryPaneID = panes[0].id }
        if expandedPaneID == id { expandedPaneID = nil }
        retire(pane)
    }

    /// The caller adopts this preparation, keeping its existing renderer and tuner lease.
    public func exit() -> LiveTVPlaybackPreparation? {
        let survivor = audiblePane.flatMap { $0.preparation.current == nil ? nil : $0 }
            ?? panes.first { $0.preparation.current != nil }
            ?? panes.first
        guard let survivor else { return nil }
        let removed = panes.filter { $0.id != survivor.id }
        survivor.task?.cancel()
        survivor.requestID = UUID()
        survivor.preparation.cancelPendingPreparation()
        survivor.requestedChannel = survivor.preparation.current?.channel
        panes = [survivor]
        audiblePaneID = survivor.id
        primaryPaneID = survivor.id
        expandedPaneID = nil
        isEnabled = false
        isEditingLayout = false
        issue = nil
        for pane in removed { retire(pane) }
        return survivor.preparation
    }

    public func setActive(_ isActive: Bool) {
        active = isActive
        if !isActive { stop() }
    }

    public func stop() {
        _ = exit()
        for pane in panes {
            pane.task?.cancel()
            pane.requestID = UUID()
            pane.preparation.stop()
            pane.hasPresentedFrame = false
        }
    }

    public func close() async {
        stop()
        let retiring = Array(cleanups.values)
        for pane in panes { await pane.preparation.close() }
        for cleanup in retiring { await cleanup.value }
    }

    public func validateAuthorization() {
        for pane in panes {
            if let requested = pane.requestedChannel,
               !authorizes(requested, reference(requested.id)) {
                pane.requestedChannel = nil
            }
            pane.preparation.validateAuthorization()
        }
    }

    public func confirmWatching(_ id: UUID, preparedID: UUID) {
        guard active, isEnabled, let pane = panes.first(where: { $0.id == id }),
              !pane.hasPresentedFrame,
              let current = pane.preparation.current, current.id == preparedID else { return }
        pane.hasPresentedFrame = true
        recordWatched(current.channel.id)
    }

    public func playbackFailed(_ id: UUID, preparedID: UUID) {
        guard let pane = panes.first(where: { $0.id == id }),
              pane.preparation.current?.id == preparedID else { return }
        pane.hasPresentedFrame = false
        pane.preparation.failCurrent(id: preparedID)
    }

    public func report(_ update: LiveTVPlaybackUpdate, paneID: UUID, preparedID: UUID) {
        guard active, let pane = panes.first(where: { $0.id == paneID }),
              pane.preparation.current?.id == preparedID else { return }
        let previous = pane.reportTail
        pane.reportTail = Task { @MainActor [weak self, weak pane] in
            await previous?.value
            guard let self, self.active, let pane, !pane.retired,
                  pane.preparation.current?.id == preparedID else { return }
            await pane.preparation.report(update, for: preparedID)
        }
    }

    private func prepare(
        _ channel: LiveTVPrototypeChannel, in pane: LiveTVMultiviewPane
    ) -> Task<Void, Never> {
        pane.task?.cancel()
        let requestID = UUID()
        pane.requestID = requestID
        pane.requestedChannel = channel
        issue = nil
        let serverReference = reference(channel.id)
        let task = Task { @MainActor [weak self, weak pane] in
            guard let self, let pane, self.active, self.isEnabled else { return }
            let accepted = await pane.preparation.prepare(
                channel, serverReference: serverReference,
                isAuthorized: { [weak self, weak pane] in
                    guard let self, self.active, let pane, !pane.retired else { return false }
                    return self.authorizes(channel, serverReference)
                },
                accept: { [weak self, weak pane] in
                    self?.active == true && self?.isEnabled == true && pane?.retired == false
                        && !Task.isCancelled
                }
            )
            guard pane.requestID == requestID, !pane.retired else { return }
            if accepted {
                pane.hasPresentedFrame = false
            } else if !self.authorizes(channel, serverReference) {
                pane.requestedChannel = nil
            }
        }
        pane.task = task
        return task
    }

    private func retire(_ pane: LiveTVMultiviewPane) {
        pane.retired = true
        pane.task?.cancel()
        pane.reportTail?.cancel()
        pane.preparation.stop()
        cleanupCount += 1
        isClosing = true
        cleanups[pane.id] = Task { @MainActor [weak self] in
            await pane.preparation.close()
            guard let self else { return }
            self.cleanups.removeValue(forKey: pane.id)
            self.cleanupCount -= 1
            self.isClosing = self.cleanupCount > 0
        }
    }
}
#endif
