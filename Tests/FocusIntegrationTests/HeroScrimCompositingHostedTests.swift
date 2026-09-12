#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroScrimCompositingHostedTests: XCTestCase {
    func testCachedScrimMatchesOriginalAcrossSizesThemesAndDirections() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = ScrimFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: ScrimFixtureView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for light in [false, true] {
            model.light = light
            for rightToLeft in [false, true] {
                model.rightToLeft = rightToLeft
                for size in [CGSize(width: 640, height: 360), CGSize(width: 1280, height: 720)] {
                    model.size = size
                    model.cached = false
                    try await Task.sleep(for: .milliseconds(200))
                    let original = try pixels(window)
                    let originalLayers = layerCounts(window.layer)
                    model.cached = true
                    try await Task.sleep(for: .milliseconds(200))
                    let candidate = try pixels(window)
                    let candidateLayers = layerCounts(window.layer)
                    var maximum = 0
                    for yFraction in [0.01, 0.2, 0.34, 0.4, 0.538, 0.58, 0.62, 0.72, 0.81, 0.9, 0.96, 0.99] {
                        for xFraction in [0.01, 0.1, 0.2, 0.3, 0.41, 0.5, 0.7, 0.9, 0.99] {
                            let x = 80 + Int(size.width * xFraction)
                            let y = 80 + Int(size.height * yFraction)
                            let index = (y * 1920 + x) * 4
                            for channel in 0..<4 {
                                maximum = max(maximum, abs(Int(original[index + channel]) - Int(candidate[index + channel])))
                            }
                        }
                    }
                    let result = XCTAttachment(string: "cached scrim max=\(maximum), size=\(size), light=\(light), rtl=\(rightToLeft), originalLayers=\(originalLayers), cachedLayers=\(candidateLayers)")
                    result.name = "Cached scrim pixel comparison"
                    result.lifetime = .keepAlways
                    add(result)
                    XCTAssertLessThanOrEqual(maximum, 2)
                }
            }
        }
    }

    private func pixels(_ window: UIWindow) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        XCTAssertEqual(cgImage.bytesPerRow, 1920 * 4)
        return Array(try XCTUnwrap(cgImage.dataProvider?.data) as Data)
    }

    private func layerCounts(_ layer: CALayer) -> [String: Int] {
        var result = ["layers": 1, "masks": layer.mask == nil ? 0 : 1,
                      "gradients": layer is CAGradientLayer ? 1 : 0]
        for child in (layer.sublayers ?? []) + (layer.mask.map { [$0] } ?? []) {
            for (key, value) in layerCounts(child) { result[key, default: 0] += value }
        }
        return result
    }
}

@MainActor @Observable
private final class ScrimFixture {
    var cached = false
    var light = false
    var rightToLeft = false
    var size = CGSize(width: 640, height: 360)
}

private struct ScrimFixtureView: View {
    let model: ScrimFixture

    var body: some View {
        LinearGradient(colors: [.red, .green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Group {
                    if model.cached {
                        HeroLegibilityTexture(tone: model.light ? .white : .black)
                    } else {
                        shading
                    }
                }
                .environment(\.layoutDirection, model.rightToLeft ? .rightToLeft : .leftToRight)
            }
            .frame(width: model.size.width, height: model.size.height)
            .padding(.leading, 80)
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }

    private var shading: some View {
        HeroLegibilityScrim(
            tone: model.light ? .white : .black,
            edgePeak: 0.55,
            edges: [.leading, .bottom],
            sideDarkeningStart: 0.34
        )
    }
}
#endif
