import Foundation
import XCTest

final class TerminalSettingsUITests: RoamttyLiveUITestCase {
    func testTmuxSessionSurvivesAppRelaunchAndCloseEndsIt() throws {
        let surface = try openTerminal()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try runCommand("export ROAMTTY_UI_RECOVERY='\(token)'; printf 'RECOVERY_'; printf 'READY\\n'")
        waitForOutput("RECOVERY_READY", surface: surface)

        // The session list, not the host page, holds sessions; a relaunch restores the card and opening it reconnects.
        app.terminate(); app.launch()
        showSessionsTab()
        let card = sessionCards.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "The tmux card must survive an app restart")
        let identifier = card.identifier
        card.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 25), "A restored session reconnects as soon as it is opened")
        XCTAssertFalse(app.buttons["terminal-reconnect"].exists, "No reconnect button while it reconnects by itself")
        let resumed = try runCommand("test \"$ROAMTTY_UI_RECOVERY\" = '\(token)' && { printf 'RECOVERY_'; printf 'PRESERVED\\n'; }")
        waitForOutput("RECOVERY_PRESERVED", surface: resumed)
        capture("tmux session resumed after app restart")

        // Closing ends the remote tmux session without asking; its card goes.
        closeTerminal()
        waitFor(NSPredicate(format: "exists == false"), element: app.descendants(matching: .any)[identifier].firstMatch, timeout: 15)
    }

    /// With the keyboard up, an item that put it away laid the page out inside the menu's action, which took the dock
    /// and the menu's button out of the window. UIKit then asked that button for its dismissal preview and aborted.
    func testMenuItemsChosenWithTheKeyboardUpDoNotCrash() throws {
        let surface = try openTerminal(mode: "SSH")
        func openMenu(_ menu: String) {
            let escape = app.buttons["cursor-escape"]
            XCTAssertTrue(escape.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: escape.frame.midY - surface.frame.minY)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let ghost = app.buttons["terminal-ghost"]
            XCTAssertTrue(ghost.waitForExistence(timeout: 3)); ghost.tap()
            XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard must still be up when the menu opens")
            let button = app.buttons[menu]
            XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
        }
        let hide = NSPredicate(format: "label == '收起' OR label == 'Hide'")

        openMenu("terminal-menu")
        let edit = app.buttons["menu-edit-text"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3)); edit.tap()
        XCTAssertTrue(app.textViews["prompt-editor"].waitForExistence(timeout: 5), "Edit text opens the editor")
        app.buttons.matching(hide).firstMatch.tap()

        openMenu("terminal-menu")
        let hideTools = app.buttons.matching(NSPredicate(format: "label == '隐藏操作栏' OR label == 'Hide toolbar'")).firstMatch
        XCTAssertTrue(hideTools.waitForExistence(timeout: 3)); hideTools.tap()
        XCTAssertTrue(app.buttons["common-commands"].waitForNonExistence(timeout: 5), "Hide toolbar hides the dock")
        XCTAssertEqual(app.state, .runningForeground)

        openMenu("session-switcher")
        let close = app.buttons["close-session"]
        XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
        XCTAssertTrue(app.buttons["add-session"].waitForExistence(timeout: 10), "Closing returns to the session list")
    }

    func testPinnedToolsReserveWidthAndFunctionShortcutsReachRemote() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let surface = try openTerminal()
        let originalWidth = surface.frame.width
        terminalMenu("terminal-pin-tools")
        let pin = app.buttons["terminal-menu"]
        waitFor(NSPredicate { _, _ in surface.frame.width < originalWidth - 40 }, element: surface)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["common-commands"].exists, "Pinned tools must stay open when touching the terminal")
        XCTAssertLessThan(surface.frame.width, originalWidth - 40)
        capture("Pinned tools reserve terminal columns")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor(NSPredicate { _, _ in surface.frame.width > surface.frame.height }, element: surface)
        let dock = app.scrollViews["terminal-dock"]
        for _ in 0..<5 {
            if pin.isHittable { break }
            dock.swipeUp()
        }
        XCTAssertTrue(pin.isHittable)
        XCTAssertTrue(app.buttons["common-commands"].isHittable)
        XCTAssertLessThanOrEqual(surface.frame.maxX, pin.frame.minX + 2, "Landscape tools must reserve columns, not cover terminal cells")
        capture("Pinned tools and terminal in landscape")
        XCUIDevice.shared.orientation = .portrait
        waitFor(NSPredicate { _, _ in surface.frame.height > surface.frame.width }, element: surface)
        XCTAssertTrue(pin.isHittable)
        XCTAssertLessThan(surface.frame.width, originalWidth - 40)
        terminalMenu("terminal-pin-tools")
        waitFor(NSPredicate { _, _ in abs(surface.frame.width - originalWidth) < 2 }, element: surface)
        app.buttons["collapse-dock"].tap()

        try runCommand(rawReader(prefix: "ROAMTTY_KEYS", count: 4))
        waitForOutput("ROAMTTY_KEYS_READY", surface: surface)
        openShortcutRing(surface: surface)
        let functions = app.buttons["pet-fn"]
        XCTAssertTrue(functions.waitForExistence(timeout: 2)); functions.tap()
        let f1 = app.buttons["pet-f1"]
        XCTAssertTrue(f1.waitForExistence(timeout: 2)); f1.tap()
        openShortcutRing(surface: surface)
        let controlC = app.buttons["pet-ctrl-c"]
        XCTAssertTrue(controlC.waitForExistence(timeout: 2)); controlC.tap()
        waitForOutput("ROAMTTY_KEYS_BYTES=1b4f5003", surface: surface)
        capture("F1 and Ctrl+C bytes received over SSH")
    }

    func testMultilinePasteRequiresConfirmationAndCancelSendsNothing() throws {
        let surface = try openTerminal()
        try runCommand(rawReader(prefix: "ROAMTTY_PASTE", count: 11))
        waitForOutput("ROAMTTY_PASTE_READY", surface: surface)
        let payload = "alpha\nbeta\n"
        openCommandDraft(payload)
        app.buttons["prompt-send"].tap()
        let cancel = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-cancel").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "Unbracketed multiline input must ask before sending")
        capture("Multiline paste confirmation")
        cancel.tap()
        XCTAssertEqual(app.textViews["prompt-editor"].value as? String, payload)
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let noBytes = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "ROAMTTY_PASTE_RECEIVED"), object: surface)
        noBytes.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noBytes], timeout: 2), .completed, "Cancelling must send no bytes to the waiting remote process")

        openCommandDraft(payload)
        app.buttons["prompt-send"].tap()
        let send = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 3)); send.tap()
        waitForOutput("ROAMTTY_PASTE_BYTES=616c7068610d626574610d", surface: surface)
        XCTAssertFalse(app.buttons["terminal-paste-send"].exists)
        capture("Confirmed paste preserves text and normalizes newlines")
    }

    func testSettingsFontSizeLanguageAndThemePersistAcrossRelaunch() {
        openSettings()
        app.buttons["language-en"].tap()
        app.buttons["theme-light"].tap()
        XCTAssertTrue(app.buttons["language-en"].isSelected)
        XCTAssertTrue(app.buttons["theme-light"].isSelected)
        let font = app.buttons["settings-font"]
        revealSettings(font); font.tap()
        let fira = app.buttons["FiraCode"]
        XCTAssertTrue(fira.waitForExistence(timeout: 3)); fira.tap()
        waitFor(NSPredicate(format: "value == %@", "FiraCode"), element: font)
        let slider = app.sliders["settings-font-size"]
        revealSettings(slider); slider.adjust(toNormalizedSliderPosition: 0.65)
        let fontSize = app.staticTexts["settings-font-size-value"]
        XCTAssertTrue(fontSize.exists)
        let chosenSize = fontSize.label
        XCTAssertNotEqual(chosenSize, "13 pt", "Changing the slider must change the saved font size")
        let hiddenFiles = app.switches["settings-hidden-files"]
        revealSettings(hiddenFiles)
        setSwitch(hiddenFiles, on: true)
        app.buttons["settings-done"].tap()
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "Hosts")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "Hosts")

        openSettings()
        XCTAssertTrue(app.buttons["language-en"].isSelected)
        XCTAssertTrue(app.buttons["theme-light"].isSelected)
        revealSettings(font)
        XCTAssertEqual(font.value as? String, "FiraCode")
        revealSettings(fontSize)
        XCTAssertEqual(fontSize.label, chosenSize)
        revealSettings(hiddenFiles)
        XCTAssertEqual(hiddenFiles.value as? String, "1")
        capture("Font, size and file settings persisted")
        let scroll = app.scrollViews["settings-scroll"]
        for _ in 0..<5 {
            if settingsVisible(app.buttons["theme-dark"], in: scroll) { break }
            scroll.swipeDown()
        }
        XCTAssertTrue(settingsVisible(app.buttons["theme-dark"], in: scroll))
        app.buttons["theme-dark"].tap(); app.buttons["language-zh"].tap()
        XCTAssertTrue(app.buttons["theme-dark"].isSelected)
        XCTAssertTrue(app.buttons["language-zh"].isSelected)
        app.buttons["settings-done"].tap()
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "主机")
    }

    func testAgentLauncherModesAndInstalledPluginsReflectLiveHost() throws {
        try openHost()
        hostMenu("host-detail-plugins")
        for name in ["tmux", "mosh"] {
            let installed = app.descendants(matching: .any)["plugin-installed-" + name].firstMatch
            XCTAssertTrue(installed.waitForExistence(timeout: 20), "The live fixture must report \(name) installed")
            XCTAssertFalse(app.buttons["plugin-install-" + name].exists)
        }
        let probe = app.buttons["host-plugins-retry"]
        XCTAssertTrue(probe.isEnabled); probe.tap()
        waitFor(NSPredicate(format: "isEnabled == true"), element: probe, timeout: 20)
        XCTAssertFalse(app.staticTexts["plugin-error"].exists)
        capture("Live tmux and mosh detection")
        app.buttons["plugins-done"].tap()
        app.buttons["host-detail-agent"].tap()
        let preview = app.staticTexts["launch-command-preview"]
        XCTAssertTrue(app.buttons["launch-agent"].waitForExistence(timeout: 10))
        pick("launch-agent", "Claude")
        pick("launch-agent-mode", "计划")
        XCTAssertEqual(preview.label, "claude --permission-mode plan")
        XCTAssertTrue(app.staticTexts["launch-permission-hint"].label.contains("批准"))
        pick("launch-agent", "Codex"); pick("launch-agent-mode", "只读")
        XCTAssertEqual(preview.label, "codex --sandbox read-only")
        pick("launch-agent", "Grok"); pick("launch-agent-mode", "YOLO")
        XCTAssertTrue(app.descendants(matching: .any)["launch-yolo-warning"].firstMatch.exists)
        XCTAssertEqual(preview.label, "grok --always-approve")
        pick("launch-agent-mode", "普通")
        XCTAssertFalse(app.descendants(matching: .any)["launch-yolo-warning"].firstMatch.exists)
        XCTAssertEqual(preview.label, "grok")

        let launch = app.buttons["launch-session"]
        let directory = app.textFields["launch-directory"]
        replace(directory, with: "/tmp/roamtty-missing-" + UUID().uuidString); directory.typeText("\n")
        XCTAssertTrue(app.staticTexts["launch-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(launch.isEnabled, "A failed folder request must not launch in the previous directory")
        replace(directory, with: "/tmp"); directory.typeText("\n")
        waitFor(NSPredicate(format: "isEnabled == true"), element: launch, timeout: 15)
        XCTAssertFalse(app.staticTexts["launch-error"].exists)
        XCTAssertEqual(directory.value as? String, "/tmp")
        capture("Agent modes and validated remote launch directory")
        app.buttons["launch-cancel"].tap()
        XCTAssertTrue(app.buttons["host-detail-agent"].waitForExistence(timeout: 5))
        XCTAssertEqual(sessionCards.count, 0, "Cancelling the launcher must create no session")
    }

    private func openSettings() {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8)); app.buttons["open-drawer"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 3)); app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5))
    }

    private func openShortcutRing(surface: XCUIElement) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let ghost = app.buttons["terminal-ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 3)); ghost.press(forDuration: 0.4)
    }

    /// Chooses the option starting with [prefix] from one of the launch sheet's pickers.
    private func pick(_ picker: String, _ prefix: String) {
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        // A tap landing while the previous menu is still closing does not open the next one: try once more.
        for _ in 0..<2 where !option.exists {
            app.buttons[picker].tap()
            _ = option.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(option.exists); option.tap()
    }

    private func openCommandDraft(_ text: String) {
        let editor = app.textViews["prompt-editor"]
        if !editor.exists { terminalMenu("menu-edit-text") }
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); replace(editor, with: text)
    }

    private func revealSettings(_ element: XCUIElement) {
        let scroll = app.scrollViews["settings-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        for _ in 0..<5 {
            if settingsVisible(element, in: scroll) { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(settingsVisible(element, in: scroll))
    }

    private func settingsVisible(_ element: XCUIElement, in scroll: XCUIElement) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let frame = scroll.frame.intersection(app.frame)
        let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
        return visible.contains(element.frame)
    }

    private func setSwitch(_ element: XCUIElement, on: Bool) {
        if (element.value as? String == "1") != on { element.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(element.value as? String, on ? "1" : "0")
    }

    private func waitFor(_ predicate: NSPredicate, element: XCUIElement, timeout: Double = 5, line: UInt = #line) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [check], timeout: timeout)
        if result != .completed { saveFailureScreenshot("waitFor-\(line)") }
        XCTAssertEqual(result, .completed, line: line)
    }

    /// The UI sends every byte through the real PTY. A bounded receiver restores
    /// terminal modes even on timeout; base64 keeps echoed input from containing
    /// the output markers that the tests assert.
    private func rawReader(prefix: String, count: Int) -> String {
        let source = """
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004l')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if not select.select([0], [], [], 1)[0]:
                    continue
                chunk = os.read(0, \(count) - len(received))
                if not chunk:
                    break
                if not received:
                    print('\\r\\n\(prefix)_RECEIVED', flush=True)
                received.extend(chunk)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex(), flush=True)
        """
        let encoded = Data(source.utf8).base64EncodedString()
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(encoded)'))\""
    }
}
