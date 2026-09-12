import CoreModels
@testable import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class CinematicDetailTransitionHostedTests: XCTestCase {
    func testCardZoomPauseStagesAndReverseReturnUseTheRealSource() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let sourceFrame = try XCTUnwrap(fixture.model.source.visibleFrame(in: fixture.window))
        fixture.model.open(in: fixture.window, usesCard: true)
        let initial = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        // Preparation covers navigation synchronously, before the destination appears.
        XCTAssertEqual(initial.screen.alpha, 1)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        try await waitUntil {
            guard let frame = initial.cardContainer.layer.presentation()?.frame else { return false }
            return frame.width > sourceFrame.width + 30 && frame.width < fixture.window.bounds.width - 30
        }
        XCTAssertEqual(initial.card.contentMode, .scaleAspectFill)
        XCTAssertTrue(session.blocksNavigation)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertEqual(session.stage, .artwork)
        XCTAssertTrue(session.blocksNavigation)
        XCTAssertNotNil(session.fallbackArtwork)
        let hidden = try pixel(fixture.window, at: try XCTUnwrap(fixture.model.frames[.logo]))
        XCTAssertGreaterThan(hidden[2], hidden[0] + 40)
        try await waitUntil { session.stage == .complete && fixture.model.stages.last == .complete }
        XCTAssertEqual(fixture.model.stages, [.artwork, .logo, .metadata, .controls, .complete])
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        let revealed = try pixel(fixture.window, at: try XCTUnwrap(fixture.model.frames[.logo]))
        XCTAssertGreaterThan(revealed[0], 240)
        XCTAssertGreaterThan(revealed[1], 240)
        let geometry = try XCTUnwrap(fixture.model.frames[.logo])
        XCTAssertGreaterThanOrEqual(geometry.minY, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(fixture.model.frames[.controls]).maxY, 1080)
        let history = XCTAttachment(string: fixture.model.events.joined(separator: "\n"))
        history.name = "cinematic-detail-stage-timeline"
        history.lifetime = .keepAlways
        add(history)

        session.close { fixture.model.path.removeLast() }
        XCTAssertTrue(session.isClosing)
        try await waitUntil {
            guard let cover = self.overlays(in: fixture.window).first,
                  let frame = cover.cardContainer.layer.presentation()?.frame else { return false }
            return frame.width < fixture.window.bounds.width - 30 && frame.width > sourceFrame.width + 30
        }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertNil(session.fallbackArtwork)
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertNotNil(fixture.model.source.visibleFrame(in: fixture.window))
        fixture.model.source.restoreFocus(in: fixture.window, preferred: nil)
        try await waitUntil {
            UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem != nil
        }
    }

    func testNoCardStillGetsArtworkPauseAndTheSameStagedEntrance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: false)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertNil(session.fallbackArtwork)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertEqual(session.stage, .artwork)
        try await waitUntil { session.stage == .complete && fixture.model.stages.last == .complete }
        XCTAssertEqual(fixture.model.stages, [.artwork, .logo, .metadata, .controls, .complete])
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
    }

    func testBackDuringTheZoomCancelsAllRemainingReveals() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertEqual(session.stage, .artwork)
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertFalse(fixture.model.stages.contains(.logo))
        XCTAssertNil(session.fallbackArtwork)
    }

    func testSourceReplacementUsesNonspatialReturnInsteadOfTheWrongCard() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        fixture.model.source.itemKey = "another-title"
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertTrue(fixture.model.path.isEmpty)
    }

    func testDisableAndDisappearanceReleaseTheInputGuardAndCover() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let disabled = TVDetailEntranceSession()
        disabled.attach(to: fixture.window, enabled: false)
        XCTAssertEqual(disabled.stage, .complete)
        XCTAssertFalse(disabled.blocksNavigation)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        session.finishImmediately()
        XCTAssertEqual(session.stage, .complete)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testPreparedSourceWithoutNavigationExpiresWithoutBlockingPlayback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.source.prepare(for: fixture.model.item)
        XCTAssertEqual(overlays(in: fixture.window).count, 1)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testInputGuardLeavesBackOutOfItsPressTypes() {
        let blocker = DetailTransitionInputGuard()
        XCTAssertFalse(blocker.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue)))
        XCTAssertTrue(blocker.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.select.rawValue)))
        XCTAssertTrue(blocker.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirect.rawValue)))
    }

    func testDirectPlaybackDoesNotPrepareOrRunADetailEntrance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        DetailTransitionNavigation.suppressNextEntrance(in: fixture.window)
        fixture.model.open(in: fixture.window, usesCard: true)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        try await waitUntil { fixture.model.session?.stage == .complete }
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertNil(fixture.model.session?.fallbackArtwork)
    }

    func testCoveredParentCannotDiscardItsChildsPreparedTransition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let parent = try XCTUnwrap(fixture.model.session)
        let child = MediaItem(id: "related-movie", title: "Related", kind: .movie)
        DetailTransitionNavigation.prepare(for: child, in: fixture.window, source: nil)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        parent.disappeared()
        XCTAssertTrue(overlays(in: fixture.window).contains { $0 === cover })
        let prepared = try XCTUnwrap(DetailTransitionNavigation.take(in: fixture.window))
        XCTAssertEqual(prepared.itemKey, child.stablePresentationID)
        prepared.discard()
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testDisabledPageDoesNotClaimALaterPreparedChild() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let parent = TVDetailEntranceSession()
        parent.attach(to: fixture.window, enabled: false)
        fixture.model.source.prepare(for: fixture.model.item)
        parent.attach(to: fixture.window, enabled: false)
        let prepared = try XCTUnwrap(DetailTransitionNavigation.take(in: fixture.window))
        prepared.discard()
    }

    func testTrailerHandoffUsesTheCapturedVideoFrameInsteadOfAScreenSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let videoFrame = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 12)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        }
        DetailTransitionNavigation.prepare(
            for: fixture.model.item, in: fixture.window, source: nil, artworkSnapshot: videoFrame
        )
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertTrue(cover.screen.image === videoFrame)
        DetailTransitionNavigation.take(in: fixture.window)?.discard()
    }

    func testRealPosterArtworkAnchorExcludesCaptionAndSurvivesOpaqueRasterization() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for style in [CardStyle.framed, .borderless] {
            for shape in [PosterCardView.Style.poster, .landscape] {
                let previous = scene.windows.first(where: \.isKeyWindow)
                let item = MediaItem(id: "actual-poster-\(style)", title: "Poster Caption", kind: .movie)
                let host = UIHostingController(rootView: PosterCardView(
                    item: item, style: shape, enablesAsyncArtworkFallback: false
                ) {}.frame(width: shape == .poster ? 240 : 520)
                    .environment(\.plozzCardStyle, style)
                    .environment(\.plozzReduceTransparency, true))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                defer {
                    DetailTransitionNavigation.take(in: window)?.discard()
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await waitUntil { self.sourceView(in: window)?.reference?.visibleFrame(in: window) != nil }
                let marker = try XCTUnwrap(sourceView(in: window))
                let source = try XCTUnwrap(marker.reference)
                let artwork = try XCTUnwrap(source.visibleFrame(in: window))
                let wholeCard = marker.convert(marker.bounds, to: window)
                XCTAssertEqual(
                    artwork.width / artwork.height,
                    shape == .poster ? 2.0 / 3.0 : 16.0 / 9.0, accuracy: 0.02
                )
                XCTAssertLessThan(artwork.maxY, wholeCard.maxY - 10, "The transition must not enlarge the caption")
                source.prepare(for: item)
                let cover = try XCTUnwrap(overlays(in: window).first)
                let image = try XCTUnwrap(cover.card.image)
                XCTAssertEqual(image.size.width, artwork.width, accuracy: 1)
                XCTAssertEqual(image.size.height, artwork.height, accuracy: 1)
            }
        }
    }

    private func sourceView(in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView { return source }
        return view.subviews.lazy.compactMap { self.sourceView(in: $0) }.first
    }

    private func pixel(_ window: UIWindow, at frame: CGRect) throws -> [Int] {
        let image = DetailTransitionSnapshot.image(of: window)
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: frame.midX, y: frame.midY, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }

    private func makeFixture() async throws -> CinematicFixtureWindow {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = CinematicFixtureWindow(scene: scene)
        try await waitUntil { fixture.model.source.visibleFrame(in: fixture.window) != nil }
        return fixture
    }

    private func overlays(in window: UIWindow) -> [DetailTransitionOverlay] {
        window.subviews.compactMap { $0 as? DetailTransitionOverlay }
    }

    private func inputGuards(in window: UIWindow) -> [DetailTransitionInputGuard] {
        (window.gestureRecognizers ?? []).compactMap { $0 as? DetailTransitionInputGuard }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Cinematic transition did not reach its expected state", file: file, line: line)
    }
}

