import XCTest

final class LiveTVSourceNavigationSmokeTests: XCTestCase {
    @MainActor
    func testEmptySetupOpensPlaylistFormAndBackWithoutLoadingSources() {
        let app = launchFixture()
        defer { app.terminate() }
        let welcome = app.staticTexts["Add your channels"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        assertNoPublicChannelOffer(in: app)
        XCTAssertFalse(app.staticTexts["No guide? No problem."].exists)
        assertNoSourcesOrNetwork(in: app)

        guard select(app.buttons["live-tv-setup-playlist"], in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Name (optional)"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testServerSetupExplainsMissingAccountsWithoutOfferingChannels() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Add your channels"].waitForExistence(timeout: 10))

        assertNoPublicChannelOffer(in: app)
        guard select(app.buttons["live-tv-setup-server"], in: app) else { return }
        XCTAssertTrue(app.staticTexts["No connected Live TV servers"].waitForExistence(timeout: 5))
        assertNoPublicChannelOffer(in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Add your channels"].waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSettingsSourcesPaneOpensEditorWithoutAnIntermediateManagementPage() {
        let app = launchFixture(arguments: ["--source-settings"])
        defer { app.terminate() }
        let addPlaylist = app.buttons["Add IPTV playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage sources"].exists)
        XCTAssertFalse(app.staticTexts["No guide? No problem."].exists)
        XCUIRemote.shared.press(.right)
        guard select(addPlaylist, in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Auto preview"].exists)
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSettingsSourcesPaneCanToggleAndEditAnExistingSourceDirectly() {
        let app = launchFixture(arguments: ["--source-settings", "--configured-sources"])
        defer { app.terminate() }
        let enabled = app.switches["live-tv-source-enabled-fixture"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.right)
        guard select(enabled, in: app) else { return }
        let saved = NSPredicate(format: "label == %@", "Sources 1 writes 1 requests 0")
        expectation(for: saved, evaluatedWith: app.staticTexts["fixture-source-metrics"])
        waitForExpectations(timeout: 5)
        guard select(app.buttons["live-tv-edit-source-fixture"], in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["live-tv-playlist-url"].value as? String, "https://example.invalid/fixture.m3u")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-tv-remove-source-fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage sources"].exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 1 requests 0")
    }

    @MainActor
    func testTypedSourcesDestinationCanPushPlaylistEditorAndReturn() {
        let app = launchFixture(arguments: ["--typed-sources"])
        defer { app.terminate() }

        guard select(app.buttons["fixture-sources"], in: app) else { return }
        let addPlaylist = app.buttons["Add IPTV playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        assertNoPublicChannelOffer(in: app)
        guard select(addPlaylist, in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["fixture-sources"].waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSetupCardsHaveEqualSizesAndAllActionsAreReachable() {
        let app = launchFixture(arguments: ["--setup-cards"])
        defer { app.terminate() }
        let cards = ["playlist", "server", "library"].map { app.buttons["live-tv-setup-\($0)"] }
        for card in cards { XCTAssertTrue(card.waitForExistence(timeout: 5)) }
        let sizes = cards.map { card in
            let scale = card.hasFocus ? 1.025 : 1.0
            return CGSize(width: card.frame.width / scale, height: card.frame.height / scale)
        }
        for size in sizes.dropFirst() {
            XCTAssertEqual(size.width, sizes[0].width, accuracy: 2)
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 2)
        }
        XCTAssertLessThan(cards[0].frame.maxX, cards[1].frame.minX)
        XCTAssertLessThan(cards[1].frame.maxX, cards[2].frame.minX)
        capture("live-setup-three-cards", in: app)
        for action in ["playlist", "server", "library"] {
            guard select(app.buttons["live-tv-setup-\(action)"], in: app) else { return }
            XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, action)
        }
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSetupCardsStackAtNarrowWidthsAndAccessibilitySizes() {
        for arguments in [["--setup-compact"], ["--setup-accessibility"]] {
            let app = launchFixture(arguments: ["--setup-cards"] + arguments)
            let playlist = app.buttons["live-tv-setup-playlist"]
            let server = app.buttons["live-tv-setup-server"]
            XCTAssertTrue(playlist.waitForExistence(timeout: 5))
            XCTAssertTrue(server.exists)
            XCTAssertLessThan(playlist.frame.maxY, server.frame.minY)
            XCTAssertEqual(playlist.frame.midX, server.frame.midX, accuracy: 2)
            capture(arguments[0], in: app)
            guard select(app.buttons["live-tv-setup-library"], in: app) else {
                app.terminate()
                return
            }
            XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, "library")
            assertNoSourcesOrNetwork(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testSetupCardsMirrorInRightToLeftAndRemainReadableInLightTheme() {
        let app = launchFixture(arguments: ["--setup-cards", "--rtl", "--light"])
        defer { app.terminate() }
        let playlist = app.buttons["live-tv-setup-playlist"]
        let library = app.buttons["live-tv-setup-library"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertTrue(library.exists)
        XCTAssertGreaterThan(playlist.frame.minX, library.frame.maxX)
        capture("live-setup-light-rtl", in: app)
        guard select(library, in: app) else { return }
        XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, "library")
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--source-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-source-metrics"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertNoSourcesOrNetwork(in app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 0 writes 0 requests 0")
        XCTAssertFalse(app.staticTexts["fixture-unexpected-playback"].exists)
        XCTAssertFalse(app.staticTexts["Profile settings unavailable"].exists)
    }

    @MainActor
    private func assertNoPublicChannelOffer(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Try free channels"].exists)
        XCTAssertFalse(app.buttons["Try free US channels"].exists)
        XCTAssertFalse(app.buttons["Add free channels"].exists)
        XCTAssertFalse(app.staticTexts["Free channels"].exists)
    }

    @MainActor
    private func select(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        guard button.waitForExistence(timeout: 5) else {
            XCTFail("Missing navigation control")
            return false
        }
        for _ in 0..<12 {
            let identifier = button.identifier.isEmpty ? button.label : button.identifier
            let focusedCell = app.cells.containing(.button, identifier: identifier)
                .allElementsBoundByIndex.contains(where: \.hasFocus)
            if button.hasFocus || focusedCell {
                XCUIRemote.shared.press(.select)
                return true
            }
            let focused = app.descendants(matching: .any).allElementsBoundByIndex.first(where: \.hasFocus)
            let target = button.frame
            if let focused, abs(target.midY - focused.frame.midY) < 40 {
                XCUIRemote.shared.press(target.midX < focused.frame.midX ? .left : .right)
            } else {
                XCUIRemote.shared.press(target.midY < (focused?.frame.midY ?? 0) ? .up : .down)
            }
        }
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Could not focus navigation control \(button.label)")
        return false
    }
}
