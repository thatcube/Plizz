import FeatureLiveTVCore
import Foundation
import SwiftUI
@testable import FeatureLiveTV

@main
struct SearchFixtureApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--source-fixture")
            || ProcessInfo.processInfo.arguments.contains("--live-root-fixture") {
            URLProtocol.registerClass(SourceSmokeNetworkBlocker.self)
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--search-fixture") {
                SearchFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--source-fixture") {
                SourceOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--navigation-fixture") {
                NavigationRailFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--multiview-fixture") {
                MultiviewFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--live-root-fixture") {
                LiveTVRootFixture()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }
}

struct SearchFixture: View {
    @State private var model: LiveTVPrototypeModel
    @State private var imports = LiveTVPrototypeImportModel()
    @State private var selectedID: String?
    @State private var selectedRow: LiveTVGuideRowID?
    @State private var railActive = true
    @State private var hasFocus = false
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor = Date(timeIntervalSince1970: 1_800_000_000)
    @State private var timelineOffset: CGFloat = 0
    @State private var closeCount = 0
    private let direction: LayoutDirection

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        direction = arguments.contains("--rtl") ? .rightToLeft : .leftToRight
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = LiveTVPrototypeModel(now: now, scenario: .noGuide, channels: (0..<30).map {
            LiveTVPrototypeChannel(
                id: "\($0)", number: $0, name: "Channel \($0)", category: "News",
                symbol: "tv", accent: 0, source: .iptv, tagline: ""
            )
        })
        if arguments.contains("--programmes") {
            try! model.replacePrograms((0..<30).map {
                LiveTVPrototypeProgram(
                    id: "current-\($0)", channelID: "\($0)", title: "Current programme \($0)",
                    subtitle: "", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(3_600)
                )
            })
        }
        if arguments.contains("--filtered") { model.query = "Channel 2" }
        _model = State(initialValue: model)
        _selectedID = State(initialValue: model.guideChannels.first?.channel.id)
        _selectedRow = State(initialValue: model.guideChannels.first?.id)
    }

    var body: some View {
        if closeCount > 0 {
            Text(verbatim: "Search closed \(closeCount)")
                .accessibilityIdentifier("search-closed")
        } else if ProcessInfo.processInfo.arguments.contains("--without-search") {
            results(close: {})
        } else {
            PrototypeNativeSearch(
                query: $model.query, restoresGuideFocus: false, isPresented: true,
                close: { closeCount += 1 }, editing: { railActive = true }
            ) { close in
                results(close: close)
            }
            .ignoresSafeArea()
        }
    }

    private func results(close: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: "Selection \(selectedID ?? "nil") focus \(hasFocus)")
                .accessibilityIdentifier("selection-probe")
            PrototypeBrowser(
                model: model, imports: imports,
                selectedID: $selectedID, selectedRowID: $selectedRow,
                railActive: $railActive, focusedProgram: $focusedProgram,
                hasFocus: $hasFocus, topRequest: 0, nowRequest: 0,
                guideOffset: $guideOffset, timeAnchor: $timeAnchor,
                timelineOffset: $timelineOffset,
                restoreFocusRequest: 0, isPresented: true,
                isRestoringFocus: false, restoresPlaybackFocus: false,
                watchOrigin: nil, focusRestored: { _ in },
                tune: { _ in }, details: { _ in }, openControls: {},
                openSources: {}, openGuideTime: {}, openToolbar: close,
                isLoading: false, loadFailed: false, reload: {}
            )
        }
        .ignoresSafeArea(.container, edges: [.bottom, .trailing])
        .environment(\.layoutDirection, direction)
    }
}
