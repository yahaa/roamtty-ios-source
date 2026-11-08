import XCTest

/// Every page and sheet in landscape uses one flat 48-point bar instead of the system one, and lays its content out to
/// use the width: settings, the guide and about as two columns, the new-session choices as a grid, the transfers as
/// two columns, the file preview and the command history with their status in the bar.
final class LandscapePagesUITests: RoamttyLiveUITestCase {
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

    private func turn() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
    }

    /// The control is in the flat bar: near the top, and no system bar is shown.
    private func assertInBar(_ control: XCUIElement, _ message: String = "") {
        XCTAssertTrue(control.waitForExistence(timeout: 8), message)
        XCTAssertLessThan(control.frame.maxY, 60, "In the 48-point bar " + message)
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The system bar is hidden in landscape " + message)
    }

    private func openFromDrawer(_ id: String) {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8))
        app.buttons["open-drawer"].tap()
        let item = app.buttons[id]
        XCTAssertTrue(item.waitForExistence(timeout: 3)); item.tap()
    }

    func testSettingsGuideAndAboutAreTwoColumns() {
        turn()
        openFromDrawer("open-settings")
        let done = app.buttons["settings-done"]
        assertInBar(done, "settings")
        let theme = element("theme-system"), notify = element("settings-notify-off")
        XCTAssertTrue(theme.waitForExistence(timeout: 3)); XCTAssertTrue(notify.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(notify.frame.minX, theme.frame.maxX - 2, "Notifications sit in the right column")
        XCTAssertLessThan(abs(notify.frame.minY - theme.frame.minY), 220, "Both columns start near the top")
        shot("settings")
        done.tap()

        openFromDrawer("open-guide")
        assertInBar(app.buttons["guide-done"], "guide")
        shot("guide")
        app.buttons["guide-done"].tap()

        openFromDrawer("open-about")
        assertInBar(app.buttons["about-done"], "about")
        let policy = element("about-privacy-policy")
        XCTAssertTrue(policy.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(policy.frame.minX, app.windows.firstMatch.frame.midX - 20, "Local data sits in the right column")
        shot("about")
        app.buttons["about-done"].tap()
    }

    func testNewSessionChoicesAreAGrid() {
        showSessionsTab()
        turn()
        let add = app.buttons["add-session"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        let close = app.buttons["new-session-close"]
        assertInBar(close, "new session")
        let terminal = app.buttons["new-session-pick-terminal"], claude = app.buttons["new-session-pick-claude"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))
        if claude.exists {
            XCTAssertNotEqual(terminal.frame.minX, claude.frame.minX, "The choices are laid out as two columns")
        }
        XCTAssertTrue(terminal.isHittable, "Every choice is in view without scrolling")
        shot("new-session")
        terminal.tap()
        let back = app.buttons["new-session-back"]
        assertInBar(back, "host step")
        XCTAssertEqual(back.frame.midY, close.frame.midY, accuracy: 2, "Back and close share the bar")
        shot("new-session-hosts")
        close.tap()
    }

    func testFilePreviewTransfersAndCommandsKeepTheHeight() throws {
        let surface = try openTerminal()
        let base = "/tmp/roamtty-landscape-" + String(UUID().uuidString.prefix(8))
        let ready = "LANDSCAPE_READY_" + String(UUID().uuidString.prefix(8))
        let text = (1...40).map { "line \($0): landscape preview keeps the height for the file" }.joined(separator: "\n")
        try runCommand("mkdir -p " + base + " && printf '%s' " + Data(text.utf8).base64EncodedString() + " | base64 -d > " + base + "/notes.txt && echo " + ready)
        waitForOutput(ready, surface: surface)

        turn()
        openTools(); app.buttons["common-commands"].tap()
        let search = app.textFields["history-search"], closeCommands = app.buttons["command-done"]
        assertInBar(closeCommands, "commands")
        XCTAssertEqual(search.frame.midY, closeCommands.frame.midY, accuracy: 4, "Search sits in the bar")
        shot("commands")
        closeCommands.tap()

        openTools(); app.buttons["download-file"].tap()
        // Opened from the terminal the browser picks files to download; leaving that mode, a tap previews.
        filesMenu("files-select")
        let filesSearch = app.textFields["files-search"]
        XCTAssertTrue(filesSearch.waitForExistence(timeout: 10)); replace(filesSearch, with: base); filesSearch.typeText("\n")
        let folder = app.buttons["files-entry-" + base]
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        let file = app.buttons["files-entry-" + base + "/notes.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        let previewDone = app.buttons["preview-done"]
        assertInBar(previewDone, "preview")
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["preview-download"].frame.midY, previewDone.frame.midY, accuracy: 2, "Download is in the bar")
        shot("preview")
        app.buttons["preview-download"].tap()

        let transfersDone = app.buttons["transfer-done"]
        assertInBar(transfersDone, "transfers")
        shot("transfers")
        transfersDone.tap()
        XCTAssertTrue(previewDone.waitForExistence(timeout: 5)); previewDone.tap()
    }
}
