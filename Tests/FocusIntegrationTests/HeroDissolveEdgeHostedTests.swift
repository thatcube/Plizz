#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroDissolveEdgeHostedTests: XCTestCase {
    func testMovingUIKitArtworkHasNoBrightBottomSeam() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = EdgeFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: EdgeFixtureView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for scale in [CGFloat(1), 2] {
            model.scale = scale
            for lift in [CGFloat(0), 0.125, 0.25, 0.5, 0.75, 110.125, 239.75] {
                model.lift = lift
                try await Task.sleep(for: .milliseconds(100))
                let image = try snapshot(window, scale: scale)
                let bytes = Array(try XCTUnwrap(image.dataProvider?.data) as Data)
                let edge = (80 + model.height - lift) * scale
                var maximum = 0
                for y in Int(floor(edge)) - 1...Int(ceil(edge)) + 1 {
                    for x in [160, 320, 480] {
                        let offset = y * image.bytesPerRow + Int(CGFloat(x) * scale) * 4
                        maximum = max(maximum, max(Int(bytes[offset]), max(Int(bytes[offset + 1]), Int(bytes[offset + 2]))))
                    }
                }
                XCTAssertLessThanOrEqual(maximum, 2, "Bright bottom edge at scale \(scale), lift \(lift)")
            }
        }
    }

    func testFadeRetainsTheMasksClippingOfVideoOverdraw() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = EdgeFixture()
        model.videoOverdraw = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: EdgeFixtureView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for original in [true, false] {
            model.original = original
            for lift in [CGFloat(0), 0.25, 0.5, 239.75] {
                model.lift = lift
                try await Task.sleep(for: .milliseconds(100))
                let image = try snapshot(window, scale: 2)
                let bytes = Array(try XCTUnwrap(image.dataProvider?.data) as Data)
                let edge = (80 + model.height - lift) * 2
                var maximum = 0
                for y in Int(floor(edge))...Int(ceil(edge)) + 2 {
                    let offset = y * image.bytesPerRow + 640 * 4
                    maximum = max(maximum, Int(bytes[offset]))
                }
                XCTAssertLessThanOrEqual(maximum, 2, "Video-like layer escaped the fade at lift \(lift), original=\(original)")
            }
        }
    }

    private func snapshot(_ window: UIWindow, scale: CGFloat) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        return cgImage
    }
}

@MainActor @Observable
private final class EdgeFixture {
    var lift: CGFloat = 0
    var scale: CGFloat = 1
    var videoOverdraw = false
    var original = false
    let height: CGFloat = 360.5
}

private struct EdgeFixtureView: View {
    let model: EdgeFixture

    var body: some View {
        EdgeArtwork()
            .frame(width: 640.25, height: model.height)
            .clipped()
            .overlay {
                if model.videoOverdraw { EdgeVideoOverdraw() }
            }
            .modifier(HeroBackdropDissolve(start: 0.42, background: model.original ? nil : .black))
            .offset(y: -model.lift)
            .environment(\.displayScale, model.scale)
            .padding(.leading, 80)
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
            .ignoresSafeArea()
    }
}

private struct EdgeVideoOverdraw: UIViewRepresentable {
    func makeUIView(context: Context) -> OverdrawingView { OverdrawingView() }
    func updateUIView(_ view: OverdrawingView, context: Context) {}

    final class OverdrawingView: UIView {
        private let picture = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.backgroundColor = UIColor.white.cgColor
            layer.addSublayer(picture)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Synthetic overdraw exercises clipping, not the on-device seam.
            picture.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 1)
        }
    }
}

private struct EdgeArtwork: UIViewRepresentable {
    func makeUIView(context: Context) -> UIImageView {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        return UIImageView(image: image)
    }

    func updateUIView(_ view: UIImageView, context: Context) {}
}
#endif
