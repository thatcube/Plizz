#if os(tvOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeVerticalMotionHostedTests: XCTestCase {
    func testSharedOffsetMatchesOriginalMotionAndReversal() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = MotionState()
        let shared = MotionState()
        let references = MotionReferences()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            HStack(alignment: .top, spacing: 40) {
                OriginalMotionFixture(state: original, references: references)
                SharedMotionFixture(state: shared, references: references)
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
        let second = try XCTUnwrap(references.shared)
        let firstOrigin = visibleY(first, in: window)
        let secondOrigin = visibleY(second, in: window)
        let initialPixels = try pixelPositions(first, second, in: window)
        var maximumDifference: CGFloat = 0
        var maximumGeometryDifference: CGFloat = 0
        var originalAnimated = false
        var sawIntermediate = false
        var samples: [String] = []

        withAnimation(.smooth(duration: 0.9)) {
            original.y = -170
            shared.y = -170
        }
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
            samples.append("down original=\(a) shared=\(b)")
        }
        XCTAssertTrue(originalAnimated, "The original control must visibly animate for this comparison to be valid.")
        XCTAssertTrue(sawIntermediate, "Down must animate rather than snap.")

        withAnimation(.smooth(duration: 0.9)) {
            original.y = 0
            shared.y = 0
        }
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
            samples.append("up original=\(a) shared=\(b)")
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(visibleY(first, in: window), firstOrigin, accuracy: 0.5)
        XCTAssertEqual(visibleY(second, in: window), secondOrigin, accuracy: 0.5)
        XCTAssertEqual(first.bounds.size, second.bounds.size)
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "Original and shared position samples"
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
}

@MainActor @Observable
private final class MotionState {
    var y: CGFloat = 0
}

@MainActor
private final class MotionReferences {
    var original: UIView?
    var shared: UIView?
}

private struct OriginalMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, shared: false)
            .frame(width: 200, height: 120)
            .offset(y: state.y)
    }
}

private struct SharedMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, shared: true)
            .frame(width: 200, height: 120)
            .modifier(HomeVerticalMotion(y: state.y))
    }
}

private struct MotionProbe: UIViewRepresentable {
    let references: MotionReferences
    let shared: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .white
        if shared { references.shared = view } else { references.original = view }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
