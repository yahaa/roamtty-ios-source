import XCTest

/// Walks the main screens and saves PNGs to ROAMTTY_SHOT_DIR (default /tmp/roamtty-parity)
/// for side-by-side comparison with the Android app. Asserts only what navigation needs.
final class ParityScreenshotUITests: RoamttyLiveUITestCase {
    private var shotDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROAMTTY_SHOT_DIR"] ?? "/tmp/roamtty-parity")
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shotDirectory.appendingPathComponent(name + ".png"))
        capture(name)
    }

    func testCaptureMainScreens() throws {
        showHostsTab()
        XCTAssertTrue(app.buttons["host-UI Live Host"].waitForExistence(timeout: 8))
        sleep(2); shot("01-hosts")
        try openHost(); sleep(2); shot("02-detail")
        hostMenu("host-detail-edit")
        if app.buttons["save-host"].waitForExistence(timeout: 5) { sleep(1); shot("02d-editor"); app.buttons["cancel-host-editor"].tap(); sleep(1) }
        app.buttons["host-detail-files"].tap()
        if app.descendants(matching: .any)["files-options"].firstMatch.waitForExistence(timeout: 10) {
            sleep(3); shot("02e-files")
            app.descendants(matching: .any)["files-options"].firstMatch.tap(); sleep(1); shot("02f-files-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap(); sleep(1)
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        for (button, name) in [("host-detail-terminal", "02b-launch"), ("host-detail-agent", "02c-agent")] {
            app.buttons[button].tap()
            if app.buttons["launch-session"].waitForExistence(timeout: 10) { sleep(3); shot(name) }
            if app.buttons["launch-cancel"].exists { app.buttons["launch-cancel"].tap(); sleep(1) }
        }
        let surface = try openTerminal(directory: "~")
        sleep(1); shot("03-terminal")
        sleep(6); shot("04-terminal-idle")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        sleep(1); shot("05-ghost")
        let ghost = app.buttons["terminal-ghost"]
        if ghost.waitForExistence(timeout: 3) {
            ghost.press(forDuration: 1.2)
            sleep(1); shot("06-ring")
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
            sleep(1)
        }
        if !ghost.exists { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap() }
        if ghost.waitForExistence(timeout: 3) { ghost.tap(); sleep(1); shot("07-dock") }
        for (id, name) in [("session-switcher", "08-session-menu"), ("terminal-menu", "09-settings-menu")] {
            let control = app.buttons[id]
            if control.waitForExistence(timeout: 2) {
                control.tap(); sleep(1); shot(name)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap(); sleep(1)
                if !app.buttons[id].exists, ghost.waitForExistence(timeout: 3) { ghost.tap(); sleep(1) }
            }
        }
        if app.buttons["common-commands"].waitForExistence(timeout: 2) {
            app.buttons["common-commands"].tap(); sleep(3); shot("10-commands")
            if app.buttons["command-done"].exists { app.buttons["command-done"].tap(); sleep(1) }
        }
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        if ghost.waitForExistence(timeout: 3) { ghost.tap(); sleep(1) }
        if app.buttons["terminal-menu"].waitForExistence(timeout: 2) {
            app.buttons["terminal-menu"].tap()
            let edit = app.buttons["menu-edit-text"]
            if edit.waitForExistence(timeout: 2) { edit.tap(); sleep(1); shot("11-editor") }
        }
    }
}
