import XCTest

@MainActor
final class SystemDirectionalFocusTests: XCTestCase {
    func testRemoteDirectionsDoNotRestoreThePreviousCardOrHero() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        try FocusStyleSettingsCaptureTests.withFocusStyle("Default") { _ in
            for borderless in [false, true] {
                add(try Self.exerciseDirections(in: app, borderless: borderless))
            }
        }
        #else
        throw XCTSkip("This regression uses an isolated simulator fixture.")
        #endif
    }

    static func exerciseDirections(in app: XCUIApplication, borderless: Bool) throws -> XCTAttachment {
        app.launchArguments = ["--focus-navigation-fixture"] + (borderless ? ["--borderless"] : [])
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Navigation fixture ready"].waitForExistence(timeout: 15))
        let hero = app.buttons["navigation-hero"]
        XCTAssertTrue(hero.hasFocus)
        XCUIRemote.shared.press(.down)
        try assertFocus("Row 0 Item 0", in: app)
        XCUIRemote.shared.press(.right)
        try assertFocus("Row 0 Item 1", in: app)
        XCUIRemote.shared.press(.right)
        try assertFocus("Row 0 Item 2", in: app)
        XCUIRemote.shared.press(.left)
        try assertFocus("Row 0 Item 1", in: app)
        for index in 2...6 {
            XCUIRemote.shared.press(.right)
            try assertFocus("Row 0 Item \(index)", in: app)
        }
        for index in stride(from: 5, through: 0, by: -1) {
            XCUIRemote.shared.press(.left)
            try assertFocus("Row 0 Item \(index)", in: app)
        }
        XCUIRemote.shared.press(.right)
        try assertFocus("Row 0 Item 1", in: app)
        XCUIRemote.shared.press(.down)
        try assertFocus("Row 1 Item 1", in: app)
        XCUIRemote.shared.press(.right)
        try assertFocus("Row 1 Item 2", in: app)
        XCUIRemote.shared.press(.up)
        try assertFocus("Row 0 Item 2", in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-directions-\(borderless ? "borderless" : "framed")"
        screenshot.lifetime = .keepAlways
        return screenshot
    }

    private static func assertFocus(_ label: String, in app: XCUIApplication) throws {
        let card = app.buttons.containing(.staticText, identifier: label).firstMatch
        let focused = card.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 3), "Expected \(label). \(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(focused.exists, "Focus bounced away from \(label). \(app.debugDescription)")
    }
}
