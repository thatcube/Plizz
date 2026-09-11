#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class HeroLogoBackgroundPlateTests: XCTestCase {
    func testPreparationRetainsTheOriginalPlateAfterStrippingAndCropping() throws {
        let prepared = try prepare(background: UIColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        let plate = try XCTUnwrap(prepared.backgroundPlate)
        XCTAssertEqual(plate.red, 0.1, accuracy: 0.02)
        XCTAssertEqual(plate.green, 0.3, accuracy: 0.02)
        XCTAssertEqual(plate.blue, 0.8, accuracy: 0.02)
        XCTAssertGreaterThan(prepared.luminance, 0.95)
        XCTAssertLessThan(prepared.image.size.width, 96)
        XCTAssertLessThan(prepared.image.size.height, 48)
    }

    func testTransparentLogoDoesNotInventABackgroundPlate() throws {
        let prepared = try prepare(background: .clear)
        XCTAssertNil(prepared.backgroundPlate)
        XCTAssertGreaterThan(prepared.red, 0.95)
    }

    func testBoxedArtworkInsideTransparentMarginsRetainsItsWhiteBacking() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 8, y: 6, width: 80, height: 36))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 24, y: 12, width: 48, height: 24))
        }
        let prepared = try XCTUnwrap(HeroLogoPipeline.decodeAndPrepare(XCTUnwrap(image.pngData())))
        let plate = try XCTUnwrap(prepared.backgroundPlate)
        XCTAssertEqual(plate.red, 1, accuracy: 0.01)
        XCTAssertEqual(plate.green, 1, accuracy: 0.01)
        XCTAssertEqual(plate.blue, 1, accuracy: 0.01)
        XCTAssertEqual(prepared.image.size, CGSize(width: 80, height: 36))
        XCTAssertGreaterThan(prepared.brightInk, 0.2)
    }

    func testAnalysisAndMemoPreserveThePlateReportedToTheHost() throws {
        let prepared = try prepare(background: .blue)
        let processed = HeroLogoAnalysis.analyze(prepared, backgroundSample: nil)
        let key = "logo-plate-test-\(UUID())"
        HeroLogoMemo.store(processed, for: key)
        let cached = try XCTUnwrap(HeroLogoMemo.value(for: key))
        XCTAssertNotNil(cached.tone.backgroundPlate)
        XCTAssertEqual(cached.tone.backgroundPlate, prepared.backgroundPlate)
        XCTAssertEqual(cached.tone.red, prepared.red)
        XCTAssertEqual(cached.tone.brightInk, prepared.brightInk)
        XCTAssertTrue(cached.image === processed.image)
    }

    func testMostlyWhiteInsetPlateWithSmallDarkLetteringStillUsesWhite() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 8, y: 6, width: 80, height: 36))
            UIColor.black.setFill()
            context.fill(CGRect(x: 40, y: 20, width: 8, height: 8))
        }
        let prepared = try XCTUnwrap(HeroLogoPipeline.decodeAndPrepare(XCTUnwrap(image.pngData())))
        XCTAssertGreaterThan(prepared.luminance, 0.95)
        XCTAssertEqual(try XCTUnwrap(prepared.backgroundPlate).luminance, 1, accuracy: 0.01)
    }

    private func prepare(background: UIColor) throws -> PreparedLogo {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
            UIColor.white.setFill()
            context.fill(CGRect(x: 24, y: 12, width: 48, height: 24))
        }
        return try XCTUnwrap(HeroLogoPipeline.decodeAndPrepare(XCTUnwrap(image.pngData())))
    }
}
#endif
