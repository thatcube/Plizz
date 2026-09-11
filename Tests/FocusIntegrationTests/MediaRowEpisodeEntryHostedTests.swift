import CoreModels
import SwiftUI
import XCTest
import CoreUI
#if os(tvOS)
import Observation
import UIKit
#endif

#if os(tvOS)
@MainActor
final class MediaRowEpisodeEntryHostedTests: XCTestCase {
    func testFocusedLoadingCardKeepsItsLeadingOverflow() async throws {
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for style in [CardFocusStyle.highlight, .outlined] {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { host.row.view.window != nil && model.appeared && host.heroIsFocused }
            let before = screenshot(window)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { model.events.contains("placeholder") }
            // Wait for rendered overflow, not merely a FocusState callback.
            let rowFrame = host.row.view.convert(host.row.view.bounds, to: window)
            let x = Int(rowFrame.minX + host.row.view.safeAreaInsets.left + PlozzTheme.Metrics.screenPadding - 4)
            let y = Int(rowFrame.minY + EpisodeColumnCard.artworkSize.height / 2)
            XCTAssertGreaterThanOrEqual(x, 0)
            let unfocusedPixel = try pixel(before, x: x, y: y)
            var overflowVisible = false
            let deadline = ContinuousClock.now + .seconds(3)
            while !overflowVisible, ContinuousClock.now < deadline {
                let focusedPixel = try pixel(screenshot(window), x: x, y: y)
                overflowVisible = zip(focusedPixel.prefix(3), unfocusedPixel.prefix(3))
                    .contains { abs(Int($0.0) - Int($0.1)) > 3 }
                if !overflowVisible { try await Task.sleep(for: .milliseconds(30)) }
            }
            XCTAssertTrue(overflowVisible, "Focused \(style) thumbnail was clipped at the row's leading edge")
            capture(window, system: system, name: "episode-placeholder-overflow-\(style)")
        }
    }

    func testFocusedLoadingSlotHandsOffToTheFarEpisodeAfterDataArrives() async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let original = settingsStore.load()
        var local = original
        local.preferOnlineArtwork = false
        settingsStore.save(local)
        defer { settingsStore.save(original) }
        let imageURL = try await seedImage()
        let model = EpisodeEntryFixture()
        let host = EpisodeEntryHost(model: model)
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await waitUntil { host.row.view.window != nil && model.appeared }
        window.layoutIfNeeded()
        await Task.yield()
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        host.prefersRow = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { model.events.contains("placeholder") }
        capture(window, system: system, name: "episode-entry-loading")
        let loadingFocus = try XCTUnwrap(system.focusedItem)
        XCTAssertFalse(model.events.contains("episode-0"))
        model.items = (0..<1000).map { (number: Int) in
            MediaItem(
                id: "episode-\(number)", title: "Episode \(number)", kind: .episode,
                seasonNumber: 20, episodeNumber: number, posterURL: imageURL
            )
        }
        model.phase = .ready
        host.view.layoutIfNeeded()
        await waitUntil { model.events.contains("episode-998") }
        await waitUntil {
            system.focusedItem.map { ObjectIdentifier($0) != ObjectIdentifier(loadingFocus) } == true
        }
        capture(window, system: system, name: "episode-entry-loaded")
        XCTAssertEqual(model.events.filter { $0.hasPrefix("episode-") }, ["episode-998"])

