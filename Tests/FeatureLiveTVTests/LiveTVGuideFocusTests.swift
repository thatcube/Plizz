#if DEBUG && os(tvOS)
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVGuideFocusTests: XCTestCase {
    func testSearchPresentationConfiguration() {
        let controller = PrototypeSearchController(searchResultsController: UIViewController())
        controller.modalPresentationStyle = .custom
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.modalPresentationStyle, .custom)
        XCTAssertTrue(controller.backPress.view === controller.view)
    }

    func testNativeFocusReturnsToTheRequestedOccurrenceIncludingAnOffscreenMainRow() async throws {
        try await requireNativeFocus()
        for section in [LiveTVGuideSection.channels, .favorites, .recent] {
            let probe = try GuideFocusProbe(section: section)
            let window = makeWindow(GuideFocusHarness(probe: probe))
            defer { window.isHidden = true; window.rootViewController = nil }

            await waitForCompletion(probe)
            XCTAssertTrue(probe.completed, "Unfinished handoff in \(section)")
            XCTAssertTrue(probe.hasFocus, "No native guide focus in \(section)")
            XCTAssertEqual(probe.selectedRow, probe.origin)
            XCTAssertEqual(probe.focusedProgram?.id, "current")
            XCTAssertFalse(probe.railActive)
        }
    }

    func testUnfocusableGuideReleasesRestorationAndCanBeEnteredAgain() async throws {
        try await requireNativeFocus()
        let probe = try GuideFocusProbe(section: .channels)
        probe.disablesGuide = true
        let window = makeWindow(GuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }

        await waitForCompletion(probe)
        XCTAssertTrue(probe.completed)
        XCTAssertFalse(probe.restoring)
        XCTAssertFalse(probe.railActive)

        probe.disablesGuide = false
        probe.completed = false
        probe.restoresPlayback = false
        probe.request += 1
        probe.restoring = true
        await waitForCompletion(probe)
        XCTAssertTrue(probe.completed)
        XCTAssertTrue(probe.hasFocus)
        XCTAssertEqual(probe.selectedRow, probe.origin)
    }

    func testUnfocusableGuideReleasesBothEntryGates() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.disablesGuide = true
        let window = makeWindow(GuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        await waitForCompletion(probe)
        XCTAssertTrue(probe.completed)
        XCTAssertFalse(probe.restoring)
        XCTAssertFalse(probe.railActive)
        XCTAssertFalse(probe.hasFocus)
    }

    func testNativeSearchUpdatesTheSameGuideInsteadOfAnotherResultList() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        probe.selectedRow = probe.model.guideChannels.first?.id
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller = try await waitForSearch(in: window)
        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertNotNil(results.view.window)
        controller.searchBar.text = "Channel 2"
        controller.searchResultsUpdater?.updateSearchResults(for: controller)
        await Task.yield()
        XCTAssertEqual(probe.model.query, "Channel 2")
        XCTAssertEqual(probe.model.visibleChannels.count, 11)
        XCTAssertEqual(probe.model.guideChannels.filter { $0.section == .channels }.count, 11)
        XCTAssertTrue(controller.searchResultsController === results)
    }

    func testNativeSearchBackClosesFromTheKeyboardWithOrWithoutAQuery() async throws {
        for query in ["", "Channel 2"] {
            let probe = try GuideFocusProbe(section: .channels)
            probe.restoring = false
            probe.model.query = query
            let window = makeWindow(NativeGuideFocusHarness(probe: probe))
            defer { window.isHidden = true; window.rootViewController = nil }
            let controller = try await waitForSearch(in: window)
            XCTAssertEqual(controller.backPress.allowedPressTypes, [NSNumber(value: UIPress.PressType.menu.rawValue)])
            XCTAssertTrue(controller.backPress.view === controller.view)
            controller.closeFromRemote()
            controller.closeFromRemote()
            await waitUntil { probe.searchClosed && controller.view.window == nil }
            XCTAssertTrue(probe.searchClosed)
            XCTAssertEqual(probe.searchCloseCount, 1)
            XCTAssertNil(controller.view.window)
        }
    }

    func testTemporarySearchDeactivationDoesNotCloseOrDiscardItsResultsHost() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        probe.model.query = "Channel 2"
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller = try await waitForSearch(in: window)
        let results = try XCTUnwrap(controller.searchResultsController)
        probe.searchPresented = false
        await waitUntil { results.view.window == nil }
        XCTAssertNil(results.view.window)
        XCTAssertFalse(probe.searchClosed)
        XCTAssertEqual(probe.searchCloseCount, 0)
        probe.searchPresented = true
        await waitUntil { results.view.window != nil }
        XCTAssertNotNil(results.view.window)
        XCTAssertEqual(probe.model.query, "Channel 2")
        XCTAssertTrue(controller.searchResultsController === results)
    }

    func testNativeNavigationBackAlsoClosesSearchOnce() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller = try await waitForSearch(in: window)
        let navigation = try XCTUnwrap(controller.presentingViewController?.navigationController)
        navigation.popViewController(animated: false)
        await waitUntil { probe.searchClosed }
        XCTAssertTrue(probe.searchClosed)
        XCTAssertEqual(probe.searchCloseCount, 1)
        XCTAssertNil(controller.view.window)
    }

    func testNativeSidebarKeepsItsRootLiveTVContentAcrossSearchAndPlaybackVisibility() async throws {
        // This verifies the Live TV root and Search host stay alive.
        // Actual system-sidebar suppression still requires an app-hosted device trial.
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        probe.model.query = "Channel 2"
        let window = makeWindow(NativeSidebarSearchHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let search = try await waitForSearch(in: window)
        let root = try XCTUnwrap(window.rootViewController)
        let results = try XCTUnwrap(search.searchResultsController)
        let appearances = probe.liveContentAppearances
        let disappearances = probe.liveContentDisappearances
        // A standalone native TabView currently settles at 2/1 rather than 1/0.
        // Compare the settled baseline instead of assuming absolute lifecycle counts.
        XCTAssertEqual(appearances, disappearances + 1)

        probe.searchPresented = false
        await waitUntil { results.view.window == nil }
        XCTAssertNil(results.view.window)
        XCTAssertTrue(window.rootViewController === root)
        XCTAssertEqual(probe.model.query, "Channel 2")
        probe.searchPresented = true
        await waitUntil { results.view.window != nil }
        XCTAssertTrue(search.searchResultsController === results)
        search.closeFromRemote()
        await waitUntil { probe.searchClosed }
        probe.navigationExcluded = false
        await Task.yield()
        XCTAssertTrue(window.rootViewController === root)
        probe.navigationExcluded = true
        probe.searchClosed = false
        _ = try await waitForSearch(in: window)
        XCTAssertTrue(window.rootViewController === root)
        XCTAssertEqual(probe.liveContentAppearances, appearances)
        XCTAssertEqual(probe.liveContentDisappearances, disappearances)
    }

    func testBackFromTheGuideCannotExposeAnEmptyNavigationRoot() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        probe.searchClosed = true
        probe.navigationExcluded = false
        let window = makeWindow(NativeSidebarSearchHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        await waitUntil { probe.dismissGuide != nil }
        let dismiss = try XCTUnwrap(probe.dismissGuide)
        let appearances = probe.liveContentAppearances
        let disappearances = probe.liveContentDisappearances
        XCTAssertEqual(appearances, disappearances + 1)

        dismiss()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(probe.liveContentAppearances, appearances)
        XCTAssertEqual(probe.liveContentDisappearances, disappearances)
        XCTAssertFalse(probe.navigationExcluded)
    }

    func testSearchCanCloseWhileGuideFocusIsRecovering() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let controller = try await waitForSearch(in: window)
        controller.closeFromRemote()
        await waitUntil { probe.searchClosed && controller.view.window == nil }
        XCTAssertTrue(probe.searchClosed)
        XCTAssertEqual(probe.searchCloseCount, 1)
        XCTAssertNil(controller.view.window)
    }

    func testInactiveSearchWaitsForActivationWithoutLosingTheQuery() async throws {
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        probe.searchPresented = false
        probe.model.query = "Channel 2"
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(findSearch(in: root))
        probe.searchPresented = true
        let controller = try await waitForSearch(in: window)
        XCTAssertEqual(controller.searchBar.text, "Channel 2")
        XCTAssertEqual(probe.model.query, "Channel 2")
        XCTAssertFalse(probe.searchClosed)
    }

    func testNativeSearchUsesTheFullScreenAndItsGuideReachesBottomAndTrailingEdges() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let probe = try GuideFocusProbe(section: .channels)
            probe.restoring = false
            let window = makeWindow(NativeGuideFocusHarness(probe: probe, direction: direction))
            defer { window.isHidden = true; window.rootViewController = nil }
            let controller = try await waitForSearch(in: window)
            await waitUntil { probe.resultsFrame != nil }
            XCTAssertEqual(controller.modalPresentationStyle, .custom)
            let presentation = try XCTUnwrap(controller.presentationController)
            XCTAssertFalse(presentation.shouldRemovePresentersView)
            let searchFrame = controller.view.convert(controller.view.bounds, to: window)
            XCTAssertEqual(searchFrame.minX, window.bounds.minX, accuracy: 1)
            XCTAssertEqual(searchFrame.maxX, window.bounds.maxX, accuracy: 1)
            XCTAssertEqual(searchFrame.maxY, window.bounds.maxY, accuracy: 1)
            let frame = try XCTUnwrap(probe.resultsFrame)
            XCTAssertEqual(frame.maxY, window.bounds.maxY, accuracy: 1)
            if direction == .leftToRight {
                XCTAssertEqual(frame.maxX, window.bounds.maxX, accuracy: 1)
            } else {
                XCTAssertEqual(frame.minX, window.bounds.minX, accuracy: 1)
            }
        }
    }

    func testSearchFadeRespectsReducedMotion() {
        let controller = PrototypeSearchController(searchResultsController: UIViewController())
        XCTAssertEqual(controller.fadeDuration, 0.18, accuracy: 0.001)
        controller.reduceMotion = true
        XCTAssertEqual(controller.fadeDuration, 0)
    }

    func testNativeSearchRestoresProgrammeFocusBelowItsKeyboard() async throws {
        try await requireNativeFocus()
        let probe = try GuideFocusProbe(section: .channels)
        probe.restoring = false
        let window = makeWindow(NativeGuideFocusHarness(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        probe.request += 1
        probe.restoring = true
        await waitForCompletion(probe)
        XCTAssertTrue(probe.completed)
        XCTAssertTrue(probe.hasFocus)
        XCTAssertEqual(probe.selectedRow, probe.origin)
        XCTAssertEqual(probe.focusedProgram?.id, "current")
    }

    private func requireNativeFocus() async throws {
        let window = makeWindow(Color.black)
        let controller = UIViewController()
        let button = UIButton(type: .system)
        button.setTitle("Focus baseline", for: .normal)
        button.frame = CGRect(x: 100, y: 100, width: 300, height: 100)
        controller.view.addSubview(button)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let system = UIFocusSystem.focusSystem(for: button)
        system?.requestFocusUpdate(to: button)
        system?.updateFocusIfNeeded()
        for _ in 0..<10 {
            if button.isFocused { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip(
            "The test host cannot focus a standalone UIKit button; native focus assertions require an app-hosted run. "
                + "Scene state: \(window.windowScene?.activationState.rawValue ?? -99), key window: \(window.isKeyWindow)."
        )
    }

    private func findSearch(in controller: UIViewController) -> UISearchController? {
        if let container = controller as? UISearchContainerViewController { return container.searchController }
        if let search = controller as? UISearchController { return search }
        for child in controller.children {
            if let search = findSearch(in: child) { return search }
        }
        return controller.presentedViewController.flatMap { findSearch(in: $0) }
    }

    private func waitForSearch(in window: UIWindow) async throws -> PrototypeSearchController {
        let root = try XCTUnwrap(window.rootViewController)
        await waitUntil {
            guard let search = self.findSearch(in: root) else { return false }
            return search.searchResultsController?.view.window != nil
                && !search.isBeingPresented
        }
        let controller = try XCTUnwrap(findSearch(in: root) as? PrototypeSearchController)
        XCTAssertNotNil(controller.searchResultsController?.view.window)
        XCTAssertFalse(controller.isBeingPresented)
        return controller
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeWindow<Content: View>(_ content: Content) -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func waitForCompletion(_ probe: GuideFocusProbe) async {
        for _ in 0..<100 {
            if probe.completed { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
@Observable
private final class GuideFocusProbe {
    let model: LiveTVPrototypeModel
    let origin: LiveTVGuideRowID
    var selectedID: String? = "24"
    var selectedRow: LiveTVGuideRowID?
    var railActive = true
    var focusedProgram: LiveTVPrototypeProgram?
    var hasFocus = false
    var offset: TimeInterval = 0
    var timelineOffset: CGFloat = 0
    var anchor = Date(timeIntervalSince1970: 1_800_000_000)
    var request = 1
    var restoring = true
    var restoresPlayback = true
    var completed = false
    var disablesGuide = false
    var searchClosed = false
    var searchCloseCount = 0
    var searchPresented = true
    var resultsFrame: CGRect?
    var navigationExcluded = true
    var liveContentAppearances = 0
    var liveContentDisappearances = 0
    var dismissGuide: (() -> Void)?

    init(section: LiveTVGuideSection) throws {
        origin = LiveTVGuideRowID(channelID: "24", section: section)
        selectedRow = origin
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model = LiveTVPrototypeModel(now: now, scenario: .noGuide, channels: (0..<30).map {
            LiveTVPrototypeChannel(
                id: "\($0)", number: $0, name: "Channel \($0)", category: "News",
                symbol: "tv", accent: 0, source: .iptv, tagline: ""
            )
        })
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "current", channelID: "24", title: "Current programme", subtitle: "",
                start: now.addingTimeInterval(-300), end: now.addingTimeInterval(3_600)
            )
        ])
        model.toggleFavorite("24")
        model.tune("24")
        model.recordWatched("24")
    }
}

private struct GuideFocusHarness: View {
    @Bindable var probe: GuideFocusProbe
    var fixedSize = true
    var searchExit: () -> Void = {}
    @State private var imports = LiveTVPrototypeImportModel()

    var body: some View {
        PrototypeBrowser(
            model: probe.model, imports: imports,
            selectedID: $probe.selectedID, selectedRowID: $probe.selectedRow,
            railActive: $probe.railActive, focusedProgram: $probe.focusedProgram,
            hasFocus: $probe.hasFocus, topRequest: 0, nowRequest: 0,
            guideOffset: $probe.offset, timeAnchor: $probe.anchor, timelineOffset: $probe.timelineOffset,
            restoreFocusRequest: probe.request, isPresented: true,
            isRestoringFocus: probe.restoring, restoresPlaybackFocus: probe.restoresPlayback,
            watchOrigin: probe.origin,
            focusRestored: { request in
                guard request == probe.request else { return }
                probe.restoring = false
                probe.completed = true
            },
            tune: { _ in }, details: { _ in }, openControls: {},
            openSources: {}, openGuideTime: {}, openToolbar: searchExit,
            isLoading: false, loadFailed: false, reload: {}
        )
        .frame(width: fixedSize ? 1_400 : nil, height: fixedSize ? 750 : nil)
        .disabled(probe.disablesGuide)
    }
}

private struct NativeGuideFocusHarness: View {
    @Bindable var probe: GuideFocusProbe
    var direction = LayoutDirection.leftToRight

    var body: some View {
        ZStack {
            if !probe.searchClosed {
                PrototypeNativeSearch(
                    query: Binding(get: { probe.model.query }, set: { probe.model.query = $0 }),
                    restoresGuideFocus: probe.restoring, isPresented: probe.searchPresented,
                    close: { probe.searchClosed = true; probe.searchCloseCount += 1 },
                    editing: { probe.railActive = true }
                ) { close in
                    GuideFocusHarness(probe: probe, fixedSize: false, searchExit: close)
                        .background {
                            NativeSearchViewportProbe { probe.resultsFrame = $0 }
                        }
                        .ignoresSafeArea(.container, edges: [.bottom, .trailing])
                        .environment(\.layoutDirection, direction)
                }
                .ignoresSafeArea()
            }
        }
    }
}

private struct NativeSidebarSearchHarness: View {
    let probe: GuideFocusProbe

    var body: some View {
        TabView {
            Tab("Live TV", systemImage: "tv") {
                LiveTVNavigationContainer(hidesNavigation: probe.navigationExcluded) {
                    ZStack {
                        Color.black
                        NativeGuideFocusHarness(probe: probe)
                        NativeGuideDismissProbe(probe: probe)
                    }
                    .onAppear { probe.liveContentAppearances += 1 }
                    .onDisappear { probe.liveContentDisappearances += 1 }
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                Text("Settings")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private struct NativeGuideDismissProbe: View {
    let probe: GuideFocusProbe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .onAppear { probe.dismissGuide = { dismiss() } }
    }
}

private struct NativeSearchViewportProbe: UIViewRepresentable {
    let report: (CGRect) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.report = report
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.report = report
    }

    final class ProbeView: UIView {
        var report: ((CGRect) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            if let window { report?(convert(bounds, to: window)) }
        }
    }
}
#endif
