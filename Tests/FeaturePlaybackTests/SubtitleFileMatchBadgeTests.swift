#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitleFileMatchBadgeTests: XCTestCase {
    func testOnlyConfirmedMatchesDrawABadgeInLightDarkAndFocusedRows() throws {
        for scheme in [ColorScheme.light, .dark] {
            for focused in [false, true] {
                let background: Color = focused || scheme == .light ? .white : .black
                let empty = try render(
                    Color.clear, background: background, scheme: scheme, focused: focused
                )
                let unconfirmed = try render(
                    SubtitleFileMatchBadge(isHashMatch: false),
                    background: background, scheme: scheme, focused: focused
                )
                let confirmed = try render(
                    SubtitleFileMatchBadge(isHashMatch: true),
                    background: background, scheme: scheme, focused: focused
                )

                XCTAssertEqual(unconfirmed, empty)
                let visiblePixels = stride(from: 0, to: confirmed.count, by: 4).filter { index in
                    abs(Int(confirmed[index]) - Int(empty[index])) > 20
                }.count
                XCTAssertGreaterThan(visiblePixels, 150, "\(scheme), focused=\(focused)")
            }
        }
    }

    func testSharedBadgeStylingPreservesTheExistingExternalBadge() throws {
        for focused in [false, true] {
            let background: Color = focused ? .white : .black
            let fill = focused ? Color.black.opacity(0.62) : Color.white.opacity(0.6)
            let reference = Text("EXTERNAL")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.4)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .blendMode(.destinationOut)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
                .compositingGroup()
            XCTAssertEqual(
                try render(ExternalSubtitleBadge(), background: background, scheme: .dark, focused: focused),
                try render(reference, background: background, scheme: .dark, focused: focused)
            )
        }
    }

    private func render<Content: View>(
        _ content: Content, background: Color, scheme: ColorScheme, focused: Bool
    ) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content
            .frame(width: 220, height: 40)
            .background(background)
            .environment(\.colorScheme, scheme)
            .environment(\.playerMenuRowIsFocused, focused)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 220)
        XCTAssertEqual(image.height, 40)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
#endif
