#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelControlsAppearanceTests: XCTestCase {
    func testNormalPlayerActionStyleKeepsFocusedLabelsBlackOnWhite() throws {
        for title in ["Pause", "Add to Favorites", "Remove from Favorites", "Try Again", "Close"] {
            let image = try render(title: title, focused: true)
            let pixels = try rgbaPixels(image)
            let ink = interiorPixelCount(pixels, image: image) { $0 < 12 && $1 < 12 && $2 < 12 }
            let backing = interiorPixelCount(pixels, image: image) { $0 > 243 && $1 > 243 && $2 > 243 }
            XCTAssertGreaterThan(ink, 30, title)
            XCTAssertGreaterThan(backing, 600, title)
        }
    }

    func testNormalPlayerActionStyleKeepsRestingLabelsWhiteOnDarkVideoScrim() throws {
        let image = try render(title: "Pause", focused: false)
        let pixels = try rgbaPixels(image)
        let ink = interiorPixelCount(pixels, image: image) { $0 > 243 && $1 > 243 && $2 > 243 }
        let backing = interiorPixelCount(pixels, image: image) { $0 < 45 && $1 < 45 && $2 < 45 }
        XCTAssertGreaterThan(ink, 30)
        XCTAssertGreaterThan(backing, 600)
    }

    func testNativeFocusStyleKeepsTheExistingRestingAppearance() throws {
        let native = try render(title: "Audio & Subtitles", focused: nil)
        let explicit = try render(title: "Audio & Subtitles", focused: false)
        XCTAssertEqual(native.width, explicit.width)
        XCTAssertEqual(native.height, explicit.height)
        XCTAssertEqual(try rgbaPixels(native), try rgbaPixels(explicit))
    }

    private func render(title: String, focused: Bool?) throws -> CGImage {
        let button = Button {} label: {
            Text(title).font(.system(size: 26, weight: .semibold))
        }
        .buttonStyle(InfoActionButtonStyle(focused: focused, prominent: false))
        .foregroundStyle(.white)
        .background(.black)
        let renderer = ImageRenderer(content: button)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func interiorPixelCount(
        _ pixels: [UInt8], image: CGImage,
        matching: (UInt8, UInt8, UInt8) -> Bool
    ) -> Int {
        var count = 0
        for y in 16..<(image.height - 16) {
            for x in 22..<(image.width - 22) {
                let offset = (y * image.width + x) * 4
                if matching(pixels[offset], pixels[offset + 1], pixels[offset + 2]) { count += 1 }
            }
        }
        return count
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
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
