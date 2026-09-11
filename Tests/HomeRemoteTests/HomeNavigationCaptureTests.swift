import XCTest

final class HomeNavigationCaptureTests: XCTestCase {
    @MainActor
    func testDriveForegroundHomeForCapture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_HOME_REMOTE_CAPTURE"] == "1",
            "Opt-in physical Home capture; requires an already-running Plozz on Home."
        )
        continueAfterFailure = false
        let startup = ProcessInfo.processInfo.environment["PLOZZ_HOME_CAPTURE_PHASE"] == "startup"
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        let hero: XCUIElement
        if startup {
            let token = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_HOME_CAPTURE_LAUNCH_TOKEN"])
            hero = app.buttons["home-hero-action-row.\(token)"]
            print("PLZREMOTE ready-for-launch \(token)")
        } else {
            XCTAssertNotEqual(app.state, .notRunning, "Launch the desired capture configuration first.")
            app.activate()
            hero = app.buttons["home-hero-action-row"]
        }
        XCTAssertTrue(hero.waitForExistence(timeout: 45), "Home hero must be loaded, not a profile picker.")
        XCTAssertEqual(app.state, .runningForeground, "Launch the desired capture configuration first.")
        if startup && !hero.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(hero.hasFocus, "Start on the hero, not a sidebar or another row.")
        if !startup {
            capture("Before navigation", app: app)
            print("PLZREMOTE warmup \(Date().timeIntervalSince1970)")
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 2)
            XCTAssertFalse(hero.hasFocus, "Down must leave the hero.")
            capture("Continue Watching", app: app)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(hero.hasFocus, "Up must return to the hero.")
        }

        print("PLZREMOTE begin \(Date().timeIntervalSince1970)")
        if ProcessInfo.processInfo.environment["PLOZZ_HOME_ANIMATION_METRICS"] == "1" {
            let options = XCTMeasureOptions()
            options.iterationCount = 12
            measure(metrics: ["HomeRecede", "HomeReturn"].map {
                XCTOSSignpostMetric(subsystem: "com.plozz.app", category: "homeanimation", name: $0)
            }, options: options) {
                print("PLZREMOTE cycle \(Date().timeIntervalSince1970)")
                navigationCycle()
            }
        } else {
            for _ in 0..<12 { navigationCycle() }
        }
        print("PLZREMOTE end \(Date().timeIntervalSince1970)")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(hero.hasFocus)
        capture("After navigation", app: app)
    }

    @MainActor
    private func navigationCycle() {
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        XCUIRemote.shared.press(.up)
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
