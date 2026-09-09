#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

enum LiveTVMultiviewGeometry {
    static func viewport(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    static func focusViewport(in size: CGSize, chromeVisible: Bool) -> CGRect {
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
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize
    ) -> CGRect {
        let area = viewport(in: size)
        if expanded != nil { return area }
        let ordered = [primary] + panes.filter { $0 != primary }
        if ordered.count == 1 { return area }
        let index = ordered.firstIndex(of: id) ?? 0
        if layout == .sideBySide {
            let horizontal = area.width >= area.height
            let slot: CGRect
            if horizontal {
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
            return slot
        }
        guard id != primary else { return area }
        // Only the inset retains its existing 16:9 presentation. Players fit their own source aspect.
        let insetBounds = insetPlacementBounds(in: area)
        let width = insetBounds.width * CGFloat(insetSize.fraction)
        let height = width * 9 / 16
        let left = corner == .topLeading || corner == .bottomLeading
        let atTop = corner == .topLeading || corner == .topTrailing
        return CGRect(
            x: left ? insetBounds.minX + 16 : insetBounds.maxX - width - 16,
            y: atTop ? insetBounds.minY + 16 : insetBounds.maxY - height - 16,
            width: width, height: height
        )
    }

    static func focusFrame(
        for id: UUID, panes: [UUID], primary: UUID,
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner,
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize,
        chromeVisible: Bool
    ) -> CGRect {
        let picture = frame(
            for: id, panes: panes, primary: primary, layout: layout, corner: corner,
            insetSize: insetSize, expanded: expanded, size: size
        )
        var region = picture
        if expanded == nil, layout == .corner, id == primary,
           let secondary = panes.first(where: { $0 != primary }) {
            let inset = frame(
                for: secondary, panes: panes, primary: primary, layout: layout, corner: corner,
                insetSize: insetSize, expanded: nil, size: size
            )
            // Keep the primary target beside, never surrounding, the inset.
            let leading = corner == .topLeading || corner == .bottomLeading
            let x = leading ? inset.maxX + 16 : picture.minX
            let right = leading ? picture.maxX : inset.minX - 16
            region = CGRect(x: x, y: picture.minY, width: max(1, right - x), height: picture.height)
        }
        return region.intersection(focusViewport(in: size, chromeVisible: chromeVisible))
    }

    private static func insetPlacementBounds(in area: CGRect) -> CGRect {
        let width = min(area.width, area.height * 16 / 9)
        let height = width * 9 / 16
        return CGRect(
            x: area.midX - width / 2, y: area.midY - height / 2,
            width: width, height: height)
    }
}

struct LiveTVMultiviewChromeState: Equatable {
    private(set) var isVisible = true
    private(set) var isEditing = false
    private(set) var inactivity = PlaybackControlsInactivity()

    mutating func activity(at time: TimeInterval) {
        inactivity.recordInteraction(at: time)
        isVisible = true
    }

    mutating func editing(at time: TimeInterval) {
        activity(at: time)
        isEditing = true
    }

    mutating func watching(at time: TimeInterval) {
        activity(at: time)
        isEditing = false
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
    let channels: [LiveTVPrototypeChannel]
    let favoriteIDs: Set<String>
    let exit: () -> Void
    let returnToGuide: () -> Void
    var pickerVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var picker: ChannelPickerDestination?
    @State private var chrome = LiveTVMultiviewChromeState()
    @State private var focusedPaneID: UUID?
    @State private var focusRestoreRequest = 0
    @State private var restoringHiddenPaneFocus = false
    @Namespace private var paneFocusScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif

    private enum ChannelPickerDestination: Identifiable {
        case add
        case replace(UUID)

        var id: String {
            switch self {
            case .add: "add"
            case .replace(let id): id.uuidString
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack(alignment: .topLeading) {
                    LiveTVMultiviewPaneViewport(
                        coordinator: coordinator, size: geometry.size,
                        chromeVisible: chrome.isVisible, focusScope: paneFocusScope,
                        focusChanged: paneFocusChanged,
                        preparedWhileFocused: selectPreparedAudio,
                        activate: expand,
                        editing: beginEditing,
                        replace: { beginEditing(); picker = .replace($0) }
                    )
                    if chrome.isVisible {
                        LiveTVMultiviewChrome(
                            coordinator: coordinator,
                            exit: exit, collapse: collapse,
                            editing: beginEditing,
                            add: { beginEditing(); picker = .add },
                            replace: { beginEditing(); picker = .replace(coordinator.audiblePaneID) }
                        )
                        .accessibilityIdentifier("live-multiview-chrome")
                        .transition(.identity)
                    }
                }
                #if os(tvOS)
                .background {
                    TVFocusActivityObserver(onActivity: activity, observesPlaybackPresses: true)
                }
                .task(id: focusRestoreRequest) {
                    guard focusRestoreRequest > 0 else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    resetFocus(in: paneFocusScope)
                }
                #endif
                .onAppear {
                    activity()
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
                .disabled(picker != nil)
                .accessibilityHidden(picker != nil)
                if let destination = picker {
                    channelPicker(destination)
                        .background(.black)
                        .ignoresSafeArea()
                }
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
        .onChange(of: picker != nil, initial: true) { _, visible in
            pickerVisibilityChanged(visible)
        }
        .onDisappear { pickerVisibilityChanged(false) }
        #if os(tvOS)
        .onExitCommand {
            if picker != nil {
                picker = nil
            } else if coordinator.expandedPaneID != nil {
                collapse()
            } else if chrome.isEditing {
                hideChrome()
            } else {
                returnToGuide()
            }
        }
        #endif
    }

    private var autoHideRequest: TimeInterval? {
        let blocked = picker != nil || coordinator.issue != nil || voiceOver
            || coordinator.panes.contains {
                $0.preparation.failure != nil
                    || ($0.preparation.current == nil && $0.preparation.isPreparing)
            }
        return chrome.canAutoHide(blocked: blocked) ? (chrome.inactivity.lastInteractionAt ?? 0) : nil
    }

    private func activity() {
        guard picker == nil, !restoringHiddenPaneFocus else { return }
        chrome.activity(at: ProcessInfo.processInfo.systemUptime)
    }

    private func beginEditing() {
        chrome.editing(at: ProcessInfo.processInfo.systemUptime)
    }

    private func paneFocusChanged(_ id: UUID, _ focused: Bool) {
        if focused {
            focusedPaneID = id
            if restoringHiddenPaneFocus {
                restoringHiddenPaneFocus = false
                chrome.hide()
            } else {
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
        guard coordinator.expandedPaneID == nil || coordinator.expandedPaneID == id,
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

    private func channelPicker(_ destination: ChannelPickerDestination) -> some View {
        LiveTVMultiviewChannelPicker(
            channels: channels, favoriteIDs: favoriteIDs,
            selectedIDs: Set(coordinator.panes.compactMap { $0.channel?.id }),
            cancel: { picker = nil }
        ) { channel in
            switch destination {
            case .add:
                coordinator.collapse()
                coordinator.add(channel)
            case .replace(let id): coordinator.replace(id, with: channel)
            }
            picker = nil
        }
    }
}

private struct LiveTVMultiviewPaneViewport: View {
    let coordinator: LiveTVMultiviewCoordinator
    let size: CGSize
    let chromeVisible: Bool
    let focusScope: Namespace.ID
    let focusChanged: (UUID, Bool) -> Void
    let preparedWhileFocused: (UUID) -> Void
    let activate: (UUID) -> Void
    let editing: () -> Void
    let replace: (UUID) -> Void

    var body: some View {
        let viewport = LiveTVMultiviewGeometry.focusViewport(in: size, chromeVisible: chromeVisible)
        ZStack(alignment: .topLeading) {
            ForEach(coordinator.panes) { pane in
                let frame = LiveTVMultiviewGeometry.frame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size
                )
                let focusFrame = LiveTVMultiviewGeometry.focusFrame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size,
                    chromeVisible: chromeVisible
                )
                let visible = coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id
                LiveTVMultiviewPaneControl(
                    pane: pane, audible: coordinator.audiblePaneID == pane.id,
                    focusFrame: focusFrame.offsetBy(dx: -frame.minX, dy: -frame.minY),
                    isInteractive: visible, chromeVisible: chromeVisible, focusScope: focusScope,
                    focusChanged: { focusChanged(pane.id, $0) },
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
                .opacity(visible ? 1 : 0)
                .disabled(!visible)
                .accessibilityHidden(!visible)
            }
        }
        // Bridge Done's horizontal gap without absorbing the header or toolbar into this focus section.
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
    let editing: () -> Void
    let add: () -> Void
    let replace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LiveTVMultiviewHeader(exit: exit, editing: editing)
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
                collapse: collapse, editing: editing
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
        #endif
    }
}

private struct LiveTVMultiviewHeader: View {
    let exit: () -> Void
    let editing: () -> Void

    var body: some View {
        HStack {
            Text("Multiview").font(.headline)
            Spacer()
            LiveTVMultiviewAction(title: "Done", symbol: "xmark", action: exit, editing: editing)
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
    let focusScope: Namespace.ID
    let focusChanged: (Bool) -> Void
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
            if chromeVisible {
                if focused {
                    PrototypeFocusOutline(cornerRadius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(audible ? palette.accent : .white.opacity(0.15), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .foregroundStyle(.white)
        .onChange(of: focused) { _, value in focusChanged(value) }
        .onChange(of: pane.preparation.current?.id) { _, current in
            if focused, current != nil, isInteractive { preparedWhileFocused() }
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
    let editing: () -> Void
    @FocusState private var layoutFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                if coordinator.canAdd {
                    LiveTVMultiviewAction(title: "Add channel", symbol: "plus", action: add, editing: editing)
                        .accessibilityIdentifier("live-multiview-add")
                }
                Menu {
                    ForEach(LiveTVMultiviewLayout.allCases, id: \.self) { layout in
                        Button {
                            coordinator.layout = layout
                        } label: {
                            Label(layout.title, systemImage: coordinator.layout == layout ? "checkmark" : "rectangle")
                        }
                    }
                    if coordinator.layout == .corner {
                        Section("Position") {
                            ForEach(LiveTVMultiviewCorner.allCases, id: \.self) { corner in
                                Button(corner.title) { coordinator.corner = corner }
                            }
                        }
                        Section("Size") {
                            ForEach(LiveTVMultiviewInsetSize.allCases, id: \.self) { size in
                                Button(size.title) { coordinator.insetSize = size }
                            }
                        }
                    }
                } label: {
                    Label("Layout", systemImage: "rectangle.split.2x1")
                }
                .focused($layoutFocused)
                .onChange(of: layoutFocused) { _, focused in
                    if focused { editing() }
                }
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
                if coordinator.expandedPaneID != nil {
                    LiveTVMultiviewAction(
                        title: "Show both", symbol: "rectangle.split.2x1",
                        action: collapse, editing: editing
                    )
                    .accessibilityIdentifier("live-multiview-collapse")
                }
                if coordinator.panes.count > 1 {
                    LiveTVMultiviewAction(title: "Remove", symbol: "minus.circle", action: {
                        coordinator.remove(coordinator.audiblePaneID)
                    }, editing: editing)
                    .accessibilityIdentifier("live-multiview-remove")
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
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

private struct LiveTVMultiviewChannelPicker: View {
    let channels: [LiveTVPrototypeChannel]
    let favoriteIDs: Set<String>
    let selectedIDs: Set<String>
    let cancel: () -> Void
    let select: (LiveTVPrototypeChannel) -> Void
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var category: String?

    private var results: [LiveTVPrototypeChannel] {
        channels.filter { channel in
            (!favoritesOnly || favoriteIDs.contains(channel.id))
                && (category == nil || category == channel.category)
                && (query.isEmpty || channel.name.localizedStandardContains(query)
                    || channel.category.localizedStandardContains(query)
                    || String(channel.number).localizedStandardContains(query))
        }
    }

    var body: some View {
        #if os(tvOS)
        PrototypeNativeSearch(
            query: $query, restoresGuideFocus: false, isPresented: true,
            close: cancel, editing: {}
        ) { close in
            LiveTVMultiviewSearchResults(
                channels: results, categories: Array(Set(channels.map(\.category))).sorted(),
                selectedIDs: selectedIDs, query: query,
                favoritesOnly: $favoritesOnly, category: $category,
                cancel: close, select: select
            )
        }
        #else
        NavigationStack {
            channelList
                .searchable(text: $query, prompt: "Search channels")
                .navigationTitle("Choose channel")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                }
        }
        #endif
    }

    private var channelList: some View {
        List {
            Section {
                Toggle("Favorites only", isOn: $favoritesOnly)
                    .toggleStyle(SettingsSwitchToggleStyle())
                Picker("Category", selection: $category) {
                    Text("All categories").tag(String?.none)
                    ForEach(Array(Set(channels.map(\.category))).sorted(), id: \.self) { value in
                        Text(value).tag(Optional(value))
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                ForEach(results) { channel in
                    LiveTVMultiviewChannelRow(
                        channel: channel, isSelected: selectedIDs.contains(channel.id),
                        select: { select(channel) }
                    )
                }
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}

#if os(tvOS)
private struct LiveTVMultiviewSearchResults: View {
    let channels: [LiveTVPrototypeChannel]
    let categories: [String]
    let selectedIDs: Set<String>
    let query: String
    @Binding var favoritesOnly: Bool
    @Binding var category: String?
    let cancel: () -> Void
    let select: (LiveTVPrototypeChannel) -> Void

    var body: some View {
        VStack(spacing: 16) {
            PrototypeSearchFocusBoundary {
                HStack {
                    Text("Choose channel").font(.title2.weight(.semibold))
                    Spacer()
                    LiveTVMultiviewAction(title: "Cancel", symbol: "xmark", action: cancel)
                }
            }
            ScrollView {
                LazyVStack(spacing: 16) {
                    PrototypeSearchFocusBoundary {
                        Toggle("Favorites only", isOn: $favoritesOnly)
                            .toggleStyle(SettingsSwitchToggleStyle())
                    }
                    PrototypeSearchFocusBoundary {
                        Picker("Category", selection: $category) {
                            Text("All categories").tag(String?.none)
                            ForEach(categories, id: \.self) { value in
                                Text(value).tag(Optional(value))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(channels) { channel in
                        // Native Search needs the same row-sized UIKit boundary as the guide.
                        PrototypeSearchFocusBoundary {
                            LiveTVMultiviewChannelRow(
                                channel: channel, isSelected: selectedIDs.contains(channel.id),
                                select: { select(channel) }
                            )
                            .buttonStyle(PrototypeButtonStyle(surface: .guide))
                            .focusEffectDisabled()
                        }
                    }
                    if channels.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 48)
    }
}
#endif

private struct LiveTVMultiviewChannelRow: View {
    let channel: LiveTVPrototypeChannel
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 16) {
                ChannelLogoArtwork(
                    name: channel.name, logoURL: channel.logoURL,
                    size: CGSize(width: 72, height: 48), cornerRadius: 8
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                    Text(channel.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(channel.name)
        .accessibilityValue(channel.category)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("live-multiview-channel-\(channel.id)")
        .disabled(isSelected)
    }
}
#endif
