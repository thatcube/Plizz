#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

enum LiveTVMultiviewGeometry {
    static func viewport(in size: CGSize, isEditing: Bool = false) -> CGRect {
        let canvas = CGRect(origin: .zero, size: size)
        guard isEditing else { return canvas }
        #if os(tvOS)
        let horizontal = min(CGFloat(80), size.width / 12)
        let vertical = min(CGFloat(156), size.height / 4)
        #else
        let horizontal = min(CGFloat(24), size.width / 12)
        let vertical = min(CGFloat(100), size.height / 4)
        #endif
        return canvas.insetBy(dx: horizontal, dy: vertical)
    }

    static func focusViewport(in size: CGSize, chromeVisible: Bool, isEditing: Bool = false) -> CGRect {
        if isEditing { return viewport(in: size, isEditing: true) }
        guard chromeVisible else { return viewport(in: size) }
        #if os(tvOS)
        let top = min(CGFloat(156), size.height / 4)
        let bottom = min(CGFloat(156), size.height / 4)
        #else
        let top = min(CGFloat(90), size.height / 4)
        let bottom = min(CGFloat(110), size.height / 4)
        #endif
        return CGRect(x: 0, y: top, width: size.width, height: max(1, size.height - top - bottom))
    }

    static func frame(
        for id: UUID, panes: [UUID], primary: UUID,
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner,
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize,
        isEditing: Bool = false, aspectRatio: CGFloat? = nil
    ) -> CGRect {
        if expanded != nil { return viewport(in: size) }
        let area = viewport(in: size, isEditing: isEditing)
        let ordered = [primary] + panes.filter { $0 != primary }
        if ordered.count == 1 {
            return isEditing ? contentFrame(in: area, aspectRatio: aspectRatio) : area
        }
        let index = ordered.firstIndex(of: id) ?? 0
        if layout == .mainAndStack {
            let gap = min(CGFloat(16), max(0, min(area.width, area.height) / 12))
            let sideWidth = area.width * 0.28
            let mainWidth = area.width - sideWidth - gap
            let slot: CGRect
            if id == primary {
                slot = CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height)
            } else {
                let count = CGFloat(ordered.count - 1)
                let height = (area.height - gap * (count - 1)) / count
                slot = CGRect(
                    x: area.maxX - sideWidth, y: area.minY + CGFloat(index - 1) * (height + gap),
                    width: sideWidth, height: height)
            }
            return isEditing ? contentFrame(in: slot, aspectRatio: aspectRatio) : slot
        }
        if layout == .sideBySide {
            let horizontal = area.width >= area.height
            let slot: CGRect
            if ordered.count > 2 {
                let row = index / 2
                let columns = min(2, ordered.count - row * 2)
                let width = area.width / CGFloat(columns)
                slot = CGRect(
                    x: area.minX + CGFloat(index % 2) * width,
                    y: area.minY + CGFloat(row) * area.height / 2,
                    width: width, height: area.height / 2)
            } else if horizontal {
                let width = area.width / 2
                slot = CGRect(
                    x: area.minX + CGFloat(index) * width, y: area.minY,
                    width: width, height: area.height)
            } else {
                let height = area.height / 2
                slot = CGRect(
                    x: area.minX, y: area.minY + CGFloat(index) * height,
                    width: area.width, height: height)
            }
            return isEditing ? contentFrame(in: slot.insetBy(dx: 8, dy: 8), aspectRatio: aspectRatio) : slot
        }
        guard id != primary else {
            return isEditing ? contentFrame(in: area, aspectRatio: aspectRatio) : area
        }
        let insetBounds = insetPlacementBounds(in: area)
        let count = CGFloat(ordered.count - 1)
        let spacing: CGFloat = 12
        let availableHeight = max(1, insetBounds.height - 32 - spacing * (count - 1))
        let width = min(insetBounds.width * CGFloat(insetSize.fraction), availableHeight / count * 16 / 9)
        let height = width * 9 / 16
        let left = corner == .topLeading || corner == .bottomLeading
        let atTop = corner == .topLeading || corner == .topTrailing
        let columnHeight = height * count + spacing * (count - 1)
        let top = atTop ? insetBounds.minY + 16 : insetBounds.maxY - columnHeight - 16
        let slot = CGRect(
            x: left ? insetBounds.minX + 16 : insetBounds.maxX - width - 16,
            y: top + CGFloat(index - 1) * (height + spacing),
            width: width, height: height
        )
        return isEditing ? contentFrame(in: slot, aspectRatio: aspectRatio) : slot
    }

    static func focusFrame(
        for id: UUID, panes: [UUID], primary: UUID,
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner,
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize,
        chromeVisible: Bool, isEditing: Bool = false, aspectRatio: CGFloat? = nil
    ) -> CGRect {
        let picture = frame(
            for: id, panes: panes, primary: primary, layout: layout, corner: corner,
            insetSize: insetSize, expanded: expanded, size: size,
            isEditing: isEditing, aspectRatio: aspectRatio
        )
        var region = contentFrame(in: picture, aspectRatio: aspectRatio)
        if expanded == nil, layout == .corner, id == primary,
           let secondary = panes.first(where: { $0 != primary }) {
            let inset = frame(
                for: secondary, panes: panes, primary: primary, layout: layout, corner: corner,
                insetSize: insetSize, expanded: nil, size: size, isEditing: isEditing
            )
            // Keep the primary target beside, never surrounding, the inset.
            let leading = corner == .topLeading || corner == .bottomLeading
            let x = leading ? inset.maxX + 16 : picture.minX
            let right = leading ? picture.maxX : inset.minX - 16
            region = region.intersection(
                CGRect(x: x, y: picture.minY, width: max(1, right - x), height: picture.height))
        }
        return region.intersection(focusViewport(in: size, chromeVisible: chromeVisible, isEditing: isEditing))
    }

    static func contentFrame(in area: CGRect, aspectRatio: CGFloat?) -> CGRect {
        let ratio = aspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 16 / 9
        let width = min(area.width, area.height * ratio)
        let height = width / ratio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private static func insetPlacementBounds(in area: CGRect) -> CGRect {
        contentFrame(in: area, aspectRatio: 16 / 9)
    }
}

