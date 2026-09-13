import CoreModels
@testable import CoreUI
import FeatureHome
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailTransitionVisualRegressionTests: XCTestCase {
    func testThumbnailIsGoneBeforeLandingWhileDestinationArtworkExpands() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        fixture.source.prepare(for: fixture.item)
        fixture.controller.view.backgroundColor = .blue
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        session.resolvedDestinationArtwork(backdrop)
        session.attach(to: fixture.window, enabled: true)
        let overlay = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        try await Task.sleep(for: .milliseconds(250))
        let frame = try XCTUnwrap(overlay.cardContainer.layer.presentation()?.frame)
        XCTAssertGreaterThan(frame.width, 300)
        XCTAssertLessThan(frame.width, fixture.window.bounds.width - 20)
        XCTAssertLessThan(overlay.card.layer.presentation()?.opacity ?? 1, 0.05)
        XCTAssertGreaterThan(overlay.destination.layer.presentation()?.opacity ?? 0, 0.8)
        XCTAssertTrue(overlay.destination.image === backdrop)
        try await waitUntil { overlay.superview == nil }
        XCTAssertEqual(session.stage, .artwork)
    }

    func testReturnMatchesFocusedArtworkFrameAndContinuousScaledCorners() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        fixture.controller.prefersCard = true
        system.requestFocusUpdate(to: fixture.controller)
        system.updateFocusIfNeeded()
        try await waitUntil { fixture.controller.card.isFocused }
        fixture.source.prepare(for: fixture.item)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        fixture.controller.prefersCard = false
        system.requestFocusUpdate(to: fixture.controller)
        system.updateFocusIfNeeded()
        try await waitUntil { !fixture.controller.card.isFocused }
        session.attach(to: fixture.window, enabled: true)
        try await waitUntil { session.stage == .complete }
        session.close { fixture.controller.prefersCard = true }
        let overlay = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        try await waitUntil { overlay.cardContainer.frame.width < fixture.window.bounds.width - 20 }
        let target = overlay.cardContainer.frame
        let radius = overlay.cardContainer.layer.cornerRadius
        XCTAssertEqual(overlay.cardContainer.layer.cornerCurve, .continuous)
        try await waitUntil { overlay.superview == nil && fixture.controller.card.isFocused }
        let current = try XCTUnwrap(fixture.source.geometry(in: fixture.window))
        XCTAssertEqual(target.minX, current.frame.minX, accuracy: 0.5)
        XCTAssertEqual(target.minY, current.frame.minY, accuracy: 0.5)
        XCTAssertEqual(target.width, current.frame.width, accuracy: 0.5)
        XCTAssertEqual(target.height, current.frame.height, accuracy: 0.5)
        XCTAssertEqual(radius, current.cornerRadius, accuracy: 0.5)
        XCTAssertGreaterThan(radius, fixture.source.cornerRadius)
    }

    func testProductionShowDoesNotScrollIntoEpisodesWhileTheHeroEnters() async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let originalSettings = settingsStore.load()
        var settings = originalSettings
        settings.preferOnlineArtwork = false
        settingsStore.save(settings)
        defer { settingsStore.save(originalSettings) }
        let scene = try await activeScene()
        let artwork = try await seedArtwork()
        let provider = TransitionShowProvider(artwork: artwork)
        let model = TransitionShowModel(provider: provider)
        let host = UIHostingController(rootView: TransitionShowRoot(model: model))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        DetailTransitionNavigation.prepare(for: provider.show, in: window, source: nil)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        model.path.append(1)
        try await waitUntil {
            model.detail.state.value?.childrenLoaded == true && self.verticalScroll(in: host.view) != nil
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(cover.destination.image, "Use the actual backdrop resolved by the production hero.")
        let scroll = try XCTUnwrap(verticalScroll(in: host.view))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 2,
                       "The artwork pause must not move into the episode browser.")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 2,
                       "A whole-show open must stay on its hero when controls finish appearing.")
        let shot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        shot.name = "production-series-entrance"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testMissingDetailBackdropDoesNotReuseTheOutgoingPoster() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        fixture.source.prepare(for: fixture.item)
        let session = TVDetailEntranceSession()
        session.attach(to: fixture.window, enabled: true)
        session.finishImmediately()
        XCTAssertNotNil(session.returnArtwork, "The small snapshot is retained only for returning to the card.")
        let host = UIHostingController(rootView: HeroBackdropLayer(
            references: [], height: 1080, scrimTone: .black, ignoresOverscan: false
        ).environment(\.detailEntranceSession, session))
        host.view.backgroundColor = .black
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = DetailTransitionSnapshot.image(of: fixture.window)
        let sample = try XCTUnwrap(screenshot.cgImage?.cropping(to: CGRect(x: 960, y: 100, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThan(bytes[0], 30, "The red outgoing thumbnail must not become the page's backdrop.")
    }

    func testRealPosterReturnMatchesItsFocusedPaintedArtwork() async throws {
        let scene = try await activeScene()
        let artwork = try await seedArtwork(color: .red, size: CGSize(width: 200, height: 300))
        let layouts: [(CardStyle, PosterCardView.Style)] = [
            (.framed, .poster), (.borderless, .poster),
            (.framed, .landscape), (.borderless, .landscape)
        ]
        for (style, shape) in layouts {
            for focusStyle in CardFocusStyle.allCases {
                let model = RealPosterReturnModel(artwork: artwork)
                let host = UIHostingController(rootView: RealPosterReturnRoot(
                    model: model, style: style, focusStyle: focusStyle, shape: shape
                ))
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                defer {
                    model.session?.finishImmediately()
                    DetailTransitionNavigation.take(in: window)?.discard()
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await waitUntil { self.sourceView(in: host.view)?.reference?.isFocused == true }
                let source = try XCTUnwrap(sourceView(in: host.view)?.reference)
                try await Task.sleep(for: .milliseconds(600))
                let before = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                before.name = "focused-source-\(style)-\(shape)-\(focusStyle)"
                before.lifetime = .keepAlways
                add(before)
                let initialPainted = try redArtworkBounds(in: window)
                let initialGeometry = try XCTUnwrap(source.geometry(in: window))
                if focusStyle == .system {
                    XCTAssertNotNil(source.nativeArtworkView, "System artwork must use native UIKit geometry.")
                }
                source.prepare(for: model.item)
                model.path.append(1)
                try await waitUntil { model.session != nil }
                let session = try XCTUnwrap(model.session)
                try await waitUntil { session.stage == .complete }
                session.close { model.path.removeLast() }
                let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
                try await waitUntil { cover.cardContainer.frame.width < 1000 }
                let target = cover.cardContainer.frame
                let radius = cover.cardContainer.layer.cornerRadius
                try await waitUntil { cover.superview == nil && source.isFocused == true }
                try await Task.sleep(for: .milliseconds(600))
                let painted = try redArtworkBounds(in: window)
                let after = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                after.name = "focused-return-\(style)-\(shape)-\(focusStyle)"
                after.lifetime = .keepAlways
                add(after)
                let geometry = XCTAttachment(string: "Before: geometry \(initialGeometry), pixels \(initialPainted)\nAfter: geometry \(String(describing: source.geometry(in: window))), pixels \(painted)\n\(nativeProjectionDescription(source.nativeArtworkView, in: window))")
                geometry.name = "native-geometry-\(style)-\(shape)-\(focusStyle)"
                geometry.lifetime = .keepAlways
                add(geometry)
                XCTAssertEqual(target.minX, painted.minX, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.minY, painted.minY, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.width, painted.width, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.height, painted.height, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(radius, try XCTUnwrap(source.geometry(in: window)).cornerRadius, accuracy: 0.5)
            }
        }
    }

    func testNativeCircularTileHasNoSquareFocusPlate() async throws {
        let scene = try await activeScene()
        let artwork = try await seedArtwork(color: .red, size: CGSize(width: 200, height: 200))
        let previous = scene.windows.first(where: \.isKeyWindow)
        var focused = false
        let host = UIHostingController(rootView: CircularFocusTile(
            diameter: 200, focusPadding: 20, action: {},
            onFocusChange: { focused = $0 },
            avatar: { FallbackAsyncImage(urls: [artwork], variant: .personHeadshot) { Color.clear } },
            caption: { _ in Text("Circular portrait") }
        )
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.themePalette, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { focused }
        try await Task.sleep(for: .milliseconds(700))
        let image = DetailTransitionSnapshot.image(of: window)
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-circular-focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        let painted = try redArtworkBounds(in: window)
        XCTAssertEqual(painted.width, painted.height, accuracy: 2)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        let cgImage = try XCTUnwrap(image.cgImage)
        for corner in [
            CGPoint(x: painted.minX + 4, y: painted.minY + 4),
            CGPoint(x: painted.maxX - 4, y: painted.minY + 4)
        ] {
            let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(origin: corner, size: CGSize(width: 1, height: 1))))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertLessThan(bytes.prefix(3).max() ?? 255, 20, "Native focus must not add a square plate behind the portrait.")
        }
    }

    func testSystemFocusSurvivesRapidHorizontalAndVerticalReversals() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = NativeFocusGridHost()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.layoutIfNeeded()
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        try await waitUntil { system.focusedItem != nil }
        let frames = host.cards.map { $0.view.frame }
        for index in [1, 0, 1, 3, 1, 0, 2, 0, 2, 3, 2, 0] {
            host.preferredIndex = index
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await waitUntil {
                guard let item = system.focusedItem,
                      let owner = TVNavigationExitProtectionFocus.containingView(of: item) else { return false }
                return owner.isDescendant(of: host.cards[index].view)
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(host.cards.map { $0.view.frame }, frames, "Projection must not change the grid's layout.")
        }
        try await Task.sleep(for: .milliseconds(650))
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "native-focus-after-rapid-reversals"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIndependentFocusSurfaceRemainsFocusableInSystemCardMode() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        var focused = false
        let host = UIHostingController(rootView: IndependentFocusSurface { focused = $0 }
            .environment(\.plozzCardFocusStyle, .system))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { focused }
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
    }

    private func sourceView(in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView { return source }
        return view.subviews.lazy.compactMap { self.sourceView(in: $0) }.first
    }

    private func nativeProjectionDescription(_ view: UIView?, in window: UIWindow) -> String {
        var current = view
        var lines: [String] = []
        while let ancestor = current, ancestor !== window {
            lines.append("\(type(of: ancestor)): frame \(ancestor.frame), bounds \(ancestor.bounds), transform \(ancestor.layer.transform), sublayers \(ancestor.layer.sublayerTransform)")
            if let image = ancestor as? UIImageView {
                let guide = image.focusedFrameGuide
                lines.append("Focused guide \(guide.layoutFrame), window \(String(describing: guide.owningView?.convert(guide.layoutFrame, to: window)))")
            }
            current = ancestor.superview
        }
        return lines.joined(separator: "\n")
    }

    private func redArtworkBounds(in window: UIWindow) throws -> CGRect {
        let image = try XCTUnwrap(DetailTransitionSnapshot.image(of: window).cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if bytes[index] > 150,
                   Int(bytes[index]) > Int(bytes[index + 1]) + 60,
                   Int(bytes[index]) > Int(bytes[index + 2]) + 60 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor
    private final class FocusReturnFixture {
        let window: UIWindow
        let previous: UIWindow?
        let source = DetailTransitionSourceReference()
        let item = MediaItem(id: "focused-return", title: "Focused return", kind: .movie)
        let controller = FocusReturnController()

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = controller
            controller.card.reference = source
            source.view = controller.card
            source.itemKey = item.stablePresentationID
            source.cornerRadius = 22
            source.focusRequester = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
        }

        func close() {
            DetailTransitionNavigation.take(in: window)?.discard()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor
    private final class FocusReturnController: UIViewController, DetailTransitionFocusRequesting {
        let card = FocusScaledArtworkButton(type: .custom)
        let other = UIButton(type: .system)
        var prefersCard = true

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [prefersCard ? card : other]
        }

        func requestFocus() -> Bool {
            prefersCard = true
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return true
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            card.frame = CGRect(x: 160, y: 280, width: 240, height: 360)
            card.backgroundColor = .red
            card.layer.cornerRadius = 22
            card.layer.cornerCurve = .continuous
            card.clipsToBounds = true
            card.setTitle("Card", for: .normal)
            other.frame = CGRect(x: 600, y: 280, width: 200, height: 80)
            other.setTitle("Other", for: .normal)
            view.addSubview(card)
            view.addSubview(other)
        }
    }

    @MainActor
    private final class FocusScaledArtworkButton: UIButton {
        weak var reference: DetailTransitionSourceReference?

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            reference?.isFocused = isFocused
            coordinator.addCoordinatedAnimations({
                self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            }, completion: nil)
        }
    }

    private func activeScene() async throws -> UIWindowScene {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView,
           scroll.bounds.height > 700, scroll.contentSize.height > scroll.bounds.height {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.verticalScroll(in: $0) }.first
    }

    private func seedArtwork(
        color: UIColor = .blue, size: CGSize = CGSize(width: 320, height: 180)
    ) async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://transition-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image {
            color.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let request = URLRequest(url: requestURL)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: request)
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
        }
        return url
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Production series fixture did not settle", file: file, line: line)
    }
}