@MainActor
private final class CinematicFixtureWindow {
    let window: UIWindow
    let previousWindow: UIWindow?
    let model = CinematicFixtureModel()

    init(scene: UIWindowScene) {
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: CinematicFixtureRoot(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
    }

    func close() {
        model.session?.finishImmediately()
        DetailTransitionNavigation.take(in: window)?.discard()
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

@MainActor @Observable
private final class CinematicFixtureModel {
    let item = MediaItem(id: "cinematic-movie", title: "Movie", kind: .movie)
    let source = DetailTransitionSourceReference()
    var path: [Int] = []
    @ObservationIgnored var session: TVDetailEntranceSession?
    @ObservationIgnored var stages: [DetailEntranceStage] = []
    @ObservationIgnored var frames: [DetailEntranceStage: CGRect] = [:]
    @ObservationIgnored var events: [String] = []

    func open(in window: UIWindow, usesCard: Bool) {
        DetailTransitionNavigation.prepare(for: item, in: window, source: usesCard ? source : nil)
        path.append(1)
    }
}

private struct CinematicFixtureRoot: View {
    @Bindable var model: CinematicFixtureModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Color.red
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .background {
                    DetailTransitionSourceAnchor(reference: model.source,
                                                 itemKey: model.item.stablePresentationID, cornerRadius: 24)
                }
                .focusable()
                .navigationDestination(for: Int.self) { _ in
                    CinematicFixturePage(model: model)
                        .cinematicDetailPage(isEnabled: true)
                }
        }
    }
}

private struct CinematicFixturePage: View {
    let model: CinematicFixtureModel
    @Environment(\.detailEntranceSession) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.white.frame(width: 200, height: 60)
                .detailEntranceStage(.logo)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.frames[.logo] = $0
                }
            Color.yellow.frame(width: 400, height: 60)
                .detailEntranceStage(.metadata)
            Button("Play") {}
                .detailEntranceStage(.controls)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.frames[.controls] = $0
                }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(.blue)
        .modifier(DetailTopSafeAreaBreakout())
        .onAppear {
            model.session = session
            model.stages = [.artwork]
        }
        .onChange(of: session?.stage) { _, stage in
            if let stage, model.stages.last != stage {
                model.stages.append(stage)
                model.events.append("\(Date().timeIntervalSince1970): \(stage)")
            }
        }
    }
}
