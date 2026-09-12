import XCTest

final class LiveTVSearchRemoteTests: XCTestCase {
    @MainActor
    func testGuideLastRowWithoutSearch() {
        let app = launchSearch(arguments: ["--without-search"])
        defer { app.terminate() }
        XCTAssertEqual(app.staticTexts["selection-probe"].label, "Selection 0 focus true")
        for row in 1..<30 {
            XCUIRemote.shared.press(.down)
            let button = app.buttons["live-tv-channel-content-channels-\(row)-whole"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing row \(row)")
            XCTAssertTrue(button.hasFocus, "Focus skipped row \(row)")
        }
    }

    @MainActor
    func testDownEntersFirstResultAndCanReachTheLastRowWithoutJumping() {
        let app = launchSearch()
        defer { app.terminate() }
        let selection = app.staticTexts["selection-probe"]
        XCTAssertEqual(selection.label, "Selection 0 focus false")

        for row in 0..<30 {
            XCUIRemote.shared.press(.down)
            let button = app.buttons["live-tv-channel-content-channels-\(row)-whole"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing row \(row)")
            XCTAssertTrue(button.hasFocus, "Focus skipped row \(row)")
            XCTAssertEqual(selection.label, "Selection \(row) focus true")
        }
        for row in (0..<29).reversed() {
            XCUIRemote.shared.press(.up)
            XCTAssertEqual(selection.label, "Selection \(row) focus true")
        }
        XCUIRemote.shared.press(.up)
        XCTAssertEqual(selection.label, "Selection 0 focus false")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["live-tv-channel-content-channels-0-whole"].hasFocus)
    }

    @MainActor
    func testKeyboardEntryWithProgrammeRowsAndRightToLeftLayout() {
        let app = launchSearch(arguments: ["--programmes", "--rtl"])
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(app.staticTexts["selection-probe"].label, "Selection 0 focus true")
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Current programme 0").firstMatch.hasFocus)
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(app.staticTexts["selection-probe"].label, "Selection 1 focus true")
    }

    @MainActor
    func testBackClosesOnceFromKeyboardAndFilteredResults() {
        for arguments in [[], ["--filtered"], ["--filtered", "--enter-results"]] {
            let app = launchSearch(arguments: arguments)
            defer { app.terminate() }
            if arguments.contains("--enter-results") {
                XCUIRemote.shared.press(.down)
                XCTAssertTrue(app.buttons["live-tv-channel-content-channels-2-whole"].hasFocus)
            }
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.staticTexts["search-closed"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["search-closed"].label, "Search closed 1")
            XCTAssertFalse(app.searchFields.firstMatch.exists)
        }
    }

    @MainActor
    private func launchSearch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--search-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["selection-probe"].waitForExistence(timeout: 10))
        return app
    }
}