@MainActor
private final class NativeFocusGridHost: UIViewController {
    let cards = (0..<4).map { UIHostingController(rootView: NativeFocusTestCard(index: $0)) }
    var preferredIndex = 0

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [cards[preferredIndex]] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for (index, card) in cards.enumerated() {
            addChild(card)
            view.addSubview(card.view)
            card.view.backgroundColor = .clear
            card.view.frame = CGRect(x: 250 + (index % 2) * 620, y: 80 + (index / 2) * 440, width: 540, height: 380)
            card.didMove(toParent: self)
        }
    }
}

private struct IndependentFocusSurface: View {
    let onFocus: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .frame(width: 400, height: 220)
            .focusableCard(isFocused: $focused, cornerRadius: 10, action: {})
            .onChange(of: focused) { _, value in onFocus(value) }
            .accessibilityLabel("Independent picture control")
    }
}

private struct NativeFocusTestCard: View {
    let index: Int
    @PlozzCardFocus private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Color(uiColor: .red)
                .frame(width: 440, height: 248)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .plozzFocusHalo(cornerRadius: 28, focusScale: 1.1, isFocused: focused)
            Text(verbatim: "Native card \(index)")
                .foregroundStyle(.white)
        }
        .focusableCard(isFocused: $focused, cornerRadius: 28, action: {})
        .plozzCardFocusTransition(isFocused: focused)
        .environment(\.plozzCardFocusStyle, .system)
    }
}

