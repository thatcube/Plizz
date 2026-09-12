import XCTest
import UIKit

@MainActor
final class FocusStyleSettingsCaptureTests: XCTestCase {
    func testHighContrastRingAndSelectionOnOwnedSimulator() throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_SYSTEM_FOCUS_CAPTURE"] == "1",
            "Opt-in native focus regression; requires a disposable simulator and the built FocusHost fixture."
        )
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")
        settings.launch()
        try select("Accessibility", in: settings)
        try select("Display", in: settings)
        let style = settings.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus Style")).firstMatch
        let original = try XCTUnwrap(style.value as? String)
        defer {
            settings.activate()
            if style.value as? String != original {
                do { try select("Focus Style", in: settings) }
                catch { XCTFail("Could not restore the simulator's Focus Style: \(error)") }
            }
            XCTAssertEqual(style.value as? String, original)
        }
        if original != "High Contrast" {
            try select("Focus Style", in: settings)
            if settings.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "High Contrast")).firstMatch.exists {
                try select("High Contrast", in: settings)
            }
            XCTAssertEqual(style.value as? String, "High Contrast")
        }
        let tree = XCTAttachment(string: settings.debugDescription)
        tree.name = "tvOS-display-settings"
        tree.lifetime = .keepAlways
        add(tree)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        for mode in ["production", "production-circle"] {
            app.launchArguments = ["--focus-style-fixture", mode]
            app.launch()
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(focused.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "System card"))
                    .firstMatch.waitForExistence(timeout: 3),
                app.debugDescription
            )
            Thread.sleep(forTimeInterval: 0.7)
            let capture = app.screenshot()
            let screenshot = XCTAttachment(screenshot: capture)
            screenshot.name = "real-system-focus-\(mode)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            try assertHighContrastRing(in: capture.image, around: focused.frame, circular: mode == "production-circle")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Activated 1"].waitForExistence(timeout: 3), app.debugDescription)
            XCUIRemote.shared.press(.select, forDuration: 1)
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Context action"))
                    .firstMatch.waitForExistence(timeout: 3),
                app.debugDescription
            )
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.staticTexts["Activated 1"].waitForExistence(timeout: 3), "Long press must not also select the card.")
            app.terminate()
        }
        #else
        throw XCTSkip("Settings inspection is restricted to the task-owned simulator.")
        #endif
    }

    private func assertHighContrastRing(in image: UIImage, around frame: CGRect, circular: Bool) throws {
        XCTAssertLessThan(frame.height, 500, "The native wrapper must use its content's intrinsic height.")
        let bitmap = try XCTUnwrap(image.cgImage)
        let width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = CGFloat(width) / image.size.width
        let region = frame.insetBy(dx: -24, dy: -24)
        var white = 0
        for y in max(0, Int(region.minY * scale))..<min(height, Int(region.maxY * scale)) {
            for x in max(0, Int(region.minX * scale))..<min(width, Int(region.maxX * scale)) {
                let index = (y * width + x) * 4
                if bytes[index] > 220, bytes[index + 1] > 220, bytes[index + 2] > 220 { white += 1 }
            }
        }
        XCTAssertGreaterThan(white, Int(2 * (frame.width + frame.height) * scale), "The real high-contrast ring must be visible, not merely lift/specular lighting.")
        if circular {
            XCTAssertEqual(frame.width, frame.height, accuracy: 1)
            let corner = (Int((frame.minY + 4) * scale) * width + Int((frame.minX + 4) * scale)) * 4
            XCTAssertLessThan(bytes[corner..<corner + 3].max() ?? 255, 80, "A circular native card must not grow a square plate.")
        }
    }

    private func select(_ label: String, in app: XCUIApplication) throws {
        let target = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 3), app.debugDescription)
        for _ in 0..<25 {
            if target.hasFocus {
                XCUIRemote.shared.press(.select)
                return
            }
            let current = try XCTUnwrap(app.cells.allElementsBoundByIndex.first(where: \.hasFocus))
            XCUIRemote.shared.press(target.frame.midY < current.frame.midY ? .up : .down)
        }
        XCTFail("Could not focus \(label). \(app.debugDescription)")
    }
}
