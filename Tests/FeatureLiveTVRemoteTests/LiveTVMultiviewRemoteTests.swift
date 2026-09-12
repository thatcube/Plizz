import XCTest
import UIKit

final class LiveTVMultiviewRemoteTests: XCTestCase {
    @MainActor
    func testNativePlayerFocusIsRenderedAcrossControlsAndHUDReturn() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        if app.buttons["Pause"].exists { select(app.buttons["Pause"], in: app) }
        let controls: [(String, XCUIElement)] = [
            ("previous", app.buttons["Previous Channel"]),
            ("play", app.buttons["Play"]),
            ("next", app.buttons["Next Channel"]),
            ("favorite", app.buttons["live-channel-favorite"]),
            ("multiview", app.buttons["live-channel-multiview"]),
            ("tracks", app.buttons["live-channel-tracks"])
        ]
        for (name, target) in controls {
            let anchor = name == "next" ? app.buttons["Previous Channel"] : app.buttons["Next Channel"]
            assertRenderedFocus(target, anchor: anchor, name: "player-\(name)", in: app)
        }
        select(app.buttons["live-channel-tracks"], in: app)
        capture("player-track-menu", in: app)
        selectMenuItem("Off", in: app)
        assertRenderedFocus(
            app.buttons["live-channel-tracks"], anchor: app.buttons["Next Channel"],
            name: "player-tracks-return", in: app
        )
        select(app.buttons["Play"], in: app)
        let revealSurface = app.descendants(matching: .any)["live-channel-reveal-surface"].firstMatch
        for cycle in 1...2 {
            let hidden = NSPredicate { _, _ in
                !app.buttons["live-channel-tracks"].exists && revealSurface.exists
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 15),
                .completed, "Playing HUD must hide without losing its video owner"
            )
            capture("player-hud-hidden-\(cycle)", in: app)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(revealSurface.exists, "Visible controls must remove the native reveal focus surface")
            let focused = focusedElement(in: app)
            guard focused.exists, focused.elementType == .button else {
                XCTFail("Revealing the HUD must focus a visible control: \(nativeFocus(in: app))")
                return
            }
            let identifier = focused.identifier
            let label = focused.label
            let frame = focused.frame
            let beforeFocus = nativeFocus(in: app)
            let before = capture("player-hud-revealed-\(cycle)", in: app)
            let direction: XCUIRemote.Button = identifier == "live-channel-tracks" ? .down
                : identifier == "live-channel-multiview" ? .left : .right
            XCUIRemote.shared.press(direction)
            let moved = focusedElement(in: app)
            XCTAssertTrue(moved.exists && moved.elementType == .button)
            XCTAssertTrue(moved.identifier != identifier || moved.label != label, "Remote input must move control focus")
            XCTAssertFalse(revealSurface.exists)
            XCTAssertTrue(app.buttons["Pause"].exists)
            let after = capture("player-hud-moved-\(cycle)", in: app)
            let change = pixelDifference(before, after, region: frame.insetBy(dx: -8, dy: -8), screen: app.frame)
            let evidence = XCTAttachment(string:
                "HUD cycle \(cycle), \(label): changed pixel fraction=\(change.fraction), mean RGB delta=\(change.mean)\n" +
                "Revealed: \(beforeFocus)\nMoved: \(nativeFocus(in: app))"
            )
            evidence.name = "player-hud-return-focus-\(cycle)-pixel-evidence"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertGreaterThan(
                change.fraction, 0.03,
                "The initially focused HUD control must visibly differ after native directional movement"
            )
        }
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
    }

    @MainActor
    func testMultiviewToolbarFocusIsRendered() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        for name in ["add", "layout", "replace", "done"] {
            let anchor = name == "layout" ? app.buttons["live-multiview-done"] : app.buttons["live-multiview-layout"]
            assertRenderedFocus(
                app.buttons["live-multiview-\(name)"], anchor: anchor,
                name: "multiview-single-\(name)", in: app
            )
        }
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        focusAudio("Sports 2", in: app)
        for name in ["promote", "remove"] {
            assertRenderedFocus(
                app.buttons["live-multiview-\(name)"], anchor: app.buttons["live-multiview-layout"],
                name: "multiview-pair-\(name)", in: app
            )
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testMultiviewFocusedPanesKeepVideoReadableInBothLayouts() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        for layout in ["side-by-side", "corner"] {
            if layout == "corner" {
                select(app.buttons["live-multiview-layout"], in: app)
                selectMenuItem("Corner", in: app)
                assertCornerLayout(in: app)
            }
            for (index, channel) in ["Sports 1", "Sports 2"].enumerated() {
                let anchor = layout == "corner" && channel == "Sports 2"
                    ? app.buttons["live-multiview-remove"] : app.buttons["live-multiview-layout"]
                assertRenderedFocus(
                    pane(channel, in: app), anchor: anchor,
                    name: "\(layout)-\(channel)", preservesVideo: true,
                    visualSurface: app.otherElements["multiview-fixture-video-\(index + 1)"], in: app
                )
            }
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testPaneDirectionsFromDoneAndAcrossEveryCornerKeepNativeContextMenus() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-done"], in: app, activate: false)
        XCUIRemote.shared.press(.down)
        assertNativeFocus(pane("Sports 1", in: app), in: app)
        capture("single-pane-down-from-done", in: app)
        XCUIRemote.shared.press(.up)
        assertNativeFocus(app.buttons["live-multiview-watch"], in: app)

        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        for corner in ["Bottom right", "Top right", "Top left", "Bottom left"] {
            select(app.buttons["live-multiview-layout"], in: app)
            selectMenuItem(corner, in: app)
            select(pane("Sports 1", in: app), in: app, activate: false)
            XCUIRemote.shared.press(corner.hasSuffix("left") ? .left : .right)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            assertAudio("Sports 2", in: app)
            capture("\(corner)-inset-directional-focus", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
            XCUIRemote.shared.press(corner.hasSuffix("left") ? .right : .left)
            assertNativeFocus(pane("Sports 1", in: app), in: app)
            assertAudio("Sports 1", in: app)
            capture("\(corner)-main-directional-focus", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 1", engine: 1, in: app)
            revealChrome(in: app)
        }
        focusAudio("Sports 2", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        try await Task.sleep(for: .seconds(6))
        capture("corner-pane-native-context-menu", in: app)
        selectMenuItem("Make main picture", in: app)
        assertAudio("Sports 2", in: app)
        finishSetup(in: app)
        assertVideoFrame(2, equals: app.frame, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testProductionRootRetainsThePromotedPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--live-root-fixture"]
        app.launch()
        defer { app.terminate() }
        select(app.buttons["live-tv-channel-channels-1"], in: app)
        select(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Play channel")
            ).firstMatch,
            in: app
        )
        XCTAssertTrue(
            app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        select(app.buttons["live-channel-multiview"], in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertSideBySideFillsScreen(in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        revealChrome(in: app)
        focusAudio("Sports 2", in: app)
        select(app.buttons["live-multiview-done"], in: app)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-2"].label, "Engine 2 loads 1")
        XCUIRemote.shared.press(.menu)
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        select(app.buttons["live-root-fixture-refresh"], in: app)
        XCTAssertEqual(app.buttons["live-root-fixture-refresh"].value as? String, "1")
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        select(app.buttons["live-root-fixture-leave"], in: app)
        assertMetrics("Engines 2 loads 2 stops 2 audible 0", in: app)
    }

    @MainActor
    func testNativeFullscreenMultiviewLayoutsAndReturnKeepExistingPlayers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--multiview-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
        select(app.buttons["live-channel-multiview"], in: app)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5))
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)

        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertSideBySideFillsScreen(in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        revealChrome(in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        assertCornerLayout(in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Top left", in: app)
        assertCornerLayout(in: app, topLeft: true)
        focusAudio("Sports 1", in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)

        revealChrome(in: app)
        focusAudio("Sports 2", in: app)
        select(app.buttons["live-multiview-done"], in: app)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-2"].label, "Engine 2 loads 1")
    }

    @MainActor
    func testChromeHidesWithoutResizingAndNativeInputRestoresFocusAndAudio() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        finishSetup(in: app)
        assertSideBySideFillsScreen(in: app)
        let original = [1, 2].map { app.otherElements["multiview-fixture-video-\($0)"].frame }
        for cycle in 1...2 {
            focusAudio("Sports 1", in: app)
            let shown = capture("multiview-chrome-shown-\(cycle)", in: app)
            assertChromeHidden(in: app)
            let hidden = capture("multiview-chrome-hidden-\(cycle)", in: app)
            assertNativeFocus(pane("Sports 1", in: app), in: app)
            for (index, frame) in original.enumerated() {
                assertVideoFrame(index + 1, equals: frame, in: app)
                let sample = CGRect(
                    x: frame.minX + frame.width * 0.18, y: frame.minY + frame.height * 0.22,
                    width: frame.width * 0.12, height: frame.height * 0.12
                )
                XCTAssertLessThan(
                    pixelDifference(shown, hidden, region: sample, screen: app.frame).mean, 0.06,
                    "Hiding chrome must not change video contents"
                )
            }
            XCUIRemote.shared.press(.right)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            assertAudio("Sports 2", in: app)
            XCTAssertTrue(app.buttons["live-multiview-edit"].waitForExistence(timeout: 2))
            capture("multiview-chrome-revealed-\(cycle)", in: app)
            for (index, frame) in original.enumerated() {
                assertVideoFrame(index + 1, equals: frame, in: app)
            }
            if !app.buttons["live-multiview-edit"].exists { XCUIRemote.shared.press(.down) }
            select(app.buttons["live-multiview-edit"], in: app, activate: false)
            assertAudio("Sports 2", in: app)
            try await Task.sleep(for: .seconds(6))
            assertNativeFocus(app.buttons["live-multiview-edit"], in: app)
            XCTAssertTrue(app.buttons["live-multiview-done"].exists)
            XCUIRemote.shared.press(.menu)
            assertChromeHidden(in: app)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            try await Task.sleep(for: .seconds(1))
            XCTAssertFalse(app.buttons["live-multiview-layout"].exists, "Focus restoration must not reopen chrome")
            assertAudio("Sports 2", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testNativePickerAndLayoutMenuRemainPresentedPastInactivityGrace() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-add"], in: app)
        try await Task.sleep(for: .seconds(6))
        capture("multiview-picker-pinned", in: app)
        chooseGuideChannel(2, in: app)
        finishSetup(in: app)
        focusAudio("Sports 2", in: app)
        revealChrome(in: app)
        assertNativeFocus(app.buttons["live-multiview-layout"], in: app)
        assertAudio("Sports 2", in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        try await Task.sleep(for: .seconds(6))
        capture("multiview-layout-menu-pinned", in: app)
        selectMenuItem("Corner", in: app)
        assertCornerLayout(in: app)
        assertAudio("Sports 2", in: app)
        finishSetup(in: app)
        focusAudio("Sports 2", in: app)
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertFalse(app.buttons["live-multiview-layout"].exists)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
    }

    @MainActor
    func testFocusedPendingPaneKeepsExistingAudioUntilItsSourceIsPrepared() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--multiview-fixture", "--pending-multiview-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(pane("Sports 2", in: app), in: app, activate: false)
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        assertAudio("Sports 1", in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(pane("Sports 1", in: app).exists, "An unprepared pane must not expand")
        assertAudio("Sports 1", in: app)
        capture("multiview-pending-pane-focus", in: app)
        XCUIRemote.shared.press(.playPause)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        assertAudio("Sports 2", in: app)
        capture("multiview-prepared-pane-focus", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
    }

    @MainActor
    private func focusAudio(_ channel: String, in app: XCUIApplication) {
        select(pane(channel, in: app), in: app, activate: false)
        assertNativeFocus(pane(channel, in: app), in: app)
        assertAudio(channel, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    private func assertAudio(_ channel: String, in app: XCUIApplication) {
        let matches = NSPredicate { _, _ in
            guard self.pane(channel, in: app).value as? String == "Audio on" else { return false }
            return (1...4).map { "Sports \($0)" }.filter { $0 != channel }.allSatisfy {
                let other = self.pane($0, in: app)
                return !other.exists || other.value as? String == "Muted"
            }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Expected audio on \(channel), value \(String(describing: self.pane(channel, in: app).value)). " +
                "Sports 1: \(String(describing: self.pane("Sports 1", in: app).value)). \(nativeFocus(in: app))"
        )
    }

    @MainActor
    private func revealChrome(in app: XCUIApplication) {
        if !app.buttons["live-multiview-layout"].exists && !app.buttons["live-multiview-edit"].exists {
            XCUIRemote.shared.press(.down)
        }
        if app.buttons["live-multiview-edit"].exists {
            select(app.buttons["live-multiview-edit"], in: app)
        }
        XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func finishSetup(in app: XCUIApplication) {
        let watch = app.descendants(matching: .any)["live-multiview-watch"].firstMatch
        if watch.exists {
            select(watch, in: app)
        }
    }

    @MainActor
    private func assertChromeHidden(in app: XCUIApplication) {
        let hidden = NSPredicate { _, _ in
            !app.buttons["live-multiview-layout"].exists
                && !app.buttons["live-multiview-edit"].exists && !app.buttons["live-multiview-done"].exists
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 8),
            .completed, "Watching must remove chrome without removing native pane focus targets"
        )
    }

    @MainActor
    private func assertSelectAndBackPreservePictures(channel: String, engine: Int, in app: XCUIApplication) {
        finishSetup(in: app)
        select(pane(channel, in: app), in: app, activate: false)
        let original = [1, 2].map { app.otherElements["multiview-fixture-video-\($0)"].frame }
        assertNativeFocus(pane(channel, in: app), in: app)
        XCUIRemote.shared.press(.select)
        assertVideoFrame(engine, equals: app.frame, in: app)
        let other = channel == "Sports 1" ? "Sports 2" : "Sports 1"
        let hidden = NSPredicate { _, _ in !self.pane(other, in: app).exists }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 3),
            .completed, "Expanded viewing must expose only the selected pane")
        capture("multiview-expanded-\(channel)", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(pane(other, in: app).waitForExistence(timeout: 3))
        for (index, frame) in original.enumerated() {
            assertVideoFrame(index + 1, equals: frame, in: app)
        }
        assertNativeFocus(pane(channel, in: app), in: app)
        assertAudio(channel, in: app)
        assertChromeHidden(in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        capture("multiview-restored-\(channel)", in: app)
    }

    @MainActor
    func testFourChannelSetupUsesGuideAndFullscreenHasNoFocusOutline() {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        select(app.buttons["live-channel-multiview"], in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["live-multiview-watch"].firstMatch.waitForExistence(timeout: 5),
            app.debugDescription)
        let setupVideo = app.otherElements["multiview-fixture-video-1"].frame
        XCTAssertGreaterThan(setupVideo.minX, app.frame.minX)
        XCTAssertGreaterThan(setupVideo.minY, app.frame.minY)
        for channel in 2...4 {
            select(app.buttons["live-multiview-add"], in: app)
            XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Choose channel"].exists)
            capture("multiview-guide-selection-\(channel)", in: app)
            chooseGuideChannel(channel, in: app)
            assertMetrics("Engines \(channel) loads \(channel) stops 0 audible 1", in: app)
        }
        XCTAssertFalse(app.buttons["live-multiview-add"].exists)
        finishSetup(in: app)
        let frames = (0..<4).map { index in
            CGRect(
                x: app.frame.minX + CGFloat(index % 2) * app.frame.width / 2,
                y: app.frame.minY + CGFloat(index / 2) * app.frame.height / 2,
                width: app.frame.width / 2, height: app.frame.height / 2)
        }
        for (index, frame) in frames.enumerated() { assertVideoFrame(index + 1, equals: frame, in: app) }
        select(pane("Sports 2", in: app), in: app, activate: false)
        select(pane("Sports 1", in: app), in: app, activate: false)
        let first = capture("multiview-four-watch-focus-first", in: app)
        select(pane("Sports 2", in: app), in: app, activate: false)
        assertAudio("Sports 2", in: app)
        let second = capture("multiview-four-watch-focus-second", in: app)
        let edge = CGRect(
            x: frames[0].minX + frames[0].width * 0.35, y: frames[0].minY + 2,
            width: frames[0].width * 0.3, height: 6)
        XCTAssertLessThan(pixelDifference(first, second, region: edge, screen: app.frame).mean, 0.01)
        select(pane("Sports 4", in: app), in: app, activate: false)
        assertAudio("Sports 4", in: app)
        XCUIRemote.shared.press(.select)
        assertVideoFrame(4, equals: app.frame, in: app)
        XCUIRemote.shared.press(.menu)
        for (index, frame) in frames.enumerated() { assertVideoFrame(index + 1, equals: frame, in: app) }
        assertAudio("Sports 4", in: app)
        assertMetrics("Engines 4 loads 4 stops 0 audible 1", in: app)
    }

    @MainActor
    private func chooseGuideChannel(_ number: Int, in app: XCUIApplication) {
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@ AND label == %@",
            "live-tv-channel-", "live-tv-channel-content-", "Sports \(number)"
        )).firstMatch
        for _ in 0..<16 {
            if target.exists {
                select(target, in: app)
                return
            }
            XCUIRemote.shared.press(.down)
        }
        XCTFail("Guide channel \(number) was not reachable. \(app.debugDescription)")
    }

    @MainActor
    private func confirmCloseMultiview(in app: XCUIApplication) {
        let dialog = app.sheets["Close Multiview?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let close = dialog.buttons.matching(NSPredicate(format: "label == %@", "Close Multiview")).firstMatch
        select(close, in: app)
        let dismissed = NSPredicate { _, _ in !dialog.exists }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5),
            .completed)
    }

    @MainActor
    func testProductionGuideAddsReplacesAndCancelsWithoutDiscardingMultiview() {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        select(app.buttons["live-tv-channel-channels-2"], in: app)
        selectMenuItem("Add to Favorites", in: app)
        startProductionChannel(in: app)
        select(app.buttons["live-channel-multiview"], in: app)
        select(app.buttons["live-multiview-add"], in: app)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["live-tv-category-list"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].exists)
        XCTAssertFalse(app.staticTexts["Choose channel"].exists)
        capture("actual-guide-selects-multiview-channel", in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        XCUIRemote.shared.press(.menu)
        select(app.buttons["live-tv-search"], in: app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        select(app.buttons["live-multiview-cancel-selection"], in: app)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5))
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        focusAudio("Sports 2", in: app)
        select(app.buttons["live-multiview-replace"], in: app)
        chooseGuideChannel(3, in: app)
        let replaced = NSPredicate { _, _ in
            app.staticTexts["multiview-fixture-player-2"].label == "Engine 2 loads 2"
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: replaced, object: nil)], timeout: 5),
            .completed)
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
        XCTAssertTrue(pane("Sports 3", in: app).exists)
        finishSetup(in: app)
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        let keepWatching = app.buttons.matching(identifier: "Keep watching").firstMatch
        XCTAssertTrue(keepWatching.waitForExistence(timeout: 5))
        XCTAssertTrue(pane("Sports 1", in: app).exists)
        select(keepWatching, in: app)
        XCTAssertTrue(pane("Sports 3", in: app).waitForExistence(timeout: 5))
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFavoriteMultiviewRestoresMainAndStackAfterRelaunch() {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        startProductionChannel(in: app)
        select(app.buttons["live-channel-multiview"], in: app)
        for number in 2...4 {
            select(app.buttons["live-multiview-add"], in: app)
            chooseGuideChannel(number, in: app)
            assertMetrics("Engines \(number) loads \(number) stops 0 audible 1", in: app)
        }
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Main and stack", in: app)
        select(app.buttons["live-multiview-favorite"], in: app)
        XCTAssertEqual(app.buttons["live-multiview-favorite"].value as? String, "Saved")
        capture("favorite-main-and-stack-setup", in: app)
        app.terminate()
        app.launchArguments = ["--live-root-fixture", "--preserve-multiview-favorites"]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-multiview-favorites"].waitForExistence(timeout: 10))
        select(app.buttons["live-tv-multiview-favorites"], in: app)
        let saved = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "live-multiview-saved-")).firstMatch
        select(saved, in: app)
        assertMetrics("Engines 4 loads 4 stops 0 audible 1", in: app)
        let main = pane("Sports 1", in: app)
        for number in 2...4 {
            let secondary = pane("Sports \(number)", in: app)
            XCTAssertGreaterThan(main.frame.width, secondary.frame.width * 2)
            XCTAssertGreaterThan(secondary.frame.minX, main.frame.maxX)
            if number > 2 {
                let previous = pane("Sports \(number - 1)", in: app)
                XCTAssertGreaterThan(secondary.frame.minY, previous.frame.maxY)
            }
        }
        capture("favorite-main-and-stack-restored", in: app)
    }

    @MainActor
    private func launchProductionGuide() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--live-root-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func startProductionChannel(in app: XCUIApplication) {
        select(app.buttons["live-tv-channel-channels-1"], in: app)
        selectMenuItem("Play channel", in: app)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertSideBySideFillsScreen(in app: XCUIApplication) {
        finishSetup(in: app)
        for index in 0..<2 {
            let width = app.frame.width / 2
            assertVideoFrame(index + 1, equals: CGRect(
                x: app.frame.minX + CGFloat(index) * width,
                y: app.frame.minY, width: width, height: app.frame.height
            ), in: app)
        }
    }

    @MainActor
    private func assertVideoFrame(_ engine: Int, equals expected: CGRect, in app: XCUIApplication) {
        let video = app.otherElements["multiview-fixture-video-\(engine)"]
        let matches = NSPredicate { _, _ in
            guard video.exists else { return false }
            let actual = video.frame
            return abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
                && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Video \(engine) must receive its maximum player slot \(expected): \(video)"
        )
    }

    @MainActor
    private func assertCornerLayout(
        in app: XCUIApplication, topLeft: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let main = app.otherElements["multiview-fixture-video-1"]
        let inset = app.otherElements["multiview-fixture-video-2"]
        let matches = NSPredicate { _, _ in
            guard main.exists, inset.exists, inset.frame.width < main.frame.width / 2,
                  main.frame.insetBy(dx: -1, dy: -1).contains(inset.frame) else { return false }
            return !topLeft || (inset.frame.midX < main.frame.midX && inset.frame.midY < main.frame.midY)
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, app.debugDescription, file: file, line: line
        )
        if app.descendants(matching: .any)["live-multiview-watch"].firstMatch.exists {
            XCTAssertGreaterThan(main.frame.minX, app.frame.minX)
            XCTAssertGreaterThan(main.frame.minY, app.frame.minY)
            XCTAssertLessThan(main.frame.maxY, app.frame.maxY)
        } else {
            assertVideoFrame(1, equals: app.frame, in: app)
        }
    }

    @MainActor
    private func selectMenuItem(
        _ title: String, identifierPrefix: String = "", in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // tvOS exposes Menu actions as focused collection cells, not AX buttons.
        let predicate = identifierPrefix.isEmpty
            ? NSPredicate(format: "label == %@", title)
            : NSPredicate(
                format: "label == %@ AND identifier BEGINSWITH %@", title, identifierPrefix
            )
        let item = app.cells.containing(predicate).firstMatch
        select(item, in: app, file: file, line: line)
    }

    @MainActor
    private func select(
        _ target: XCUIElement, in app: XCUIApplication,
        activate: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard target.exists || target.waitForExistence(timeout: 5) else {
            XCTFail(
                "Missing target: \(target). Native focus: \(nativeFocus(in: app)). \(app.debugDescription)",
                file: file, line: line
            )
            return
        }
        var previousFrame: CGRect?
        var previousMoveWasVertical = false
        for _ in 0..<16 {
            let targetContainsFocus = target.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
            if target.hasFocus || targetContainsFocus {
                if activate { XCUIRemote.shared.press(.select) }
                return
            }
            let focused = focusedElement(in: app)
            guard focused.exists else {
                XCTContext.runActivity(named: "Native focus transition") { activity in
                    activity.add(XCTAttachment(string: nativeFocus(in: app)))
                }
                let movingUp = previousFrame.map { target.frame.midY < $0.midY } ?? false
                XCUIRemote.shared.press(movingUp ? .up : .down)
                continue
            }
            let sameNativeCell = target.elementType == .cell && focused.elementType == .cell &&
                abs(target.frame.midX - focused.frame.midX) < 2 &&
                abs(target.frame.midY - focused.frame.midY) < 2
            if sameNativeCell || (!target.identifier.isEmpty && focused.identifier == target.identifier) ||
               ((!target.identifier.isEmpty || !target.label.isEmpty) &&
               focused.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@", target.identifier, target.label
                )
            ).firstMatch.exists) {
                if activate { XCUIRemote.shared.press(.select) }
                return
            }
            let destination = target.frame
            let origin = focused.frame
            let stalled = previousFrame == origin
            previousFrame = origin
            let below = destination.minY >= origin.maxY - 1
            let above = destination.maxY <= origin.minY + 1
            let horizontalGap = destination.minX >= origin.maxX - 1 || destination.maxX <= origin.minX + 1
            let verticalCenters = !horizontalGap &&
                abs(destination.midY - origin.midY) > abs(destination.midX - origin.midX)
            if (above || below || verticalCenters) && !(stalled && previousMoveWasVertical && horizontalGap) {
                XCUIRemote.shared.press(destination.midY > origin.midY ? .down : .up)
                previousMoveWasVertical = true
            } else {
                XCUIRemote.shared.press(destination.midX > origin.midX ? .right : .left)
                previousMoveWasVertical = false
            }
        }
        let focused = focusedElement(in: app)
        XCTFail(
            "Remote focus cannot reach \(target). Focus: \(focused.exists ? focused.debugDescription : "none"). " +
                "Native focus: \(nativeFocus(in: app)). \(app.debugDescription)",
            file: file, line: line
        )
    }

    @MainActor
    private func focusedElement(in app: XCUIApplication) -> XCUIElement {
        let reported = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard !reported.exists || reported.elementType == .other else { return reported }
        let diagnostic = nativeFocus(in: app)
        let prefix = "focusWindowFrame="
        guard let component = diagnostic.components(separatedBy: " | ")
            .first(where: { $0.hasPrefix(prefix) }) else { return reported }
        let frame = NSCoder.cgRect(for: String(component.dropFirst(prefix.count)))
        guard frame.width > 0, frame.height > 0 else { return reported }
        // Native menu anchors, menu cells and panes can own UIKit focus without AX hasFocus.
        let candidates = diagnostic.contains("focused=_UIContextMenuCell |")
            ? app.cells.allElementsBoundByIndex
            : app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "live-multiview-"
            )).allElementsBoundByIndex
        return candidates.first {
            let candidate = $0.frame
            return abs(candidate.midX - frame.midX) < 2 &&
                abs(candidate.midY - frame.midY) < 2 &&
                abs(candidate.width - frame.width) < 2 &&
                abs(candidate.height - frame.height) < 2
        } ?? reported
    }

    @MainActor
    private func pane(_ channel: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "live-multiview-pane-", channel
        )).firstMatch
    }

    @MainActor
    private func assertNativeFocus(
        _ target: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let matches = NSPredicate { _, _ in
            guard target.exists else { return false }
            if target.hasFocus { return true }
            let focused = self.focusedElement(in: app)
            guard focused.exists else { return false }
            if !target.identifier.isEmpty { return focused.identifier == target.identifier }
            return !target.label.isEmpty && focused.label == target.label && focused.elementType == target.elementType
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Expected native focus on \(target). \(nativeFocus(in: app)). \(app.debugDescription)",
            file: file, line: line
        )
    }

    @MainActor
    private func launchVisualFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--multiview-fixture", "--visual-focus-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        capture("visual-fixture-launched", in: app)
        return app
    }

    @MainActor
    @discardableResult
    private func capture(_ name: String, in app: XCUIApplication) -> UIImage {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot.image
    }

    @MainActor
    private func assertRenderedFocus(
        _ target: XCUIElement, anchor: XCUIElement, name: String,
        preservesVideo: Bool = false, visualSurface: XCUIElement? = nil, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        select(anchor, in: app, activate: false, file: file, line: line)
        guard target.exists else {
            XCTFail("Missing visual focus target \(name)", file: file, line: line)
            return
        }
        if let visualSurface {
            guard visualSurface.exists, !visualSurface.frame.isEmpty else {
                XCTFail("Missing rendered video surface for \(name)", file: file, line: line)
                return
            }
        }
        // Corner hit regions are narrower than the video and its full-picture focus outline.
        let frame = visualSurface?.frame ?? target.frame
        let before = capture("\(name)-unfocused", in: app)
        select(target, in: app, activate: false, file: file, line: line)
        let after = capture("\(name)-focused", in: app)
        let region = frame.union(visualSurface?.frame ?? target.frame).insetBy(dx: -8, dy: -8)
        let change = pixelDifference(before, after, region: region, screen: app.frame)
        let evidence = "\(name): changed pixel fraction=\(change.fraction), mean RGB delta=\(change.mean)"
        let attachment = XCTAttachment(string: "\(evidence)\n\(nativeFocus(in: app))")
        attachment.name = "\(name)-pixel-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(
            change.fraction, preservesVideo ? 0.007 : 0.03,
            "Focused \(name) must have a visible treatment. \(evidence)", file: file, line: line
        )
        if preservesVideo {
            let sample = CGRect(
                x: frame.minX + frame.width * 0.18, y: frame.minY + frame.height * 0.22,
                width: frame.width * 0.12, height: frame.height * 0.12
            )
            let videoChange = pixelDifference(before, after, region: sample, screen: app.frame)
            let videoEvidence = XCTAttachment(string: "\(name): video RGB delta=\(videoChange.mean)")
            videoEvidence.name = "\(name)-video-evidence"
            videoEvidence.lifetime = .keepAlways
            add(videoEvidence)
            XCTAssertLessThan(
                videoChange.mean, 0.06,
                "Focus must not wash out \(name)'s video: RGB delta=\(videoChange.mean)",
                file: file, line: line
            )
        }
    }

    private func pixelDifference(
        _ before: UIImage, _ after: UIImage, region: CGRect, screen: CGRect
    ) -> (fraction: Double, mean: Double) {
        guard let first = before.cgImage, let second = after.cgImage,
              first.width == second.width, first.height == second.height else { return (0, 1) }
        let width = first.width
        let height = first.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { storage in
                let context = CGContext(
                    data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let a = pixels(first)
        let b = pixels(second)
        let clipped = region.intersection(screen)
        guard !clipped.isNull, !clipped.isEmpty else { return (0, 1) }
        let x0 = max(0, Int(clipped.minX / screen.width * Double(width)))
        let x1 = min(width, Int(clipped.maxX / screen.width * Double(width)))
        let y0 = max(0, Int(clipped.minY / screen.height * Double(height)))
        let y1 = min(height, Int(clipped.maxY / screen.height * Double(height)))
        var changed = 0
        var sum = 0.0
        let count = (x1 - x0) * (y1 - y0)
        guard count > 0 else { return (0, 1) }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                let delta = (0..<3).reduce(0) { $0 + abs(Int(a[offset + $1]) - Int(b[offset + $1])) }
                let normalized = Double(delta) / (3 * 255)
                if normalized > 0.15 { changed += 1 }
                sum += normalized
            }
        }
        return (Double(changed) / Double(count), sum / Double(count))
    }

    @MainActor
    private func nativeFocus(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["multiview-fixture-focus-diagnostics"]
        guard diagnostics.exists else { return "unavailable" }
        return diagnostics.value as? String ?? "unavailable"
    }

    @MainActor
    private func assertMetrics(
        _ expected: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let metrics = app.staticTexts["multiview-fixture-metrics"]
        let matches = NSPredicate { _, _ in metrics.exists && metrics.label == expected }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, app.debugDescription, file: file, line: line
        )
    }
}
