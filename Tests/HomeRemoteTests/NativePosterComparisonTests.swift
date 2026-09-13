import XCTest
import UIKit

@MainActor
final class NativePosterComparisonTests: XCTestCase {
    func testInspectNativeInitializationDefaults() throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLOZZ_NATIVE_POSTER_COMPARISON"] == "1")
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        defer { app.terminate() }
        app.launchArguments = ["--native-poster-comparison"]
        app.launch()
        let metadata = app.staticTexts["native-comparison-metadata"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let report = XCTAttachment(string: metadata.label)
        report.name = "native-poster-initialization-defaults"
        report.lifetime = .keepAlways
        add(report)
        #else
        throw XCTSkip("Runs only in an isolated simulator.")
        #endif
    }

    func testCompareBareNativePosterWithAdapter() throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLOZZ_NATIVE_POSTER_COMPARISON"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        defer { app.terminate() }
        var measurements: [[String: Any]] = []
        for style in ["Default", "High Contrast"] {
            try FocusStyleSettingsCaptureTests.withFocusStyle(style) { _ in
                app.launchArguments = ["--native-poster-comparison"]
                app.launch()
                let metadata = app.staticTexts["native-comparison-metadata"]
                XCTAssertTrue(metadata.waitForExistence(timeout: 5))
                for focusedIndex in 0..<3 {
                    if focusedIndex > 0 { XCUIRemote.shared.press(.right) }
                    let focused = NSPredicate(format: "label CONTAINS %@", "\(focusedIndex): focused=true")
                    XCTAssertEqual(
                        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: metadata)], timeout: 5),
                        .completed, metadata.label
                    )
                    Thread.sleep(forTimeInterval: 1)
                    let capture = app.screenshot()
                    let attachment = XCTAttachment(screenshot: capture)
                    attachment.name = "native-poster-\(style)-focused-\(focusedIndex)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let geometry = XCTAttachment(string: metadata.label)
                    geometry.name = "native-poster-geometry-\(style)-\(focusedIndex)"
                    geometry.lifetime = .keepAlways
                    add(geometry)
                    for column in 0..<3 {
                        let spans = try landmarks(capture.image, column: column)
                        measurements.append([
                            "style": style, "focusedIndex": focusedIndex, "column": column,
                            "imageSpan": spans.red, "overlaySpan": spans.yellow, "greenPixels": spans.green
                        ])
                    }
                }
                app.terminate()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        let report = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        report.name = "native-poster-comparison-measurements"
        report.lifetime = .keepAlways
        add(report)
        #else
        throw XCTSkip("Runs only in an isolated simulator.")
        #endif
    }

    private func landmarks(_ image: UIImage, column: Int) throws -> (red: Int, yellow: Int, green: Int) {
        let bitmap = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        let scale = CGFloat(bitmap.width) / image.size.width
        let region = CGRect(x: 30 + column * 600, y: 280, width: 560, height: 340)
        var redMin = Int.max, redMax = -1, yellowMin = Int.max, yellowMax = -1, green = 0
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                let pixel = (y * bitmap.width + x) * 4
                let r = Int(bytes[pixel]), g = Int(bytes[pixel + 1]), b = Int(bytes[pixel + 2])
                if r > 130 && r > g + 60 && r > b + 60 {
                    redMin = min(redMin, x); redMax = max(redMax, x)
                }
                if r > 150 && g > 150 && b < 120 {
                    yellowMin = min(yellowMin, x); yellowMax = max(yellowMax, x)
                }
                if g > 140 && g > r + 60 && g > b + 60 { green += 1 }
            }
        }
        XCTAssertGreaterThan(redMax, redMin, "Missing image landmarks in column \(column)")
        XCTAssertGreaterThan(yellowMax, yellowMin, "Missing overlay landmarks in column \(column)")
        return (redMax - redMin + 1, yellowMax - yellowMin + 1, green)
    }
}
