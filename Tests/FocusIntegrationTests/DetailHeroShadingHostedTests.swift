#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailHeroShadingHostedTests: XCTestCase {
    func testCachedDetailLayerPreservesShadingDissolveAndVideoClipping() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let state = DetailShadingFixtureState()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: DetailShadingFixture(state: state))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for (name, tone, background) in [
            ("dark", Color.black, Color.black),
            ("light", Color.white, Color.white),
            ("custom", Color.purple, Color.black)
        ] {
            state.tone = tone
            state.background = background
            for rightToLeft in [false, true] {
                state.rightToLeft = rightToLeft
                for size in [CGSize(width: 640, height: 360), CGSize(width: 1280, height: 576),
                             CGSize(width: 1920, height: 1080)] {
                    state.size = size
                    for offset in [CGFloat(0), -90] {
                        state.offset = offset
                        state.cached = false
                        try await Task.sleep(for: .milliseconds(100))
                        let original = try pixels(window)
                        state.cached = true
                        try await Task.sleep(for: .milliseconds(100))
                        let cached = try pixels(window)
                        var maximum = 0
                        var compared = 0
                        for yFraction in [0.01, 0.2, 0.33, 0.34, 0.45, 0.538, 0.58, 0.62, 0.72, 0.85, 0.95, 0.99] {
                            let y = Int(size.height * yFraction + offset)
                            guard y >= 0, y < 1080 else { continue }
                            for xFraction in [0.01, 0.1, 0.2, 0.3, 0.41, 0.5, 0.7, 0.9, 0.99] {
                                let index = y * 1920 * 4 + Int(size.width * xFraction) * 4
                                for channel in 0..<4 {
                                    maximum = max(maximum, abs(Int(original[index + channel]) - Int(cached[index + channel])))
                                }
                                compared += 1
                            }
                        }
                        let edge = Int(size.height + offset)
                        if edge >= 0, edge + 1 < 1080 {
                            let index = (edge + 1) * 1920 * 4 + Int(size.width / 2) * 4
                            let expected = name == "light" ? 255 : 0
                            XCTAssertEqual(Int(cached[index]), expected, "Video overdraw must remain clipped.")
                        }
                        XCTAssertGreaterThan(compared, 30)
                        let attachment = XCTAttachment(string:
                            "detail max=\(maximum), theme=\(name), rtl=\(rightToLeft), size=\(size), offset=\(offset)")
                        attachment.name = "Detail shading pixel comparison"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        XCTAssertLessThanOrEqual(maximum, 2)
                    }
                }
            }
        }
    }

    private func pixels(_ window: UIWindow) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        XCTAssertEqual(cg.bytesPerRow, 1920 * 4)
        return Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
    }
}

@MainActor @Observable
private final class DetailShadingFixtureState {
    var cached = false
    var tone = Color.black
    var background = Color.black
    var rightToLeft = false
    var size = CGSize(width: 640, height: 360)
    var offset: CGFloat = 0
}

private struct DetailShadingFixture: View {
    let state: DetailShadingFixtureState

    var body: some View {
        HeroBackdropLayer(
            references: [], height: state.size.height, scrimTone: state.tone,
            verticalOffset: state.offset, dissolveStart: 0.33, ignoresOverscan: false,
            stillImageOpacity: 0, prefersCachedScrim: state.cached
        ) {
            DetailVideoFixture()
                .frame(width: state.size.width, height: state.size.height)
        }
        .frame(width: state.size.width, height: state.size.height)
        .environment(\.layoutDirection, state.rightToLeft ? .rightToLeft : .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(state.background)
        .ignoresSafeArea()
    }
}

private struct DetailVideoFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> PictureView { PictureView() }
    func updateUIView(_ view: PictureView, context: Context) {}

    final class PictureView: UIView {
        private let picture = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.colors = [UIColor.red.cgColor, UIColor.green.cgColor, UIColor.blue.cgColor]
            picture.startPoint = CGPoint(x: 0, y: 0)
            picture.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(picture)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 1)
            CATransaction.commit()
        }
    }
}
#endif
