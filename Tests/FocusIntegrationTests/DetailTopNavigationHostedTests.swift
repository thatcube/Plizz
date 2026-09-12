import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailTopNavigationHostedTests: XCTestCase {
    func testDetailHeroRemainsFullBleedWithTopNavigation() async throws {
        try await verifyNavigation(mode: .top)
    }

    func testDetailHeroPreservesNativeSidebarLayout() async throws {
        try await verifyNavigation(mode: .sidebar)
    }

    func testDetailHeroPreservesStandaloneNavigationLayout() async throws {
        try await verifyNavigation(mode: .contentOnly)
    }

    private func verifyNavigation(mode: DetailNavigationMode) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = DetailNavigationFixture()
        let metrics = DetailNavigationMeasurements()
        let host = UIHostingController(rootView: DetailNavigationRoot(mode: mode, model: model, metrics: metrics))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await waitUntil { host.view.window === window && !host.view.bounds.isEmpty }
        for visit in 1...2 {
            model.foregroundVisible = false
            model.extraMetadata = false
            model.requestedAction = .automatic
            metrics.heroFrame = .zero
            withAnimation { model.path.append(visit) }
            try await waitUntil {
                metrics.detailVisible && metrics.heroFrame.minX >= 0 && metrics.heroFrame.width > 0
            }
            try await Task.sleep(for: .milliseconds(500))
            model.requestedAction = .play
            try await waitUntil { metrics.playFocused }
            assertGeometry(metrics, in: window, context: "\(mode), visit \(visit)")

            // A fully hidden foreground must still receive initial Play focus.
            XCTAssertTrue(metrics.playFocused)
            let hidden = try pixel(window, at: metrics.logoFrame.center)
            XCTAssertGreaterThan(hidden[2], hidden[0] + 40, "Artwork must remain visible before the title reveal")
            model.foregroundVisible = true
            try await Task.sleep(for: .milliseconds(550))
            let revealed = try pixel(window, at: metrics.logoFrame.center)
            XCTAssertGreaterThan(revealed[0], 240)
            XCTAssertGreaterThan(revealed[1], 240)
            assertGeometry(metrics, in: window, context: "\(mode), revealed")

            model.extraMetadata = true
            try await Task.sleep(for: .milliseconds(200))
            model.requestedAction = .more
            try await waitUntil { metrics.moreFocused }
            try await Task.sleep(for: .milliseconds(500))
            assertGeometry(metrics, in: window, context: "\(mode), late metadata and More focus")
            model.requestedAction = .cast
            try await waitUntil { metrics.castFocused }
            try await waitUntil { metrics.heroFrame.minY < -20 }
            model.requestedAction = .play
            try await waitUntil { metrics.playFocused }
            try await Task.sleep(for: .milliseconds(500))
            assertGeometry(metrics, in: window, context: "\(mode), returned from Cast")

            let log = XCTAttachment(string: metrics.events.joined(separator: "\n") + "\n" + hierarchy(window))
            log.name = "detail-\(mode)-visit-\(visit)-geometry"
            log.lifetime = .keepAlways
            add(log)
            withAnimation { _ = model.path.popLast() }
            try await waitUntil { !metrics.detailVisible }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func testReduceMotionShowsForegroundWithoutWaitingForTheReveal() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = DetailNavigationFixture()
        model.reduceMotion = true
        let metrics = DetailNavigationMeasurements()
        let host = UIHostingController(rootView:
            DetailNavigationRoot(mode: .top, model: model, metrics: metrics))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await waitUntil { host.view.window === window && !host.view.bounds.isEmpty }
        model.path.append(1)
        try await waitUntil { metrics.logoFrame.width > 0 }
        model.requestedAction = .play
        try await waitUntil { metrics.playFocused }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.foregroundVisible)
        let visible = try pixel(window, at: metrics.logoFrame.center)
        XCTAssertGreaterThan(visible[0], 240)
        XCTAssertGreaterThan(visible[1], 240)
        assertGeometry(metrics, in: window, context: "Reduce Motion")
    }

    private func assertGeometry(
        _ metrics: DetailNavigationMeasurements, in window: UIWindow, context: String
    ) {
        XCTAssertEqual(metrics.heroFrame.minY, 0, accuracy: 1)
        XCTAssertEqual(metrics.heroFrame.minX, 80, accuracy: 1, context)
        XCTAssertEqual(metrics.heroFrame.width, 1760, accuracy: 1, context)
        XCTAssertEqual(metrics.heroFrame.height, 1080, accuracy: 1, context)
        XCTAssertLessThanOrEqual(metrics.playFrame.maxY, window.bounds.maxY - 60, context)
    }

    private func pixel(_ window: UIWindow, at point: CGPoint) throws -> [Int] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let source = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(source.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.map(Int.init)
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "Detail navigation did not reach its expected layout/focus state", file: file, line: line)
    }

    private func hierarchy(_ view: UIView, depth: Int = 0) -> String {
        guard depth < 18 else { return "" }
        let scroll = (view as? UIScrollView).map {
            " offset=\($0.contentOffset) inset=\($0.contentInset) adjusted=\($0.adjustedContentInset)"
        } ?? ""
        return "\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(view.frame) safe=\(view.safeAreaInsets)\(scroll)\n"
            + view.subviews.map { hierarchy($0, depth: depth + 1) }.joined()
    }

}

