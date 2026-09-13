import XCTest

@MainActor
final class ProductionHomeNavigationTests: XCTestCase {
    func testNavigateProductionHomeWithNativeCards() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture"]
        app.launchEnvironment["PLZPERF_ANIMATIONS"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        XCTAssertTrue(hero.hasFocus)
        print("PRODUCTION_HOME_READY \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 8)
        for cycle in 0..<3 {
            print("PRODUCTION_HOME_CYCLE \(cycle) \(Date().timeIntervalSince1970)")
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(hero.hasFocus)
            for _ in 0..<4 {
                XCUIRemote.shared.press(.right)
                Thread.sleep(forTimeInterval: 0.2)
            }
            for _ in 0..<4 {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: 0.2)
            }
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 1)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(hero.hasFocus)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "production-home-after-navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #else
        throw XCTSkip("This uses an isolated simulator with local fixture data.")
        #endif
    }
}