struct LiveTVMultiviewChromeState: Equatable {
    private(set) var isVisible = true
    private(set) var isEditing = false
    private(set) var inactivity = PlaybackControlsInactivity()

    mutating func activity(at time: TimeInterval) {
        guard !isEditing else { return }
        inactivity.recordInteraction(at: time)
        isVisible = true
    }

    mutating func editing(at time: TimeInterval) {
        guard !isEditing else { return }
        activity(at: time)
        isEditing = true
    }

    mutating func watching(at time: TimeInterval) {
        isEditing = false
        activity(at: time)
    }

    mutating func hide() {
        isVisible = false
        isEditing = false
    }

    func canAutoHide(blocked: Bool) -> Bool {
        isVisible && !isEditing && !blocked
    }
}

struct LiveTVMultiviewOverlay: View {
    let coordinator: LiveTVMultiviewCoordinator
    let exit: () -> Void
    let returnToGuide: () -> Void
    let addChannel: () -> Void
    let replaceChannel: (UUID) -> Void
    var isFavorite = false
    var toggleFavorite: (() -> Void)?
    @State private var exitDestination: ExitDestination?
    @State private var chrome = LiveTVMultiviewChromeState()
    @State private var focusedPaneID: UUID?
    @State private var focusRestoreRequest = 0
    @State private var restoringHiddenPaneFocus = false
    @State private var restoringSetupFocus = false
    @Namespace private var paneFocusScope
    @Namespace private var controlsFocusScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif

    private enum ExitDestination { case player, guide }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack(alignment: .topLeading) {
                    LiveTVMultiviewPaneViewport(
                        coordinator: coordinator, size: geometry.size,
                        chromeVisible: chrome.isVisible, focusScope: paneFocusScope,
                        focusedPaneID: focusedPaneID,
                        preparedWhileFocused: selectPreparedAudio,
                        activate: expand,
                        editing: beginEditing,
                        replace: { beginEditing(); replaceChannel($0) }
                    )
                    if chrome.isVisible {
                        LiveTVMultiviewChrome(
                            coordinator: coordinator,
                            exit: { exitDestination = .player }, collapse: collapse, watch: finishSetup, setup: startSetup,
                            focusScope: controlsFocusScope,
                            restoresSetupFocus: restoringSetupFocus,
                            setupFocused: { restoringSetupFocus = false },
                            editing: beginEditing,
                            add: { beginEditing(); addChannel() },
                            replace: { beginEditing(); replaceChannel(coordinator.audiblePaneID) },
                            isFavorite: isFavorite, toggleFavorite: toggleFavorite
                        )
                        .transition(.identity)
                    }
                }
                #if os(tvOS)
                .background {
                    TVFocusActivityObserver(
                        onActivity: activity, observesPlaybackPresses: true,
                        onFocusedFrame: { nativeFocusChanged($0, size: geometry.size) })
                }
                .task(id: focusRestoreRequest) {
                    guard focusRestoreRequest > 0 else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    resetFocus(in: paneFocusScope)
                }
                #endif
                .onAppear {
                    if coordinator.isEditingLayout { beginEditing() } else { activity() }
                    restoreAudiblePaneFocus()
                }
                .onChange(of: voiceOver) { _, enabled in
                    if enabled { activity() }
                }
                .task(id: autoHideRequest) {
                    guard autoHideRequest != nil else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let delay = chrome.inactivity.remainingDelay(
                        startedAt: chrome.inactivity.lastInteractionAt ?? now, now: now
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, autoHideRequest != nil else { return }
                    chrome.hide()
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.layout)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.primaryPaneID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.corner)
            }
        }
        .alert(
            "Multiview",
            isPresented: Binding(
                get: { coordinator.issue != nil },
                set: { if !$0 { coordinator.dismissIssue() } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.dismissIssue() }
        } message: {
            if let issue = coordinator.issue { Text(issue) }
        }
        .confirmationDialog(
            "Close Multiview?",
            isPresented: Binding(
                get: { exitDestination != nil },
                set: { if !$0 { exitDestination = nil } }),
            titleVisibility: .visible, presenting: exitDestination
        ) { destination in
            Button("Close Multiview", role: .destructive) {
                exitDestination = nil
                if destination == .player { exit() } else { returnToGuide() }
            }
            Button("Keep watching", role: .cancel) { exitDestination = nil }
        } message: { _ in
            if isFavorite {
                Text("This Multiview will close. Its favorite will remain available in the guide.")
            } else {
                Text("This Multiview will close. Favorite it first if you want to open this setup again.")
            }
        }
        #if os(tvOS)
        .onExitCommand {
            if coordinator.expandedPaneID != nil {
                collapse()
            } else if coordinator.isEditingLayout {
                finishSetup()
            } else if chrome.isEditing {
                hideChrome()
            } else {
                exitDestination = .guide
            }
        }
        #endif
    }

    private var autoHideRequest: TimeInterval? {
        let blocked = coordinator.isEditingLayout || exitDestination != nil || coordinator.issue != nil || voiceOver
            || coordinator.panes.contains {
                $0.preparation.failure != nil
                    || ($0.preparation.current == nil && $0.preparation.isPreparing)
            }
        return chrome.canAutoHide(blocked: blocked) ? (chrome.inactivity.lastInteractionAt ?? 0) : nil
    }

    private func activity() {
        if restoringHiddenPaneFocus {
            restoringHiddenPaneFocus = false
            return
        }
        guard !chrome.isEditing else { return }
        chrome.activity(at: ProcessInfo.processInfo.systemUptime)
    }

    private func nativeFocusChanged(_ focusedFrame: CGRect, size: CGSize) {
        let id = coordinator.panes.first { pane in
            guard coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id else { return false }
            let frame = LiveTVMultiviewGeometry.focusFrame(
                for: pane.id, panes: coordinator.panes.map(\.id), primary: coordinator.primaryPaneID,
                layout: coordinator.layout, corner: coordinator.corner, insetSize: coordinator.insetSize,
                expanded: coordinator.expandedPaneID, size: size, chromeVisible: true,
                isEditing: coordinator.isEditingLayout,
                aspectRatio: pane.videoAspectRatio.map { CGFloat($0) })
            return abs(frame.minX - focusedFrame.minX) < 2 && abs(frame.minY - focusedFrame.minY) < 2
                && abs(frame.width - focusedFrame.width) < 2 && abs(frame.height - focusedFrame.height) < 2
        }?.id
        if id == nil { restoringSetupFocus = false }
        guard id != focusedPaneID else { return }
        if let previous = focusedPaneID { paneFocusChanged(previous, false) }
        if let id { paneFocusChanged(id, true) }
    }

    private func beginEditing() {
        guard !chrome.isEditing else { return }
        chrome.editing(at: ProcessInfo.processInfo.systemUptime)
    }

    private func startSetup() {
        #if os(tvOS)
        restoringSetupFocus = true
        #endif
        coordinator.beginEditingLayout()
        beginEditing()
    }

    private func finishSetup() {
        restoringSetupFocus = false
        coordinator.finishEditingLayout()
        hideChrome()
    }

    private func paneFocusChanged(_ id: UUID, _ focused: Bool) {
        if focused {
            focusedPaneID = id
            if restoringHiddenPaneFocus {
                chrome.hide()
            } else if !coordinator.isEditingLayout {
                chrome.watching(at: ProcessInfo.processInfo.systemUptime)
            }
            selectPreparedAudio(id)
        } else if focusedPaneID == id {
            focusedPaneID = nil
            // Native context-menu focus can leave the anchor without entering another SwiftUI view.
            if chrome.isVisible { beginEditing() }
        }
    }

    private func selectPreparedAudio(_ id: UUID) {
        guard !restoringSetupFocus,
              coordinator.expandedPaneID == nil || coordinator.expandedPaneID == id,
              let pane = coordinator.panes.first(where: { $0.id == id }),
              pane.preparation.current != nil else { return }
        coordinator.selectAudio(id)
    }

    private func expand(_ id: UUID) {
        guard coordinator.panes.first(where: { $0.id == id })?.preparation.current != nil else {
            activity()
            return
        }
        selectPreparedAudio(id)
        coordinator.finishEditingLayout()
        if coordinator.panes.count > 1 { coordinator.expand(id) }
        chrome.watching(at: ProcessInfo.processInfo.systemUptime)
    }

    private func collapse() {
        coordinator.collapse()
        hideChrome()
    }

    private func hideChrome() {
        chrome.hide()
        restoreAudiblePaneFocus()
    }

    private func restoreAudiblePaneFocus() {
        #if os(tvOS)
        guard coordinator.audiblePane?.preparation.current != nil,
              focusedPaneID != coordinator.audiblePaneID else { return }
        restoringHiddenPaneFocus = !chrome.isVisible
        focusRestoreRequest &+= 1
        #endif
    }

}

