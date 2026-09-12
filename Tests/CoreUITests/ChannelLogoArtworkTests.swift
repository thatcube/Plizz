#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class ChannelLogoArtworkTests: XCTestCase {
    func testDarkColouredInkGetsASubtleLightBrandTint() {
        for luminance in [0.08, 0.3, 0.55] {
            let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
                luminance: luminance, coverage: 0.4, red: 0.8, green: 0.15, blue: 0.1
            ))
            XCTAssertGreaterThan(min(plate.red, plate.green, plate.blue), 0.93)
            XCTAssertGreaterThan(plate.red, plate.green)
            XCTAssertLessThan(max(plate.red, plate.green, plate.blue) - min(plate.red, plate.green, plate.blue), 0.04)
            XCTAssertTrue(plate.isLight)
        }
    }

    func testSmallWhiteWordmarkUnderAColouredIconKeepsDarkBacking() {
        let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 0.35, coverage: 0.4, red: 0.9, green: 0.3, blue: 0.1, brightInk: 0.06
        ))
        XCTAssertFalse(plate.isLight)
        XCTAssertLessThan(max(plate.red, plate.green, plate.blue), 0.24)
    }

    func testNeutralInkDoesNotInventAChannelColour() {
        let darkInk = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 0.2, coverage: 0.4, red: 0.2, green: 0.2, blue: 0.2
        ))
        XCTAssertEqual(darkInk.color, Color(red: 1, green: 1, blue: 1))
        let whiteInk = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 1, coverage: 0.4, red: 1, green: 1, blue: 1, brightInk: 1
        ))
        XCTAssertEqual(whiteInk, ChannelLogoPlate(tone: nil))
    }

    func testMutedBrandTintsRetainStrongBlackOrWhiteInkContrast() {
        for ink in [(1.0, 0.0, 0.0), (0.0, 0.2, 1.0), (1.0, 0.8, 0.0)] {
            for whiteLettering in [false, true] {
                let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
                    luminance: 0.4, coverage: 0.4,
                    red: ink.0, green: ink.1, blue: ink.2, brightInk: whiteLettering ? 0.1 : 0
                ))
                func linear(_ value: Double) -> Double {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(plate.red)
                    + 0.7152 * linear(plate.green) + 0.0722 * linear(plate.blue)
                let contrast = whiteLettering ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
                XCTAssertGreaterThan(contrast, 7)
            }
        }
    }

    func testOriginalWhitePlateWinsEvenWithBrightHighlightsInsideTheLogo() {
        let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 0.5, coverage: 1, brightInk: 0.6,
            backgroundPlate: HeroBackgroundSample(red: 1, green: 1, blue: 1, luminance: 1)
        ))
        XCTAssertEqual(plate.color, Color(red: 1, green: 1, blue: 1))
    }

    func testOriginalBrandBackingIsNotTintedByTheLogosInk() {
        let original = HeroBackgroundSample(red: 0.1, green: 0.3, blue: 0.8, luminance: 0.3)
        let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 1, coverage: 0.4, red: 1, green: 1, blue: 1,
            brightInk: 1, backgroundPlate: original
        ))
        XCTAssertEqual(plate.red, original.red)
        XCTAssertEqual(plate.green, original.green)
        XCTAssertEqual(plate.blue, original.blue)
    }

    func testDarkPlateHasAFirmCharcoalFloorInsteadOfFadingIntoBlack() {
        let plate = ChannelLogoPlate(tone: nil)
        XCTAssertGreaterThanOrEqual(min(plate.red, plate.green, plate.blue), 0.14)
        XCTAssertFalse(plate.isLight)
    }

    func testGuideAndPlayerPlatesStaySolidOpaqueAndTheSameColour() throws {
        for tone in [
            ResolvedLogoTone(luminance: 0.1, coverage: 0.4),
            ResolvedLogoTone(luminance: 0.95, coverage: 0.4, brightInk: 0.9)
        ] {
            let plate = ChannelLogoPlate(tone: tone)
            var referencePixel: [UInt8]?
            for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
                for scheme in [ColorScheme.light, .dark] {
                    let content = ChannelLogoPlateContent(
                        name: "", image: nil, plate: plate, size: size,
                        cornerRadius: 16, artworkInset: size.height * 20 / 128
                    )
                    .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(size.width))
                    XCTAssertEqual(image.height, Int(size.height))
                    let pixels = try rgbaPixels(image)
                    for y in [4, image.height / 2, image.height - 5] {
                        let offset = (y * image.width + image.width / 2) * 4
                        let pixel = Array(pixels[offset..<(offset + 4)])
                        XCTAssertEqual(pixel[3], 255)
                        if let referencePixel {
                            XCTAssertEqual(pixel, referencePixel)
                        } else {
                            referencePixel = pixel
                        }
                    }
                    XCTAssertEqual(pixels[3], 0)
                }
            }
        }
    }

    func testOriginalLogoColoursAreNotRecolouredOrShadowed() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let content = ChannelLogoPlateContent(
            name: "Brand", image: logo,
            plate: ChannelLogoPlate(tone: ResolvedLogoTone(luminance: 0.2, coverage: 0.4)),
            size: CGSize(width: 200, height: 128), cornerRadius: 16, artworkInset: 20
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(image)
        let center = (image.height / 2 * image.width + image.width / 2) * 4
        XCTAssertEqual(Array(pixels[center..<(center + 4)]), [255, 0, 0, 255])
        let background = (4 * image.width + image.width / 2) * 4
        XCTAssertEqual(Array(pixels[background..<(background + 4)]), [255, 255, 255, 255])
    }

    func testMissingArtworkKeepsTheSameFrameForLongChannelNames() {
        for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
            let logo = ChannelLogoArtwork(
                name: String(repeating: "International News ", count: 8),
                logoURL: nil, size: size, cornerRadius: 16
            )
            let measured = UIHostingController(rootView: logo)
                .sizeThatFits(in: CGSize(width: 600, height: 600))
            XCTAssertEqual(measured.width, size.width, accuracy: 0.5)
            XCTAssertEqual(measured.height, size.height, accuracy: 0.5)
        }
    }

    func testWarmedGuideLogoAndBackingRenderInPlayerOnTheFirstFrame() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let prepared = PreparedLogo(image: image, luminance: 0.2, red: 1, green: 0, blue: 0, coverage: 1)
        HeroLogoMemo.store(
            HeroLogoAnalysis.analyze(prepared, backgroundSample: nil),
            for: HeroLogoMemo.key(for: [.remote(url)])
        )
        let renderer = ImageRenderer(content: ChannelLogoArtwork(
            name: "", logoURL: url, size: CGSize(width: 112, height: 72), cornerRadius: 12
        ))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(rendered)
        let center = (rendered.height / 2 * rendered.width + rendered.width / 2) * 4
        XCTAssertEqual(Array(pixels[center..<(center + 4)]), [255, 0, 0, 255])
        let background = (4 * rendered.width + rendered.width / 2) * 4
        XCTAssertEqual(pixels[background + 3], 255)
        XCTAssertGreaterThan(pixels[background], pixels[background + 1])
        XCTAssertGreaterThan(min(pixels[background], pixels[background + 1], pixels[background + 2]), 235)
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
