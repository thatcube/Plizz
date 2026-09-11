#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroScrimCompositingHostedTests: XCTestCase {
    func testRecordOriginalAndCurrentFadeMotionWithTheSameLift() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = PairedFadeMotionFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: PairedFadeMotionView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let originalIndex = (288 * 1920 + 400) * 4
        let currentIndex = (288 * 1920 + 1120) * 4
        let before = try pixels(window)
        XCTAssertEqual(before[originalIndex], before[currentIndex])
        XCTAssertGreaterThan(before[originalIndex], 240)
        let started = ContinuousClock.now
        model.receded = true
        var samples: [FadeMotionSample] = []
        for milliseconds in [80, 120, 160, 240, 400, 600] {
            try await Task.sleep(for: .milliseconds(milliseconds))
            let frame = try pixels(window)
            let elapsed = started.duration(to: .now).components
            samples.append(FadeMotionSample(
                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                original: Int(frame[originalIndex]),
                current: Int(frame[currentIndex])
            ))
        }
        let data = try JSONEncoder().encode(samples)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Original and current fade motion - local simulator only"
        attachment.lifetime = .keepAlways
        add(attachment)
        let last = try XCTUnwrap(samples.last)
        XCTAssertLessThan(last.original, 180)
        XCTAssertEqual(Double(last.original), Double(last.current), accuracy: 2)
        for sample in samples {
            XCTAssertLessThanOrEqual(abs(sample.original - sample.current), 4,
                                     "The new fade must track the original during the lift, not just at rest")
        }
    }

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

    func testOpaqueDissolveAnimatesAndReversesWithoutSnapping() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = DissolveAnimationFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: DissolveAnimationFixtureView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let index = (288 * 1920 + 400) * 4
        let before = Int(try pixels(window)[index])
        model.start = 0.42
        try await Task.sleep(for: .milliseconds(300))
        let moving = Int(try pixels(window)[index])
        XCTAssertLessThan(moving, before - 2, "The fade must have started")

        model.start = 0.62
        try await Task.sleep(for: .milliseconds(40))
        let reversing = Int(try pixels(window)[index])
        XCTAssertLessThan(reversing, before - 2, "Reversal must not snap to the resting fade")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertLessThanOrEqual(abs(Int(try pixels(window)[index]) - before), 2)

        model.start = 0.42
        try await Task.sleep(for: .seconds(1.5))
        let finished = Int(try pixels(window)[index])
        XCTAssertGreaterThan(moving, finished + 2, "An intermediate frame must differ from the final fade")
    }

    func testOpaqueDissolveMatchesOriginalMaskAcrossThemesAndRecedePositions() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = DissolveFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: DissolveFixtureView(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for (themeIndex, palette) in [ThemePalette.dark, .pureBlack, .light].enumerated() {
            model.background = palette.backgroundBase
            model.light = palette.isLight
            for start in [CGFloat(0.18), 0.38, 0.42, 0.62] {
                model.start = start
                model.opaque = false
                try await Task.sleep(for: .milliseconds(150))
                let original = try pixels(window)
                try await Task.sleep(for: .milliseconds(150))
                let repeatedOriginal = try pixels(window)
                model.opaque = true
                try await Task.sleep(for: .milliseconds(150))
                let candidate = try pixels(window)
                let first = (88 * 1920 + 88) * 4
                let last = (432 * 1920 + 712) * 4
                XCTAssertNotEqual(Array(original[first..<first + 4]), Array(original[last..<last + 4]))
                var maximumDifference = 0
                var maximumRepeatDifference = 0
                var totalDifference = 0
                var totalRepeatDifference = 0
                var samples = 0
                for y in stride(from: 88, through: 432, by: 24) {
                    for x in stride(from: 88, through: 712, by: 24) {
                        let index = (y * 1920 + x) * 4
                        for channel in 0..<4 {
                            let difference = abs(Int(original[index + channel]) - Int(candidate[index + channel]))
                            let repeatDifference = abs(Int(original[index + channel]) - Int(repeatedOriginal[index + channel]))
                            maximumDifference = max(maximumDifference, difference)
                            maximumRepeatDifference = max(maximumRepeatDifference, repeatDifference)
                            totalDifference += difference
                            totalRepeatDifference += repeatDifference
                            samples += 1
                        }
                        let metrics = XCTAttachment(string: "theme=\(themeIndex) start=\(start) max=\(maximumDifference) mean=\(Double(totalDifference) / Double(samples)) repeatMax=\(maximumRepeatDifference) repeatMean=\(Double(totalRepeatDifference) / Double(samples))")
                        metrics.name = "Dissolve pixel metrics \(themeIndex)-\(start)"
                        metrics.lifetime = .keepAlways
                        add(metrics)
                        XCTAssertLessThanOrEqual(maximumDifference, 2)
                    }
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

private struct FadeMotionSample: Codable {
    let seconds: Double
    let original: Int
    let current: Int
}

@MainActor @Observable
private final class PairedFadeMotionFixture {
    var receded = false
}

private struct PairedFadeMotionView: View {
    let model: PairedFadeMotionFixture

    var body: some View {
        HStack(spacing: 80) {
            surface(current: false)
            surface(current: true)
        }
        .padding(.leading, 80)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .ignoresSafeArea()
    }

    private func surface(current: Bool) -> some View {
        Group {
            if current {
                Color.white.modifier(HeroBackdropDissolve(
                    start: model.receded ? 0.42 : 0.62, background: .black
                ))
            } else {
                Color.white.mask(referenceMask)
            }
        }
        .frame(width: 640, height: 360)
        .offset(y: model.receded ? -80 : 0)
        .animation(.smooth(duration: 0.96), value: model.receded)
    }

    private var referenceMask: LinearGradient {
        let start: CGFloat = model.receded ? 0.42 : 0.62
        let span = 1 - start
        return LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .white, location: start),
            .init(color: .white.opacity(0.72), location: start + span * 0.32),
            .init(color: .white.opacity(0.36), location: start + span * 0.60),
            .init(color: .white.opacity(0.10), location: start + span * 0.83),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

@MainActor @Observable
private final class DissolveAnimationFixture {
    var start: CGFloat = 0.62
}

private struct DissolveAnimationFixtureView: View {
    let model: DissolveAnimationFixture

    var body: some View {
        Color.white
            .modifier(HeroBackdropDissolve(start: model.start, background: .black))
            .animation(.smooth(duration: 0.96), value: model.start)
            .frame(width: 640, height: 360)
            .background(.black)
            .padding(.leading, 80)
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }
}

@MainActor @Observable
private final class DissolveFixture {
    var background = ThemePalette.dark.backgroundBase
    var light = false
    var start: CGFloat = 0.62
    var opaque = false
}

private struct DissolveFixtureView: View {
    let model: DissolveFixture

    var body: some View {
        surface
            .frame(width: 640, height: 360)
            .background(model.background)
            .padding(.leading, 80)
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var surface: some View {
        if model.opaque {
            artwork.modifier(HeroBackdropDissolve(start: model.start, background: model.background))
        } else {
            artwork.mask(originalMask)
        }
    }

    private var artwork: some View {
        LinearGradient(colors: [.red, .green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                HeroLegibilityScrim(
                    tone: model.light ? .white : .black,
                    edgePeak: 0.55, edges: [.leading, .bottom], sideDarkeningStart: 0.34
                )
            }
    }

    private var originalMask: LinearGradient {
        let start = model.start
        let span = max(1 - start, 0.0001)
        return LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .white, location: start),
            .init(color: .white.opacity(0.72), location: start + span * 0.32),
            .init(color: .white.opacity(0.36), location: start + span * 0.60),
            .init(color: .white.opacity(0.10), location: start + span * 0.83),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
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
                        HomeHeroLegibilityTexture(tone: model.light ? .white : .black)
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