@MainActor @Observable
private final class DetailNavigationFixture {
    var path: [Int] = []
    var foregroundVisible = false
    var reduceMotion = false
    var extraMetadata = false
    var requestedAction = DetailNavigationAction.automatic
}

private enum DetailNavigationMode {
    case top, sidebar, contentOnly
}

private enum DetailNavigationAction {
    case automatic, play, more, cast
}

@MainActor
private final class DetailNavigationMeasurements {
    var detailVisible = false
    var heroFrame = CGRect.zero
    var playFrame = CGRect.zero
    var logoFrame = CGRect.zero
    var playFocused = false
    var moreFocused = false
    var castFocused = false
    var events: [String] = []
}

private struct DetailNavigationRoot: View {
    let mode: DetailNavigationMode
    @Bindable var model: DetailNavigationFixture
    let metrics: DetailNavigationMeasurements
    @State private var selectedTab = 0

    var body: some View {
        switch mode {
        case .top:
            tabs.tabViewStyle(.tabBarOnly)
        case .sidebar:
            tabs.tabViewStyle(.sidebarAdaptable)
        case .contentOnly:
            navigation
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                navigation
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                Button("Search") {}
            }
        }
    }

    private var navigation: some View {
        NavigationStack(path: $model.path) {
            Button("Open Movie") { model.path.append(1) }
                .navigationDestination(for: Int.self) { _ in
                    DetailNavigationPage(model: model, metrics: metrics)
                }
        }
    }
}

private struct DetailNavigationPage: View {
    let model: DetailNavigationFixture
    let metrics: DetailNavigationMeasurements
    @FocusState private var playFocused: Bool
    @FocusState private var moreFocused: Bool
    @FocusState private var castFocused: Bool
    @Namespace private var heroActionsScope

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.white.frame(width: 100, height: 40)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                metrics.logoFrame = $0
                            }
                        Text("Movie").font(.largeTitle)
                        if model.extraMetadata {
                            Text("Additional ratings and metadata").frame(height: 80)
                        }
                        HStack(spacing: 24) {
                            Button("Play") {}
                                .prefersDefaultFocus(true, in: heroActionsScope)
                                .focused($playFocused)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    metrics.playFrame = $0
                                    metrics.events.append("play \($0)")
                                }
                            Button("More") {}.focused($moreFocused)
                        }
                        .focusScope(heroActionsScope)
                        .focusSection()
                    }
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, minHeight: 1080, alignment: .bottomLeading)
                    .modifier(DetailHeroContentReveal(
                        isVisible: model.foregroundVisible, reduceMotion: model.reduceMotion
                    ))
                    .background(.blue)
                    .id("hero")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        metrics.heroFrame = $0
                        metrics.events.append("hero \($0)")
                    }
                    Button("Cast") {}
                        .focused($castFocused)
                        .frame(height: 600)
                }
                .frame(width: 1760, alignment: .leading)
            }
            .defaultFocus($playFocused, true, priority: .userInitiated)
            .onChange(of: playFocused) { _, focused in
                metrics.playFocused = focused
                if focused {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("hero", anchor: .top)
                    }
                }
            }
            .onChange(of: moreFocused) { _, focused in
                metrics.moreFocused = focused
                if focused {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("hero", anchor: .top)
                    }
                }
            }
            .onChange(of: castFocused) { _, focused in metrics.castFocused = focused }
            .onChange(of: model.requestedAction) { _, action in
                switch action {
                case .automatic: break
                case .play: playFocused = true
                case .more: moreFocused = true
                case .cast: castFocused = true
                }
            }
            .onDisappear {
                metrics.detailVisible = false
                metrics.playFocused = false
                metrics.moreFocused = false
                metrics.castFocused = false
            }
            .scrollClipDisabled()
            .modifier(DetailTopSafeAreaBreakout())
            .onScrollGeometryChange(for: String.self) {
                "scroll offset=\($0.contentOffset) insets=\($0.contentInsets) viewport=\($0.containerSize)"
            } action: { _, value in
                metrics.events.append(value)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { metrics.detailVisible = true }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