@MainActor @Observable
private final class RealPosterReturnModel {
    let item: MediaItem
    var path: [Int] = []
    @ObservationIgnored var session: TVDetailEntranceSession?

    init(artwork: URL) {
        item = MediaItem(id: "real-return", title: "Real return", kind: .movie, posterURL: artwork)
    }
}

private struct RealPosterReturnRoot: View {
    @Bindable var model: RealPosterReturnModel
    let style: CardStyle
    let focusStyle: CardFocusStyle
    var shape = PosterCardView.Style.poster

    var body: some View {
        NavigationStack(path: $model.path) {
            PosterCardView(item: model.item, style: shape, enablesAsyncArtworkFallback: false) { model.path.append(1) }
                .frame(width: shape == .poster ? 240 : 520)
                .environment(\.plozzCardStyle, style)
                .environment(\.plozzCardFocusStyle, focusStyle)
                .environment(\.plozzReduceTransparency, true)
                .navigationDestination(for: Int.self) { _ in
                    RealPosterReturnPage(model: model)
                        .cinematicDetailPage(isEnabled: true)
                }
        }
    }
}

private struct RealPosterReturnPage: View {
    let model: RealPosterReturnModel
    @Environment(\.detailEntranceSession) private var session

    var body: some View {
        Button("Play") {}
            .detailEntranceStage(.controls)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.blue)
            .onAppear { model.session = session }
    }
}