private struct LiveTVMultiviewPaneViewport: View {
    let coordinator: LiveTVMultiviewCoordinator
    let size: CGSize
    let chromeVisible: Bool
    let focusScope: Namespace.ID
    let focusedPaneID: UUID?
    let preparedWhileFocused: (UUID) -> Void
    let activate: (UUID) -> Void
    let editing: () -> Void
    let replace: (UUID) -> Void

    var body: some View {
        // Revealing controls must not reshape the native focus section under the current picture.
        let viewport = LiveTVMultiviewGeometry.focusViewport(
            in: size, chromeVisible: true, isEditing: coordinator.isEditingLayout)
        ZStack(alignment: .topLeading) {
            ForEach(coordinator.panes) { pane in
                let frame = LiveTVMultiviewGeometry.frame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size,
                    isEditing: coordinator.isEditingLayout,
                    aspectRatio: pane.videoAspectRatio.map { CGFloat($0) }
                )
                let focusFrame = LiveTVMultiviewGeometry.focusFrame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size,
                    chromeVisible: true, isEditing: coordinator.isEditingLayout,
                    aspectRatio: pane.videoAspectRatio.map { CGFloat($0) }
                )
                let visible = coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id
                if visible {
                    LiveTVMultiviewPaneControl(
                        pane: pane, audible: coordinator.audiblePaneID == pane.id,
                        focusFrame: focusFrame.offsetBy(dx: -frame.minX, dy: -frame.minY),
                        isInteractive: visible, chromeVisible: chromeVisible,
                        showsOutline: coordinator.isEditingLayout, focusScope: focusScope,
                        nativeFocused: focusedPaneID == pane.id,
                        preparedWhileFocused: { preparedWhileFocused(pane.id) },
                        activate: { activate(pane.id) }, editing: editing,
                        listen: { coordinator.selectAudio(pane.id) },
                        promote: { coordinator.promote(pane.id) },
                        replace: { replace(pane.id) },
                        retry: { coordinator.retry(pane.id) }
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX - viewport.minX, y: frame.midY - viewport.minY)
                    .zIndex(pane.id == coordinator.primaryPaneID ? 0 : 1)
                }
            }
        }
        // Bridge the header's horizontal gap without absorbing its controls into this focus section.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        #if os(tvOS)
        .focusSection()
        .focusScope(focusScope)
        #endif
        .position(x: viewport.midX, y: viewport.midY)
    }
}

