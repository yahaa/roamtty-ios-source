import XCTest

/// In landscape, where height is short, the host form, the plugin sheet and the drawer give their height to content: a
/// flat bar instead of the system one, the form as two columns, the plugins as two cards, the drawer's menu as one row.
final class LandscapeSheetsUITests: RoamttyLiveUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    /// Attaches the screen and keeps a copy under /tmp/roamtty-landscape for review.
    private func shot(_ name: String) {
        sleep(1)
        capture(name)
        let directory = URL(fileURLWithPath: "/tmp/roamtty-landscape")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testHostFormIsTwoColumnsWithEveryFieldInView() {
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5)); addHostButton.tap()
        XCTAssertTrue(app.buttons["save-host"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The system bar is hidden in landscape")
        let cancel = app.buttons["cancel-host-editor"], save = app.buttons["save-host"]
        XCTAssertEqual(cancel.frame.midY, save.frame.midY, accuracy: 2)
        XCTAssertLessThan(save.frame.maxY, 60, "The bar is short")
        let name = element("host-name"), auth = element("host-auth-method"), system = element("host-session-mode")
        XCTAssertGreaterThan(auth.frame.minX, name.frame.maxX - 2, "Authentication sits beside the connection fields")
        XCTAssertEqual(auth.frame.minY, name.frame.minY, accuracy: 12, "The two columns start together")
        // Both rows of sections are in view at once, the session mode included.
        XCTAssertTrue(system.isHittable)
        XCTAssertTrue(element("host-password").isHittable)
        shot("host-form-password")
        // A shorter authentication box keeps the row's height: the session mode does not move up.
        let modeTop = system.frame.minY
        app.segmentedControls["host-auth-method"].buttons.element(boundBy: 2).tap(); sleep(1)
        XCTAssertEqual(system.frame.minY, modeTop, accuracy: 1)
        shot("host-form-interactive")
        save.tap()
        XCTAssertTrue(app.staticTexts["editor-error"].waitForExistence(timeout: 2), "Saving still validates in landscape")
        cancel.tap()
        XCTAssertTrue(app.buttons["add-host"].waitForExistence(timeout: 3))
    }

    func testDrawerKeepsItsHeightForSessions() {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        app.buttons["open-drawer"].tap()
        let settings = app.buttons["open-settings"], help = app.buttons["open-guide"], about = app.buttons["open-about"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertEqual(settings.frame.midY, help.frame.midY, accuracy: 2, "Settings, Help and About share one row")
        XCTAssertEqual(settings.frame.midY, about.frame.midY, accuracy: 2)
        let hosts = app.buttons["drawer-hosts"]
        XCTAssertGreaterThan(settings.frame.minY - hosts.frame.maxY, 180, "Most of the height is left for the sessions")
        shot("drawer")
        settings.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 3))
        app.buttons["settings-done"].tap()
    }

    func testPluginsAreSideBySideCards() throws {
        try openHost()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        hostMenu("host-detail-plugins")
        let tmux = element("plugin-installed-tmux"), mosh = element("plugin-installed-mosh")
        XCTAssertTrue(tmux.waitForExistence(timeout: 20)); XCTAssertTrue(mosh.waitForExistence(timeout: 20))
        sleep(1)
        XCTAssertEqual(tmux.frame.midY, mosh.frame.midY, accuracy: 1, "The two cards stand side by side")
        XCTAssertGreaterThan(mosh.frame.minX, tmux.frame.maxX)
        let probe = app.buttons["host-plugins-retry"], done = app.buttons["plugins-done"]
        XCTAssertEqual(probe.frame.midY, done.frame.midY, accuracy: 2, "Check again is the bar's refresh button")
        shot("plugins")
        probe.tap()
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: probe)
        wait(for: [enabled], timeout: 20)
        XCTAssertTrue(tmux.exists)
        XCTAssertFalse(app.staticTexts["plugin-error"].exists)
        done.tap()
    }
}