        // Browse a different real card, return to the hero, and change the server's
        // resume target. Re-entry must preserve the viewer's browse position.
        await waitUntil { self.leftNeighbor(of: system.focusedItem, in: host.row.view) != nil }
        let browsed = try XCTUnwrap(leftNeighbor(of: system.focusedItem, in: host.row.view))
        let beforeBrowsing = model.events.count
        host.preferredItem = browsed
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil {
            model.events.count > beforeBrowsing
                && model.events.last?.hasPrefix("episode-") == true
                && model.events.last != "episode-998"
        }
        let browsedID = try XCTUnwrap(model.events.last)
        XCTAssertNotEqual(browsedID, "episode-900")
        host.preferredItem = nil
        host.prefersRow = false
        model.active = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { host.heroIsFocused }
        model.resumeTarget = "episode-900"
        host.view.layoutIfNeeded()
        let reports = model.events.count
        host.prefersRow = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { model.events.count > reports && model.events.last == browsedID }
        capture(window, system: system, name: "episode-entry-remembered")
    }

    private func leftNeighbor(of focused: (any UIFocusItem)?, in root: UIView) -> (any UIFocusItem)? {
        guard let focused, let current = frame(focused, in: root) else { return nil }
        var seen = Set<ObjectIdentifier>()
        func items(_ view: UIView) -> [any UIFocusItem] {
            let own = view.focusItemContainer?.focusItems(in: view.bounds) ?? []
            return own + view.subviews.flatMap(items)
        }
        return items(root).compactMap { item -> ((any UIFocusItem), CGRect)? in
            guard seen.insert(ObjectIdentifier(item)).inserted,
                  item.canBecomeFocused, let rect = frame(item, in: root),
                  rect.width > 300, rect.width < 800,
                  rect.midX < current.midX - 20 else { return nil }
            return (item, rect)
        }.max { $0.1.midX < $1.1.midX }?.0
    }

    private func frame(_ item: any UIFocusItem, in root: UIView) -> CGRect? {
        if let view = item as? UIView { return view.convert(view.bounds, to: root) }
        var parent = item.parentFocusEnvironment
        while let environment = parent {
            if let container = environment.focusItemContainer {
                let space: any UICoordinateSpace = root
                return space.convert(item.frame, from: container.coordinateSpace)
            }
            parent = environment.parentFocusEnvironment
        }
        return nil
    }

    private func capture(_ window: UIWindow, system: UIFocusSystem, name: String) {
        let image = screenshot(window)
        let picture = XCTAttachment(image: image)
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        func describe(_ view: UIView, depth: Int = 0) -> String {
            guard depth < 12 else { return "" }
            let line = "\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(view.frame) alpha=\(view.alpha) hidden=\(view.isHidden) focusable=\(view.canBecomeFocused)\n"
            return line + view.subviews.map { describe($0, depth: depth + 1) }.joined()
        }
        let tree = XCTAttachment(string: "Focused: \(String(describing: system.focusedItem))\n" + describe(window))
        tree.name = "\(name)-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func screenshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Native hosted episode entry did not reach the expected destination")
    }

    private func seedImage() async throws -> URL {
        let url = URL(string: "https://episode-entry.example.test/\(UUID()).png")!
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let data = try XCTUnwrap(image.pngData())
        let requestURL = ArtworkImageVariant.landscapeCard.requestURL(for: url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data),
                                  for: URLRequest(url: requestURL))
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .landscapeCard)
        _ = try XCTUnwrap(decoded)
        cache.removeCachedResponse(for: URLRequest(url: requestURL))
        return url
    }
}

@MainActor
@Observable
private final class EpisodeEntryFixture {
    var items: [MediaItem] = []
    var phase = MediaRowEpisodeEntry.Phase.loading
    var active = true
    var resumeTarget = "episode-998"
    var focusStyle = CardFocusStyle.highlight
    @ObservationIgnored var appeared = false
    @ObservationIgnored var events: [String] = []
}

private struct EpisodeEntryFixtureView: View {
    let model: EpisodeEntryFixture
    var body: some View {
        MediaRowView(
            title: nil, items: model.items, presentation: .episodeColumn,
            initialScrollID: model.resumeTarget, defaultFocusID: model.resumeTarget,
            onFocusEntered: { model.active = false },
            onFocusChange: { if let item = $0 { model.events.append(item.id) } },
            episodeEntry: MediaRowEpisodeEntry(
                phase: model.phase, isActive: model.active,
                onPlaceholderFocus: {
                    model.events.append("placeholder")
                    model.active = false
                }
            ),
            onSelect: { _ in }
        )
        .frame(height: 520)
        .environment(\.plozzCardFocusStyle, model.focusStyle)
        .onAppear { model.appeared = true }
    }
}

@MainActor
private final class EpisodeEntryHost: UIViewController {
    let row: UIHostingController<EpisodeEntryFixtureView>
    private let hero = UIButton(type: .system)
    var prefersRow = false
    var preferredItem: (any UIFocusEnvironment)?
    var heroIsFocused: Bool { hero.isFocused }

    init(model: EpisodeEntryFixture) {
        row = UIHostingController(rootView: EpisodeEntryFixtureView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if let preferredItem { return [preferredItem] }
        return prefersRow ? [row] : [hero]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hero.setTitle("Play", for: .normal)
        hero.frame = CGRect(x: 100, y: 100, width: 200, height: 60)
        view.addSubview(hero)
        addChild(row)
        row.view.frame = CGRect(x: 0, y: 300, width: 1920, height: 520)
        view.addSubview(row.view)
        row.didMove(toParent: self)
    }
}
#endif