@MainActor @Observable
private final class TransitionShowModel {
    let provider: TransitionShowProvider
    let detail: ItemDetailViewModel
    let trailer = HeroTrailerController()
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))
    var path: [Int] = []

    init(provider: TransitionShowProvider) {
        self.provider = provider
        detail = ItemDetailViewModel(
            provider: provider, itemID: provider.show.id,
            initialItem: provider.show,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(enrichment: MetadataEnrichment(),
                                      availability: ExternalTitleAvailability(regionCode: region))
            },
            sourceAccountID: "transition-fixture",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
    }
}

private struct TransitionShowRoot: View {
    @Bindable var model: TransitionShowModel

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack(path: $model.path) {
                    Button("Open show") { model.path.append(1) }
                        .navigationDestination(for: Int.self) { _ in
                            ItemDetailView(viewModel: model.detail, onPlay: { _ in }, onSelectChild: { _ in })
                                .environment(model.trailer)
                                .environment(model.background)
                        }
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
    }
}

private struct TransitionShowProvider: MediaProvider {
    let artwork: URL
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(server: MediaServer(id: "transition-fixture", name: "Fixture",
                                       baseURL: artwork, provider: .jellyfin),
                    userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "")
    }
    var show: MediaItem {
        var item = MediaItem(id: "show", title: "Transition Show", kind: .series)
        item.sourceAccountID = "transition-fixture"
        item.posterURL = artwork
        item.backdropURL = artwork
        item.logoURL = artwork
        item.overview = "A production series detail fixture with a real episode browser."
        return item
    }
    var season: MediaItem {
        var item = MediaItem(id: "season", title: "Season 1", kind: .season)
        item.seriesID = "show"
        item.sourceAccountID = "transition-fixture"
        item.seasonNumber = 1
        return item
    }
    var episode: MediaItem {
        var item = MediaItem(id: "episode", title: "Episode 1", kind: .episode)
        item.sourceAccountID = "transition-fixture"
        item.seriesID = "show"
        item.seasonID = "season"
        item.seasonNumber = 1
        item.episodeNumber = 1
        item.posterURL = artwork
        item.runtime = 1800
        return item
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await Task.sleep(for: .milliseconds(700))
        return []
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { id == "show" ? show : episode }
    func children(of itemID: String) async throws -> [MediaItem] {
        try await Task.sleep(for: .milliseconds(100))
        return itemID == "show" ? [season] : [episode]
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { artwork }
}
