import XCTest

final class SeriesHeroCaptureTests: XCTestCase {
    @MainActor
    func testSeriesHeroFocusRoundTrips() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLOZZ_DETAIL_REMOTE_CAPTURE"] == "1",
                          "Open the selected show detail page before running this capture.")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let hero = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail-hero-"))
        let focusedHero = hero.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(hero.firstMatch.waitForExistence(timeout: 20), "The series hero must be present.")
        for _ in 0..<4 {
            if focusedHero.exists { break }
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(focusedHero.exists, "Start with focus on a hero control.")

        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Series hero before capture"
        before.lifetime = .keepAlways
        add(before)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(focusedHero.exists)
        let browser = XCTAttachment(screenshot: app.screenshot())
        browser.name = "Series episode browser"
        browser.lifetime = .keepAlways
        add(browser)
        for _ in 0..<3 {
            if focusedHero.exists { break }
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(focusedHero.exists)
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<8 {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 2)
            XCTAssertFalse(focusedHero.exists, "Down must enter the episode browser.")
            for _ in 0..<3 {
                if focusedHero.exists { break }
                XCUIRemote.shared.press(.up)
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertTrue(focusedHero.exists, "Up must return through the season bar to the hero.")
            Thread.sleep(forTimeInterval: 2)
        }
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Series hero after capture"
        after.lifetime = .keepAlways
        add(after)
    }
}
