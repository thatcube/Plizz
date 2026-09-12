#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeVerticalMotionHostedTests: XCTestCase {
    func testIsolatedAlphaDissolveRetainsItsAnimation() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = MotionState()
        let isolated = MotionState()
        let references = MotionReferences()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            HStack(alignment: .top, spacing: 40) {
                OriginalFadeFixture(state: original, references: references)
                IsolatedFadeFixture(state: isolated, references: references)
            }
            .padding(.top, 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let firstView = try XCTUnwrap(references.original)
        let secondView = try XCTUnwrap(references.isolated)
        let firstFrame = firstView.convert(firstView.bounds, to: window)
        let secondFrame = secondView.convert(secondView.bounds, to: window)
        let before = try pixels(window)
        let firstIndex = Int(firstFrame.minY + firstFrame.height * 0.76) * before.image.bytesPerRow
            + Int(firstFrame.midX) * 4
        let secondIndex = Int(secondFrame.minY + secondFrame.height * 0.76) * before.image.bytesPerRow
            + Int(secondFrame.midX) * 4
        let initial = Int(before.bytes[firstIndex])
        XCTAssertLessThanOrEqual(abs(initial - Int(before.bytes[secondIndex])), 2)
        var maximumDifference = 0
        var sawChange = false
        withAnimation(.smooth(duration: 0.96)) { original.fadeStart = 0.42 }
        isolated.fadeStart = 0.42
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
            let frame = try pixels(window).bytes
            maximumDifference = max(maximumDifference, abs(Int(frame[firstIndex]) - Int(frame[secondIndex])))
            sawChange = sawChange || Int(frame[secondIndex]) < initial - 2
        }
        XCTAssertTrue(sawChange)
        withAnimation(.smooth(duration: 0.96)) { original.fadeStart = 0.62 }
        isolated.fadeStart = 0.62
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(25))
            let frame = try pixels(window).bytes
            maximumDifference = max(maximumDifference, abs(Int(frame[firstIndex]) - Int(frame[secondIndex])))
        }
        XCTAssertLessThanOrEqual(maximumDifference, 2, "The alpha fade must keep the original curve through reversal.")
    }

    func testIsolatedOffsetMatchesOriginalMotionAndReversal() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = MotionState()
        let isolated = MotionState()
        let references = MotionReferences()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            HStack(alignment: .top, spacing: 40) {
                OriginalMotionFixture(state: original, references: references)
                IsolatedMotionFixture(state: isolated, references: references)
            }
            .padding(.top, 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(references.original)
        let second = try XCTUnwrap(references.isolated)
        let firstOrigin = visibleY(first, in: window)
        let secondOrigin = visibleY(second, in: window)
        let initialPixels = try pixelPositions(first, second, in: window)
        var maximumDifference: CGFloat = 0
        var maximumGeometryDifference: CGFloat = 0
        var originalAnimated = false
        var sawIntermediate = false
        var samples: [String] = []

        withAnimation(.smooth(duration: 0.9)) { original.y = -170 }
        isolated.y = -170
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(25))
            let positions = try pixelPositions(first, second, in: window)
            let a = positions.0 - initialPixels.0
            let b = positions.1 - initialPixels.1
            maximumDifference = max(maximumDifference, abs(a - b))
            maximumGeometryDifference = max(maximumGeometryDifference, abs(
                (visibleY(first, in: window) - firstOrigin) - (visibleY(second, in: window) - secondOrigin)
            ))
            if a < -1 && a > -169 { originalAnimated = true }
            if b < -1 && b > -169 { sawIntermediate = true }
            samples.append("down original=\(a) isolated=\(b)")
        }
        XCTAssertTrue(originalAnimated, "The original control must visibly animate for this comparison to be valid.")
        XCTAssertTrue(sawIntermediate, "Down must animate rather than snap.")

        withAnimation(.smooth(duration: 0.9)) { original.y = 0 }
        isolated.y = 0
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertLessThan(try pixelPositions(first, second, in: window).1 - initialPixels.1, -1,
                          "Up must not snap to rest.")
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(25))
            let positions = try pixelPositions(first, second, in: window)
            let a = positions.0 - initialPixels.0
            let b = positions.1 - initialPixels.1
            maximumDifference = max(maximumDifference, abs(a - b))
            maximumGeometryDifference = max(maximumGeometryDifference, abs(
                (visibleY(first, in: window) - firstOrigin) - (visibleY(second, in: window) - secondOrigin)
            ))
            samples.append("up original=\(a) isolated=\(b)")
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(visibleY(first, in: window), firstOrigin, accuracy: 0.5)
        XCTAssertEqual(visibleY(second, in: window), secondOrigin, accuracy: 0.5)
        XCTAssertEqual(first.bounds.size, second.bounds.size)
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "Original and isolated position samples"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(maximumDifference, 1, "The original curve and reversal must be retained.")
        XCTAssertLessThanOrEqual(maximumGeometryDifference, 1, "Reported UIKit geometry must match the original.")
    }

    private func visibleY(_ view: UIView, in window: UIWindow) -> CGFloat {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
    }

    private func pixelPositions(_ first: UIView, _ second: UIView, in window: UIWindow) throws -> (CGFloat, CGFloat) {
        let (cg, bytes) = try pixels(window)
        func top(of view: UIView) throws -> CGFloat {
            let x = Int(view.convert(view.bounds, to: window).midX)
            let y = try XCTUnwrap((0..<cg.height).first {
                let offset = $0 * cg.bytesPerRow + x * 4
                return bytes[offset] > 245 && bytes[offset + 1] > 245 && bytes[offset + 2] > 245
            })
            return CGFloat(y)
        }
        return (try top(of: first), try top(of: second))
    }

    private func pixels(_ window: UIWindow) throws -> (image: CGImage, bytes: [UInt8]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let bytes = Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
        return (cg, bytes)
    }
}

@MainActor @Observable
private final class MotionState {
    var y: CGFloat = 0
    var fadeStart: CGFloat = 0.62
}

@MainActor
private final class MotionReferences {
    var original: UIView?
    var isolated: UIView?
}

private struct OriginalMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, isolated: false)
            .frame(width: 200, height: 120)
            .offset(y: state.y)
    }
}

private struct IsolatedMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, isolated: true)
            .frame(width: 200, height: 120)
            .modifier(HomeVerticalMotion(y: state.y, duration: 0.9, isolated: true))
    }
}

private struct MotionProbe: UIViewRepresentable {
    let references: MotionReferences
    let isolated: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .white
        if isolated { references.isolated = view } else { references.original = view }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

private struct OriginalFadeFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, isolated: false)
            .frame(width: 200, height: 120)
            .mask(motionTestMask(start: state.fadeStart))
    }
}

private struct IsolatedFadeFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, isolated: true)
            .frame(width: 200, height: 120)
            .transaction { $0.animation = nil }
            .mask(motionTestMask(start: state.fadeStart))
            .animation(.smooth(duration: 0.96), value: state.fadeStart)
            .modifier(HomeVerticalMotion(y: 0, duration: 0.96, isolated: true))
    }
}

private func motionTestMask(start: CGFloat) -> LinearGradient {
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
#endif
