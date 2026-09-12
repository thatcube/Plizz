import XCTest

final class HomeNavigationCaptureTests: XCTestCase {
    @MainActor
    func testDriveForegroundHomeForCapture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_HOME_REMOTE_CAPTURE"] == "1",
            "Opt-in physical Home capture; requires an already-running Plozz on Home."
        )
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        XCTAssertNotEqual(app.state, .notRunning, "Launch the desired capture configuration first.")
        app.activate()
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "Home hero must be loaded, not a profile picker.")
        XCTAssertEqual(app.state, .runningForeground, "Launch the desired capture configuration first.")
        focusHero(hero, in: app)
        Thread.sleep(forTimeInterval: 2)
        capture("Before navigation", app: app)
        print("PLZREMOTE warmup \(Date().timeIntervalSince1970)")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(hero.hasFocus, "Down must leave the hero.")
        capture("Continue Watching", app: app)
        XCUIRemote.shared.press(.up)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(hero.hasFocus, "Up must return to the hero.")

        print("PLZREMOTE begin \(Date().timeIntervalSince1970)")
        if ProcessInfo.processInfo.environment["PLOZZ_HOME_ANIMATION_METRICS"] == "1" {
            let options = XCTMeasureOptions()
            options.iterationCount = 12
            measure(metrics: ["HomeRecede", "HomeReturn"].map {
                XCTOSSignpostMetric(subsystem: "com.plozz.app", category: "homeanimation", name: $0)
            }, options: options) {
                print("PLZREMOTE cycle \(Date().timeIntervalSince1970)")
                navigationCycle(hero: hero)
            }
        } else {
            for _ in 0..<12 { navigationCycle(hero: hero) }
        }
        print("PLZREMOTE end \(Date().timeIntervalSince1970)")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(hero.hasFocus)
        capture("After navigation", app: app)
    }

    @MainActor
    private func focusHero(_ hero: XCUIElement, in app: XCUIApplication) {
        var previousFrame: CGRect?
        var lastMoveWasUp = false
        for _ in 0..<12 {
            if hero.hasFocus { return }
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            let frame = focused.frame
            let leaveSidebar = focused.label == "Home" || (lastMoveWasUp && previousFrame == frame)
            XCUIRemote.shared.press(leaveSidebar ? .right : .up)
            previousFrame = frame
            lastMoveWasUp = !leaveSidebar
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("Could not focus the Home hero; no measurement should proceed.")
    }

    @MainActor
    private func navigationCycle(hero: XCUIElement) {
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(hero.hasFocus, "Down must reach the rows.")
        XCUIRemote.shared.press(.up)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(hero.hasFocus, "Up must return to the hero.")
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