private struct LiveTVMultiviewChrome: View {
    let coordinator: LiveTVMultiviewCoordinator
    let exit: () -> Void
    let collapse: () -> Void
    let watch: () -> Void
    let setup: () -> Void
    let focusScope: Namespace.ID
    let restoresSetupFocus: Bool
    let setupFocused: () -> Void
    let editing: () -> Void
    let add: () -> Void
    let replace: () -> Void
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            LiveTVMultiviewHeader(
                exit: exit, editing: editing, watch: coordinator.isEditingLayout ? watch : nil)
                #if os(tvOS)
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 20)
                #else
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
                #endif
                .background {
                    LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 0)
            LiveTVMultiviewToolbar(
                coordinator: coordinator, add: add, replace: replace,
                collapse: collapse, setup: setup, focusScope: focusScope,
                restoresSetupFocus: restoresSetupFocus, setupFocused: setupFocused, editing: editing,
                isFavorite: isFavorite, toggleFavorite: toggleFavorite
            )
            #if os(tvOS)
            .padding(.horizontal, 72)
            .padding(.bottom, 52)
            .padding(.top, 16)
            #else
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 12)
            #endif
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
        #if !os(tvOS)
        .simultaneousGesture(TapGesture().onEnded { _ in editing() })
        #else
        .focusScope(focusScope)
        #endif
    }
}

private struct LiveTVMultiviewHeader: View {
    let exit: () -> Void
    let editing: () -> Void
    let watch: (() -> Void)?

