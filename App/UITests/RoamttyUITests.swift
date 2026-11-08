import XCTest

final class RoamttyUITests: RoamttyLiveUITestCase {
    private var shareDestination = ""
    func testHomeContainsHostsAndEditorValidatesRequiredFields() {
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.element.exists)
        capture("Host home — dark")
        addHostButton.tap()
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.staticTexts["editor-error"].waitForExistence(timeout: 2))
        app.textFields["host-name"].tap()
        app.textFields["host-name"].typeText("Development")
        app.textFields["host-address"].tap()
        app.textFields["host-address"].typeText("example.invalid")
        app.textFields["host-username"].tap()
        app.textFields["host-username"].typeText("developer")
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.buttons["host-Development"].waitForExistence(timeout: 3))
        app.buttons["host-Development"].tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["host-detail-files"].exists)
        XCTAssertTrue(app.buttons["host-detail-agent"].exists)
    }
    /// In landscape the host page has one flat bar like home's: back, the 概览 · 进程 · 信息 tabs and the actions on a
    /// single line, over one scrolling page whose position the tabs follow.
    func testHostDetailLandscapeBar() {
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5)); addHostButton.tap()
        for (field, text) in [("host-name", "Landscape"), ("host-address", "example.invalid"), ("host-username", "developer")] {
            app.textFields[field].tap(); app.textFields[field].typeText(text)
        }
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.buttons["host-Landscape"].waitForExistence(timeout: 3)); app.buttons["host-Landscape"].tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 3))
        // The host keeps no password, so the monitor asks for one; this case only looks at the layout.
        if app.buttons["auth-cancel"].waitForExistence(timeout: 5) { app.buttons["auth-cancel"].tap() }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let back = app.buttons["host-detail-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertLessThanOrEqual(back.frame.height, 48)
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The system bar is hidden in landscape")
        for id in ["host-tab-overview", "host-tab-processes", "host-tab-info", "host-detail-agent", "host-detail-terminal", "host-detail-files", "host-detail-menu"] {
            let item = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(item.exists, id)
            XCTAssertEqual(item.frame.midY, back.frame.midY, accuracy: 2, id)
        }
        XCTAssertTrue(app.staticTexts["Landscape"].exists, "概览 names the host")
        capture("Host detail — landscape overview")
        // One page: tapping a tab scrolls to its section, and scrolling moves the tab.
        app.buttons["host-tab-info"].tap()
        XCTAssertTrue(app.staticTexts["developer"].waitForExistence(timeout: 3))
        sleep(1)
        XCTAssertTrue(app.buttons["host-tab-info"].isSelected)
        XCTAssertTrue(app.staticTexts["developer"].isHittable, "信息 scrolled into view")
        let scroll = app.scrollViews["host-detail-scroll"]
        for _ in 0..<3 { scroll.swipeDown() }
        sleep(1)
        XCTAssertTrue(app.buttons["host-tab-overview"].isSelected, "Scrolling back to the top selects 概览")
        for _ in 0..<3 { scroll.swipeUp() }
        sleep(1)
        XCTAssertTrue(app.buttons["host-tab-info"].isSelected, "Scrolling to the end selects 信息")
        capture("Host detail — landscape info")
        back.tap()
        XCTAssertTrue(app.buttons["add-host"].waitForExistence(timeout: 3))
    }
    func testLiveTrustTerminalOutputAndSFTPPreview() throws { try openLivePreview(preferMosh: false) }
    func testShareExtensionQueuesDownloadedFile() throws {
        try openLivePreview(preferMosh: true)
        app.buttons["preview-download"].tap()
        let share = app.buttons["transfer-share-roamtty-ui-preview.txt"]
        XCTAssertTrue(share.waitForExistence(timeout: 20)); share.tap()
        let target = app.cells.matching(NSPredicate(format: "label == 'Roamtty'")).firstMatch
        if !target.waitForExistence(timeout: 4) {
            let more = app.cells.matching(NSPredicate(format: "label == 'More' OR label == '更多' OR label == 'More…'")).firstMatch
            if more.exists { more.tap() }
        }
        guard target.waitForExistence(timeout: 5) else {
            let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "Share activity hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Share activity"; screenshot.lifetime = .keepAlways; add(screenshot)
            XCTFail("Installed Roamtty share activity is missing from the share sheet")
            return
        }
        target.tap()
        let save = app.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        waitForExpectations(timeout: 15)
        // Close transfer and preview sheets before the queued share chooses its destination.
        for identifier in ["transfer-done", "preview-done"] {
            let done = app.buttons[identifier]
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        }
        // Re-entering foreground consumes the shared queue using the app's normal lifecycle.
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.navigationBars["共享文件"].waitForExistence(timeout: 10))
        let destinationHost = app.buttons["share-host-ui-live-host"]
        XCTAssertTrue(destinationHost.exists); destinationHost.tap()
        let destination = app.textFields["files-upload-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        replace(destination, with: shareDestination)
        XCTAssertEqual(destination.value as? String, shareDestination)
        let filename = app.textFields["files-upload-name-0"]
        XCTAssertTrue(filename.exists)
        replace(filename, with: "roamtty-ui-preview.txt")
        XCTAssertEqual(filename.value as? String, "roamtty-ui-preview.txt")
        let startUpload = app.buttons["files-start-upload"]
        XCTAssertTrue(startUpload.exists); startUpload.tap()
        let uploaded = app.staticTexts["transfer-status-upload-roamtty-ui-preview.txt"]
        let appeared = uploaded.waitForExistence(timeout: 20)
        let failure = app.staticTexts["files-upload-error"]
        XCTAssertTrue(appeared, failure.exists ? failure.label : "The upload must create its transfer job")
        expectation(for: NSPredicate(format: "label == %@", "已完成"), evaluatedWith: uploaded)
        waitForExpectations(timeout: 20)
    }
    private func openLivePreview(preferMosh: Bool) throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_HOST"] != nil else { throw XCTSkip("Set ROAMTTY_TEST_HOST, PORT, USERNAME and PASSWORD to exercise a real SSH server") }
        showHostsTab()
        let host = app.buttons["host-UI Live Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5)); host.tap()
        let trust = app.buttons["auth-confirm"]
        XCTAssertTrue(trust.waitForExistence(timeout: 15)); trust.tap()
        let disk = app.descendants(matching: .any)["host-gauge-disk"].firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        capture("Live host metrics")
        let terminal = app.buttons["host-detail-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10)); terminal.tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 20))
        let directory = app.textFields["launch-directory"]
        replace(directory, with: "/tmp")
        directory.typeText("\n")
        let mosh = app.switches["launch-mosh"]
        XCTAssertTrue(mosh.waitForExistence(timeout: 5))
        if (mosh.value as? String == "1") != preferMosh {
            mosh.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        XCTAssertEqual(mosh.value as? String, preferMosh ? "1" : "0")
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: launch)
        waitForExpectations(timeout: 25)
        launch.tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let connected = phase("已连接")
        XCTAssertTrue(connected.waitForExistence(timeout: 20))
        XCTAssertTrue(terminalTransport.hasPrefix("tmux"))
        XCTAssertEqual(terminalTransport.hasSuffix("mosh"), preferMosh)
        let ghost = app.buttons["terminal-ghost"]
        if !preferMosh {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: ghost)
            waitForExpectations(timeout: 7)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
            XCTAssertTrue(ghost.waitForExistence(timeout: 3))
            let escape = app.buttons["cursor-escape"]
            XCTAssertTrue(escape.exists)
            XCTAssertFalse(ghost.frame.intersects(escape.frame))
            ghost.press(forDuration: 0.4)
            let functions = app.buttons["pet-fn"]
            XCTAssertTrue(functions.waitForExistence(timeout: 3))
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: functions)
            waitForExpectations(timeout: 6)
        }
        shareDestination = "/tmp/roamtty-ios-ui-upload-" + UUID().uuidString
        // swiftlint:disable:next line_length - one shell command line typed into the terminal
        try runCommand("test \"$PWD\" = /tmp && { printf 'ROAMTTY_UI_'; printf 'VERIFIED\\n'; }; mkdir -m 700 " + shareDestination + "; printf 'ROAMTTY_SFTP_PREVIEW\\n' > \"$HOME/roamtty-ui-preview.txt\"")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "ROAMTTY_UI_VERIFIED"), evaluatedWith: surface)
        waitForExpectations(timeout: 20)
        let terminalScreenshot = XCTAttachment(screenshot: app.screenshot()); terminalScreenshot.name = "Live terminal output"; terminalScreenshot.lifetime = .keepAlways; add(terminalScreenshot)
        leaveTerminal()
        XCTAssertTrue(app.buttons["host-detail-files"].waitForExistence(timeout: 5)); app.buttons["host-detail-files"].tap()
        let previewFile = app.buttons.containing(.staticText, identifier: "roamtty-ui-preview.txt").firstMatch
        XCTAssertTrue(previewFile.waitForExistence(timeout: 20)); previewFile.tap()
        let preview = app.textViews["file-code-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue((preview.value as? String ?? "").contains("ROAMTTY_SFTP_PREVIEW"))
        let previewScreenshot = XCTAttachment(screenshot: app.screenshot()); previewScreenshot.name = "SFTP file preview"; previewScreenshot.lifetime = .keepAlways; add(previewScreenshot)
    }
    func testDrawerProvidesSettingsAndLanguageUpdatesImmediately() {
        app.buttons["open-drawer"].tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["language-en"].waitForExistence(timeout: 3))
        app.buttons["language-en"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 2))
        app.buttons["theme-light"].tap()
        app.buttons["settings-done"].tap()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "Hosts")
        capture("Host home — light English")
    }
}
