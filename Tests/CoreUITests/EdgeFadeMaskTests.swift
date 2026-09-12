#if canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import SwiftUI
import XCTest

@MainActor
final class EdgeFadeMaskTests: XCTestCase {
    func testDefaultHorizontalMaskStillFadesBothEdges() throws {
        let pixels = try render(leading: 1, trailing: 1)
        XCTAssertLessThan(alpha(pixels, at: 1), 16)
        XCTAssertLessThan(alpha(pixels, at: 198), 16)
        XCTAssertGreaterThan(alpha(pixels, at: 100), 250)
    }

    func testReachedLeadingEdgeStaysOpaque() throws {
        let pixels = try render(leading: 0, trailing: 1)
        XCTAssertGreaterThan(alpha(pixels, at: 1), 250)
        XCTAssertLessThan(alpha(pixels, at: 198), 16)
    }

    func testReachedTrailingEdgeStaysOpaque() throws {
        let pixels = try render(leading: 1, trailing: 0)
        XCTAssertLessThan(alpha(pixels, at: 1), 16)
        XCTAssertGreaterThan(alpha(pixels, at: 198), 250)
    }

    func testFadeStrengthChangesContinuously() throws {
        let pixels = try render(leading: 0.5, trailing: 0.5)
        XCTAssertTrue((120 ... 145).contains(alpha(pixels, at: 1)))
        XCTAssertTrue((120 ... 145).contains(alpha(pixels, at: 198)))
        XCTAssertGreaterThan(alpha(pixels, at: 100), 250)
    }

    func testStrengthsAreClamped() throws {
        let pixels = try render(leading: -2, trailing: 4)
        XCTAssertGreaterThan(alpha(pixels, at: 1), 250)
        XCTAssertLessThan(alpha(pixels, at: 198), 16)
    }

    func testSemanticLeadingEdgeFollowsRightToLeftLayout() throws {
        let pixels = try render(leading: 0, trailing: 1, direction: .rightToLeft)
        XCTAssertGreaterThan(alpha(pixels, at: 198), 250)
        XCTAssertLessThan(alpha(pixels, at: 1), 16)
    }

    private func render(
        leading: CGFloat, trailing: CGFloat, direction: LayoutDirection = .leftToRight
    ) throws -> [UInt8] {
        let renderer = ImageRenderer(content:
            HorizontalEdgeFadeMask(fadeWidth: 24, leadingStrength: leading, trailingStrength: trailing)
                .frame(width: 200, height: 20)
                .environment(\.layoutDirection, direction)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 20)
        var pixels = [UInt8](repeating: 0, count: 200 * 20 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 200, height: 20,
                bitsPerComponent: 8, bytesPerRow: 200 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 20))
        }
        return pixels
    }

    private func alpha(_ pixels: [UInt8], at x: Int) -> Int {
        Int(pixels[(10 * 200 + x) * 4 + 3])
    }
}
#endif