    var body: some View {
        HStack {
            Text("Multiview").font(.headline)
            Spacer()
            if let watch {
                LiveTVMultiviewAction(title: "Watch", symbol: "play.fill", action: watch, editing: editing)
                    .accessibilityIdentifier("live-multiview-watch")
            }
            LiveTVMultiviewAction(title: "Close Multiview", symbol: "xmark", action: exit, editing: editing)
                .accessibilityIdentifier("live-multiview-done")
        }
        .foregroundStyle(.white)
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

private struct LiveTVMultiviewPaneControl: View {
    let pane: LiveTVMultiviewPane
    let audible: Bool
    let focusFrame: CGRect
    let isInteractive: Bool
    let chromeVisible: Bool
    let showsOutline: Bool
    let focusScope: Namespace.ID
    let nativeFocused: Bool
    let preparedWhileFocused: () -> Void
    let activate: () -> Void
    let editing: () -> Void
    let listen: () -> Void
    let promote: () -> Void
    let replace: () -> Void
    let retry: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .top) {
            if chromeVisible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LiveTVMultiviewCaption(pane: pane, audible: audible)
                }
                .frame(width: focusFrame.width, height: focusFrame.height)
                .position(x: focusFrame.midX, y: focusFrame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            pictureControl
            .disabled(!isInteractive || (pane.preparation.current == nil && pane.preparation.failure != nil))
            .accessibilityLabel(pane.channel?.name ?? String(localized: "Channel"))
            .accessibilityValue(audible ? String(localized: "Audio on") : String(localized: "Muted"))
            .accessibilityIdentifier("live-multiview-pane-\(pane.id.uuidString)")
            .contextMenu {
                #if !os(tvOS)
                Button("Listen", systemImage: "speaker.wave.2") { editing(); listen() }
                    .disabled(pane.preparation.current == nil)
                #endif
                Button("Make main picture", systemImage: "rectangle.inset.filled") { editing(); promote() }
                    .disabled(pane.preparation.current == nil)
                Button("Replace channel", systemImage: "arrow.triangle.2.circlepath", action: replace)
            }
            #if os(tvOS)
            .frame(width: focusFrame.width, height: focusFrame.height)
            .position(x: focusFrame.midX, y: focusFrame.midY)
            #endif

            if let failure = pane.preparation.failure {
                LiveTVMultiviewFailure(
                    message: failure.userDescription,
                    hasCurrentPicture: pane.preparation.current != nil,
                    retry: retry, replace: replace, editing: editing
                )
                .disabled(pane.preparation.isPreparing)
                .frame(width: focusFrame.width, height: focusFrame.height, alignment: .top)
                .position(x: focusFrame.midX, y: focusFrame.midY)
            }
        }
        .overlay {
            if chromeVisible && showsOutline {
                if nativeFocused {
                    PrototypeFocusOutline(cornerRadius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(audible ? palette.accent : .white.opacity(0.15), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .foregroundStyle(.white)
        .onChange(of: pane.preparation.current?.id) { _, current in
            if nativeFocused, current != nil, isInteractive { preparedWhileFocused() }
        }
    }

    @ViewBuilder
    private var pictureControl: some View {
        #if os(tvOS)
        Color.clear
            .accessibilityElement(children: .ignore)
            .focusableCard(
                isFocused: $focused, cornerRadius: 10,
                isEnabled: isEnabled && isInteractive
                    && (pane.preparation.current != nil || pane.preparation.failure == nil),
                action: activate
            )
            .prefersDefaultFocus(audible && pane.preparation.current != nil, in: focusScope)
        #else
        Button(action: activate) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
        #endif
    }
}

private struct LiveTVMultiviewCaption: View {
    let pane: LiveTVMultiviewPane
    let audible: Bool

    var body: some View {
        HStack(spacing: 10) {
            if audible { Image(systemName: "speaker.wave.2.fill") }
            Text(pane.channel?.name ?? String(localized: "Channel"))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            if pane.preparation.isPreparing { ProgressView().tint(.white) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7))
    }
}

private struct LiveTVMultiviewFailure: View {
    let message: LocalizedStringResource
    let hasCurrentPicture: Bool
    let retry: () -> Void
    let replace: () -> Void
    let editing: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 12) {
                Text(message).font(.callout).multilineTextAlignment(.center)
                actions
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: hasCurrentPicture ? nil : .infinity)
        .background(.black.opacity(0.78))
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                LiveTVMultiviewAction(title: "Retry", symbol: "arrow.clockwise", action: retry, editing: editing)
                LiveTVMultiviewAction(title: "Replace", symbol: "arrow.triangle.2.circlepath", action: replace, editing: editing)
            }
            HStack {
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: replace)
            }
            .labelStyle(.iconOnly)
        }
    }
}

