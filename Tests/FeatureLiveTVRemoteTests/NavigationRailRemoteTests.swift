import XCTest

final class NavigationRailRemoteTests: XCTestCase {
    @MainActor
    func testPinnedNavigationEntersLeavesAndReopensAfterReordering() {
        let app = launchFixture()
        defer { app.terminate() }
        let settings = app.buttons["Settings"]
        let profile = app.buttons["Navigation"]
        let reorder = app.buttons["navigation-reorder"]

        for entry in 0..<2 {
            XCUIRemote.shared.press(.left)
            assertFocused(settings)
            XCTAssertTrue(profile.isEnabled, "Entering navigation must expand its actual focus scope")
            if entry == 0 {
                XCUIRemote.shared.press(.up)
                assertFocused(app.buttons["Library 29"])
            } else {
                XCTAssertLessThan(settings.frame.midY, app.frame.midY)
            }
            XCUIRemote.shared.press(.right)
            assertPageFocused(in: app)
            XCTAssertFalse(profile.isEnabled, "Leaving navigation must collapse its focus scope")

            if entry == 0 {
                if !reorder.hasFocus {
                    XCUIRemote.shared.press(app.buttons["navigation-open"].hasFocus ? .up : .down)
                }
                assertFocused(reorder)
                XCUIRemote.shared.press(.select)
            }
        }
    }

    @MainActor
    func testExplicitOpenMovesActualFocusIntoTheSelectedOffscreenDestination() {
        let app = launchFixture()
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["navigation-open"])
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["Settings"])
        XCTAssertTrue(app.buttons["Navigation"].isEnabled)
        XCUIRemote.shared.press(.select)
        assertPageFocused(in: app)
        XCTAssertFalse(app.buttons["Navigation"].isEnabled)
    }

    @MainActor
    func testNativeSearchCanEnterNavigationAndReturnToItsKeyboardRepeatedly() {
        let app = XCUIApplication()
        app.launchArguments = ["--navigation-fixture", "--navigation-search"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        let search = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Search", "pinned-sidebar-page-button"
        )).firstMatch
        let capsule = app.buttons["pinned-sidebar-page-button"]
        let profile = app.buttons["Navigation"]
        for _ in 0..<2 {
            for _ in 0..<5 {
                if search.exists && search.hasFocus { break }
                XCUIRemote.shared.press(.up)
            }
            assertFocused(search)
            XCTAssertTrue(profile.isEnabled)
            XCUIRemote.shared.press(.right)
            let returned = NSPredicate { _, _ in
                capsule.exists && capsule.isEnabled && !profile.isEnabled
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5),
                .completed, app.debugDescription
            )
        }
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--navigation-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["navigation-page"].waitForExistence(timeout: 10))
        if app.buttons["Settings"].hasFocus { XCUIRemote.shared.press(.right) }
        assertPageFocused(in: app)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["navigation-page"])
        return app
    }

    @MainActor
    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate { _, _ in element.exists && element.hasFocus }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5),
            .completed, "Focus did not reach \(element). \(XCUIApplication().debugDescription)",
            file: file, line: line
        )
    }

    @MainActor
    private func assertPageFocused(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate { _, _ in
            ["navigation-page", "navigation-reorder", "navigation-open"].contains {
                app.buttons[$0].hasFocus
            }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5),
            .completed, "Focus did not return to the page. \(app.debugDescription)",
            file: file, line: line
        )
    }
}
