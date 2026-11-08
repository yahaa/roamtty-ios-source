import XCTest

class RoamttyLiveUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Start upright whatever orientation an earlier test left the simulator in.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        for key in ["ROAMTTY_TEST_HOST", "ROAMTTY_TEST_PORT", "ROAMTTY_TEST_USERNAME", "ROAMTTY_TEST_PASSWORD"] {
            if let value = ProcessInfo.processInfo.environment[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "UI-\(UUID().uuidString)"
        addUIInterruptionMonitor(withDescription: "Roamtty local network permission") { alert in
            guard alert.label.contains("Roamtty") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Roamtty'")).count > 0 else { return false }
            for title in ["Allow", "允许", "OK", "好"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists && (alert.label.contains("Roamtty") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Roamtty'")).count > 0) {
            for title in ["Allow", "允许", "OK", "好"] where alert.buttons[title].exists { alert.buttons[title].tap(); break }
        }
        // A failed previous case may leave a durable extension receipt. Let normal
        // startup consume it into this case's isolated store, then dismiss its chooser.
        // Relaunches within a test do not run this cleanup and still verify recovery.
        let incoming = app.navigationBars.matching(NSPredicate(format: "identifier == '共享文件' OR identifier == 'Shared files'")).firstMatch
        if incoming.waitForExistence(timeout: 1) {
            let cancel = incoming.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
            XCTAssertTrue(cancel.exists); cancel.tap()
        }
    }

    /// The home page opens on its sessions tab; host cards and + live on the hosts tab.
    func showHostsTab() {
        let tab = app.buttons["home-tab-hosts"]
        if tab.waitForExistence(timeout: 2), tab.isHittable, !tab.isSelected { tab.tap() }
    }
    func showSessionsTab() {
        let tab = app.buttons["home-tab-sessions"]
        if tab.waitForExistence(timeout: 2), tab.isHittable, !tab.isSelected { tab.tap() }
    }
    var addHostButton: XCUIElement { showHostsTab(); return app.buttons["add-host"] }
    /// A session card on the home sessions tab (not its title, status or action children).
    var sessionCards: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "^home-session-[0-9A-Fa-f-]{36}$"))
    }

    /// The home session cards, reached back from a host page or file browser.
    func homeSessionCards() -> XCUIElementQuery {
        for _ in 0..<3 where !app.buttons["home-tab-sessions"].exists && app.navigationBars.buttons.count > 0 {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        showSessionsTab()
        return sessionCards
    }
    /// The status line of a home session card ("已连接", "等待确认" …).
    func sessionStatus(_ cardID: String) -> XCUIElement {
        app.descendants(matching: .any)["home-session-status-" + String(cardID.dropFirst("home-session-".count))].firstMatch
    }
    func sessionConnected(_ cardID: String) -> Bool {
        let label = sessionStatus(cardID).label
        return label.contains("已连接") || label.contains("Connected")
    }
    /// Detaches the tmux client, which leaves its card disconnected, and goes back from the terminal.
    func detachTerminal() throws {
        try runCommand("tmux detach-client")
        let back = app.buttons["terminal-leave"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
    }

    /// Chooses an item of the host page's ⋯ menu (安装插件, 编辑主机, 删除主机).
    func hostMenu(_ item: String) {
        let menu = app.buttons["host-detail-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8)); menu.tap()
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 3)); entry.tap()
    }

    func openHost() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_HOST"] != nil else { throw XCTSkip("A live SSH fixture is required") }
        showHostsTab()
        let host = app.buttons["host-UI Live Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        let trust = app.buttons["auth-confirm"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 8))
    }

    @discardableResult func openTerminal(preferMosh: Bool = false, directory: String = "/tmp", mode: String = "tmux") throws -> XCUIElement {
        if !app.buttons["host-detail-terminal"].exists { try openHost() }
        app.buttons["host-detail-terminal"].tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 20))
        app.segmentedControls["launch-mode"].buttons[mode].tap()
        let folder = app.textFields["launch-directory"]
        replace(folder, with: directory); folder.typeText("\n")
        let mosh = app.switches["launch-mosh"]
        XCTAssertTrue(mosh.waitForExistence(timeout: 5))
        if (mosh.value as? String == "1") != preferMosh { mosh.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(mosh.value as? String, preferMosh ? "1" : "0")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: launch)
        waitForExpectations(timeout: 25); launch.tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        waitForConnected()
        return surface
    }

    /// The terminal has no status bar; an invisible element carries the connection phase.
    func phase(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'terminal-phase' AND label == %@", label)).firstMatch
    }
    func waitForConnected(timeout: Double = 20) {
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: timeout), "The terminal must connect")
    }

    /// Shows the dock: wakes the toolbox ghost with a reading tap, then taps it.
    func openTools() {
        if app.buttons["common-commands"].exists && app.buttons["common-commands"].isHittable { return }
        // The toolbox steps aside while the prompt editor is open, as on Android.
        if app.textViews["prompt-editor"].exists { app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap() }
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        let ghost = app.buttons["terminal-ghost"]
        // A reading tap wakes the ghost; one landing while the keyboard slides away can be absorbed, so retry.
        // Always wake it once: a ghost that is still shown may be fading out and gone before the tap lands.
        for attempt in 0..<3 where attempt == 0 || !ghost.exists {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
            if ghost.waitForExistence(timeout: 2) { break }
        }
        if !ghost.exists { saveFailureScreenshot("openTools") }
        XCTAssertTrue(ghost.exists); ghost.tap()
        XCTAssertTrue(app.buttons["common-commands"].waitForExistence(timeout: 3))
    }

    /// "tmux SSH", "SSH mosh" …: the session mode and the transport carrying it.
    var terminalTransport: String { app.descendants(matching: .any)["terminal-phase"].firstMatch.value as? String ?? "" }

    /// Back to the host page through the session menu (the terminal has no navigation bar).
    func leaveTerminal() {
        openTools(); app.buttons["session-switcher"].tap()
        let back = app.buttons.matching(NSPredicate(format: "label == '返回主机详情' OR label == 'Back to host details'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3)); back.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 5))
    }

    /// Chooses an item of the file browser's ··· menu (批量下载, 上传, 新建文件夹 …).
    func filesMenu(_ item: String) {
        let options = app.descendants(matching: .any).matching(identifier: "files-options").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        let entry = app.descendants(matching: .any).matching(identifier: item).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3)); entry.tap()
    }

    /// Chooses an item of the dock's terminal-settings menu (编辑文本, 固定操作栏, 粘贴, 关闭连接 …).
    func terminalMenu(_ item: String) {
        openTools(); app.buttons["terminal-menu"].tap()
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 3)); entry.tap()
    }

    /// Closes the session through the session menu: it ends on the server, without asking, and the session list shows.
    func closeTerminal() {
        openTools(); app.buttons["session-switcher"].tap()
        let close = app.buttons["close-session"]
        XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
        XCTAssertTrue(app.buttons["add-session"].waitForExistence(timeout: 10), "Closing returns to the session list")
    }

    /// Empties the prompt editor (holding ⌫ clears it) and puts it away, so a paste stages only the clipboard.
    func clearDraft() {
        let editor = app.textViews["prompt-editor"]
        if !editor.exists { terminalMenu("menu-edit-text") }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["draft-delete"].firstMatch.press(forDuration: 1)
        XCTAssertEqual(editor.value as? String ?? "", "")
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
    }

    /// Stages [text] in the prompt editor and sends it as one paste, without Enter.
    func typeIntoTerminal(_ text: String) {
        let editor = app.textViews["prompt-editor"]
        if !editor.exists { terminalMenu("menu-edit-text") }
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); replace(editor, with: text)
        app.buttons["prompt-send"].tap()
    }

    @discardableResult func runCommand(_ text: String) throws -> XCUIElement {
        typeIntoTerminal(text)
        app.buttons["prompt-enter"].tap()
        // Put the editor away so later gestures and screenshots see the whole terminal.
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        return surface
    }

    func waitForOutput(_ text: String, surface: XCUIElement, timeout: Double = 20) {
        // SwiftTerm's buffer export inserts a newline after every visual row,
        // including soft wraps. Match remote markers across those display rows.
        let rendered = NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            return value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").contains(text)
        }
        let expectation = XCTNSPredicateExpectation(predicate: rendered, object: surface)
        expectation.expectationDescription = "Terminal output contains \(text)"
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) != .completed else { return }
        // What the terminal showed instead, so the failure explains itself.
        let shown = (surface.value as? String ?? "").replacingOccurrences(of: "\r", with: "").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6).joined(separator: " | ")
        XCTFail("Terminal output does not contain \(text) after \(Int(timeout)) s; its last rows: \(shown)")
    }

    func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.exists); field.tap()
        func remaining() -> String? {
            let value = field.value as? String ?? ""
            return value.isEmpty || value == field.placeholderValue ? nil : value
        }
        if remaining() != nil {
            // iOS typeText inserts arrow-key glyphs literally. Use the native edit menu
            // to select the entire value, including text beyond a long field's viewport.
            field.press(forDuration: 1.1)
            let selectAll = app.menuItems.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'")).firstMatch
            let selectAllButton = app.buttons.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'")).firstMatch
            if selectAll.waitForExistence(timeout: 1) { selectAll.tap() } else if selectAllButton.exists { selectAllButton.tap() } else {
                field.doubleTap()
                if selectAll.waitForExistence(timeout: 1) { selectAll.tap() } else if selectAllButton.exists { selectAllButton.tap() }
            }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        // The long press sometimes selects only a word, leaving the rest. Backspace from
        // the trailing corner, where the caret lands at the end of a short remainder.
        for _ in 0..<4 {
            guard let old = remaining() else { break }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Replacing an input must remove its entire previous value")
    }

    /// Also writes the screen to the host's /tmp/roamtty-parity, which survives without the result bundle.
    func saveFailureScreenshot(_ name: String) {
        let directory = URL(fileURLWithPath: "/tmp/roamtty-parity")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("fail-" + name + ".png"))
        capture("Failure: " + name)
    }

    func capture(_ name: String) {
        // The application crop can use stale portrait bounds after rotation.
        // Preserve the actual display, including native picker presentation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