private struct LiveTVMultiviewToolbar: View {
    let coordinator: LiveTVMultiviewCoordinator
    let add: () -> Void
    let replace: () -> Void
    let collapse: () -> Void
    let setup: () -> Void
    let focusScope: Namespace.ID
    let restoresSetupFocus: Bool
    let setupFocused: () -> Void
    let editing: () -> Void
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?
    @FocusState private var layoutFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                if let toggleFavorite {
                    LiveTVMultiviewAction(
                        title: isFavorite ? "Unfavorite" : "Favorite",
                        symbol: isFavorite ? "star.fill" : "star",
                        action: toggleFavorite, editing: editing)
                        .accessibilityIdentifier("live-multiview-favorite")
                        .accessibilityValue(isFavorite ? "Saved" : "Not saved")
                }
                if !coordinator.isEditingLayout {
                    LiveTVMultiviewAction(
                        title: "Edit layout", symbol: "rectangle.split.2x2",
                        action: setup, editing: editing
                    )
                    .accessibilityIdentifier("live-multiview-edit")
                }
                if coordinator.isEditingLayout {
                    if coordinator.canAdd {
                        LiveTVMultiviewAction(title: "Add channel", symbol: "plus", action: add, editing: editing)
                            .accessibilityIdentifier("live-multiview-add")
                    }
                    Menu {
                        ForEach(LiveTVMultiviewLayout.allCases, id: \.self) { layout in
                            Button {
                                setup()
                                coordinator.layout = layout
                            } label: {
                                Label(layout.title, systemImage: coordinator.layout == layout ? "checkmark" : "rectangle")
                            }
                        }
                        if coordinator.layout == .corner {
                            Section("Position") {
                                ForEach(LiveTVMultiviewCorner.allCases, id: \.self) { corner in
                                    Button(corner.title) { setup(); coordinator.corner = corner }
                                }
                            }
                            Section("Size") {
                                ForEach(LiveTVMultiviewInsetSize.allCases, id: \.self) { size in
                                    Button(size.title) { setup(); coordinator.insetSize = size }
                                }
                            }
                        }
                    } label: {
                        Label("Layout", systemImage: "rectangle.split.2x1")
                    }
                    .focused($layoutFocused)
                    .onChange(of: layoutFocused) { _, focused in
                        if focused { editing(); setupFocused() }
                    }
                    #if os(tvOS)
                    .prefersDefaultFocus(true, in: focusScope)
                    .task(id: restoresSetupFocus) {
                        guard restoresSetupFocus else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if layoutFocused { setupFocused() } else { layoutFocused = true }
                    }
                    #endif
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("live-multiview-layout")
                    #if !os(tvOS)
                    if coordinator.panes.count > 1 {
                        Menu {
                            ForEach(coordinator.panes) { pane in
                                Button {
                                    coordinator.selectAudio(pane.id)
                                } label: {
                                    Label(
                                        pane.channel?.name ?? String(localized: "Channel"),
                                        systemImage: coordinator.audiblePaneID == pane.id ? "checkmark" : "speaker"
                                    )
                                }
                                .disabled(pane.preparation.current == nil)
                                .accessibilityLabel(pane.channel?.name ?? String(localized: "Channel"))
                                .accessibilityIdentifier("live-multiview-listen-\(pane.id.uuidString)")
                            }
                        } label: {
                            Label("Audio", systemImage: "speaker.wave.2")
                        }
                        .plozzActionButton(role: .secondary)
                        .accessibilityIdentifier("live-multiview-audio")
                    }
                    #endif
                    LiveTVMultiviewAction(title: "Replace", symbol: "arrow.triangle.2.circlepath", action: replace, editing: editing)
                        .accessibilityIdentifier("live-multiview-replace")
                    if coordinator.panes.count > 1, coordinator.audiblePaneID != coordinator.primaryPaneID {
                        LiveTVMultiviewAction(title: "Make main", symbol: "rectangle.inset.filled", action: {
                            coordinator.promote(coordinator.audiblePaneID)
                        }, editing: editing)
                        .accessibilityIdentifier("live-multiview-promote")
                    }
                    if coordinator.panes.count > 1 {
                        LiveTVMultiviewAction(title: "Remove", symbol: "minus.circle", action: {
                            coordinator.remove(coordinator.audiblePaneID)
                        }, editing: editing)
                        .accessibilityIdentifier("live-multiview-remove")
                    }
                }
                if coordinator.expandedPaneID != nil {
                    LiveTVMultiviewAction(
                        title: "Show all", symbol: "rectangle.split.2x2",
                        action: collapse, editing: editing
                    )
                    .accessibilityIdentifier("live-multiview-collapse")
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

private struct LiveTVMultiviewAction: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void
    var editing: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            editing()
            action()
        } label: {
            Label(title, systemImage: symbol)
        }
            .focused($focused)
            .onChange(of: focused) { _, focused in
                if focused { editing() }
            }
            .plozzActionButton(role: .secondary)
    }
}

#endif
