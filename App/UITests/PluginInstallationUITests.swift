import XCTest

/// These hosts are disposable Debian containers with genuine apt, sudo and
/// OpenSSH. Neither plugin is present initially; no package-manager stub is used.
final class PluginInstallationUITests: RoamttyLiveUITestCase {
    func testInteractiveLoginSudoRetryInstallsRealTmuxAndReprobes() throws {
        let fixture = try configuration()
        try createInteractiveHost(fixture, cancel: false)
        openPlugins()
        requestTmuxInstallation()
        answerSudo(fixture.password)

        let log = app.staticTexts["plugin-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 30), "apt must produce installation output")
        let installed = app.descendants(matching: .any)["plugin-installed-tmux"].firstMatch
        XCTAssertTrue(installed.waitForExistence(timeout: 180), "The real install and subsequent executable probe must both finish")
        XCTAssertTrue(log.label.contains("Setting up tmux"), "The log must include the real Debian package installation")
        let result = app.staticTexts["plugin-result"]
        XCTAssertTrue(result.label.contains("安装完成") || result.label.contains("was installed"))
        XCTAssertFalse(app.buttons["plugin-install-tmux"].exists)
        capture("Real apt installation completes after an explicit memory-only sudo password")
        app.buttons["plugins-done"].tap()

        // This normal fixture intentionally refuses SFTP. Directory validation
        // and launch must therefore use the production SSH shell fallback.
        let surface = try openInteractiveTerminal(mode: "tmux", password: fixture.password, expectedDefault: "tmux")
        let token = nonce(), verified = "PLUGIN_TMUX_EXECUTABLE_" + token
        // An installed badge alone cannot satisfy this: execute the newly
        // installed binary on the fixture and independently validate its version.
        let command = "test \"$PWD\" = /tmp && v=$(tmux -V) && case \"$v\" in 'tmux '[0-9]*) " + emit(verified)
            + ";; *) false;; esac; printf 'PLUGIN_VERSION_%s:%s:END\\n' '" + token + "' \"$v\""
        try runCommand(command)
        waitForOutput(verified, surface: surface)
        waitForOutput("PLUGIN_VERSION_" + token + ":tmux ", surface: surface)
        capture("Newly installed tmux reports its actual remote version")
        closePluginTerminal()
    }

    func testCancellingStreamingAptKeepsBothSSHConnectionsUsable() throws {
        let fixture = try configuration()
        let normal = try openTerminal(mode: "SSH")
        let token = nonce(), initial = "PLUGIN_OTHER_READY_" + token
        try runCommand("export ROAMTTY_PLUGIN_UI='" + token + "'; " + emit(initial))
        waitForOutput(initial, surface: normal)
        returnToHost()
        let card = homeSessionCards().firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let originalCardID = card.identifier

        try createInteractiveHost(fixture, cancel: true)
        openPlugins()
        requestTmuxInstallation()
        answerSudo(fixture.password)
        let log = app.staticTexts["plugin-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 30))
        let realDownload = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Get:'"), object: log)
        XCTAssertEqual(XCTWaiter.wait(for: [realDownload], timeout: 30), .completed, "Wait for real apt network output before cancellation")
        XCTAssertTrue(app.progressIndicators["plugin-progress"].exists || app.descendants(matching: .any)["plugin-progress"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["plugin-installed-tmux"].firstMatch.exists)
        capture("Genuine throttled apt download is still streaming before cancellation")

        // Done is the current public cancellation action; disappearing cancels
        // this installation and must not poison the cached SSH session.
        app.buttons["plugins-done"].tap()
        XCTAssertTrue(app.buttons["host-detail-menu"].waitForExistence(timeout: 8))
        openPlugins()
        let install = app.buttons["plugin-install-tmux"]
        waitEnabled(install)
        let probe = app.buttons["host-plugins-retry"]
        reveal(probe); XCTAssertTrue(probe.isEnabled); probe.tap()
        waitEnabled(install)
        XCTAssertFalse(app.descendants(matching: .any)["plugin-installed-tmux"].firstMatch.exists)
        app.buttons["plugins-done"].tap()
        let cancelledHost = try openInteractiveTerminal(mode: "SSH", password: fixture.password)
        let reusable = "PLUGIN_CANCEL_SSH_REUSED_" + token
        // A closed sheet and reusable SSH channel are insufficient: E2 left the
        // real privileged apt process downloading. Match Linux process names
        // exactly, without depending on pgrep/procps/Python or matching this
        // command's own argv, and allow at most ten seconds for remote cleanup.
        let stopped = "apt_running() { for f in /proc/[0-9]*/comm; do "
            + "{ IFS= read -r apt_name < \"$f\"; } 2>/dev/null || continue; "
            + "[ \"$apt_name\" = apt-get ] && return 0; done; return 1; }; "
            + "waited=0; while [ \"$waited\" -lt 10 ] && apt_running; do sleep 1; waited=$((waited+1)); done; "
            + "test -r /proc/1/comm && ! apt_running && ! command -v tmux >/dev/null 2>&1 && " + emit(reusable)
        try runCommand(stopped)
        waitForOutput(reusable, surface: cancelledHost, timeout: 20)
        capture("Remote apt has stopped, tmux remains absent and SSH is reusable")
        closePluginTerminal()
        returnHome()

        let original = homeSessionCards()[originalCardID]
        XCTAssertTrue(original.waitForExistence(timeout: 8))
        XCTAssertTrue(sessionConnected(originalCardID))
        original.tap()
        let preserved = "PLUGIN_OTHER_PRESERVED_" + token
        let surface = try runCommand("test \"$ROAMTTY_PLUGIN_UI\" = '" + token + "' && " + emit(preserved))
        waitForOutput(preserved, surface: surface)
        capture("Cancelling another host's install preserves the original shell and its state")
        closePluginTerminal()
    }

    private struct Configuration {
        let host, port, cancelPort, fingerprint, cancelFingerprint, username, password: String
    }

    private func configuration() throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["ROAMTTY_PLUGIN_HOST", "ROAMTTY_PLUGIN_PORT", "ROAMTTY_PLUGIN_CANCEL_PORT",
                    "ROAMTTY_PLUGIN_FINGERPRINT", "ROAMTTY_PLUGIN_CANCEL_FINGERPRINT",
                    "ROAMTTY_TEST_USERNAME", "ROAMTTY_TEST_PASSWORD"]
        let values = try keys.map { key in
            try XCTUnwrap(environment[key].flatMap { $0.isEmpty ? nil : $0 }, "Missing real plugin fixture setting: " + key)
        }
        return Configuration(host: values[0], port: values[1], cancelPort: values[2],
                             fingerprint: values[3], cancelFingerprint: values[4], username: values[5], password: values[6])
    }

    private func openInteractiveTerminal(mode: String, password: String, expectedDefault: String? = nil) throws -> XCUIElement {
        let terminal = app.buttons["host-detail-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8)); terminal.tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 20))
        let folder = app.textFields["launch-directory"]
        replace(folder, with: "/tmp"); folder.typeText("\n")
        waitEnabled(launch)
        let modes = app.segmentedControls["launch-mode"]
        if let expectedDefault {
            XCTAssertTrue(modes.buttons[expectedDefault].isSelected, "The completed live plugin probe must determine the initial session mode")
        }
        modes.buttons[mode].tap()
        let mosh = app.switches["launch-mosh"]
        XCTAssertTrue(mosh.waitForExistence(timeout: 5))
        if mosh.value as? String == "1" { mosh.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(mosh.value as? String, "0")
        waitEnabled(launch); launch.tap()

        // The terminal owns a fresh SSH connection. The server must issue its
        // actual challenge again; a monitor's interactive answer is not saved.
        let challenge = app.secureTextFields["auth-field-0"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists, "The already approved pin should authenticate the same endpoint")
        challenge.tap(); challenge.typeText(password); app.buttons["auth-confirm"].tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        return surface
    }

    private func createInteractiveHost(_ fixture: Configuration, cancel: Bool) throws {
        let name = "UI Plugin " + (cancel ? "Cancel " : "Install ") + String(nonce().prefix(8))
        let add = addHostButton
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        for (identifier, value) in [("host-name", name), ("host-address", fixture.host),
                                    ("host-port", cancel ? fixture.cancelPort : fixture.port), ("host-username", fixture.username)] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); reveal(field); replace(field, with: value)
        }
        let picker = app.segmentedControls["host-auth-method"]
        reveal(picker)
        let interactive = picker.buttons.matching(NSPredicate(format: "label == 'Interactive' OR label == '交互式认证'")).firstMatch
        XCTAssertTrue(interactive.exists); interactive.tap(); XCTAssertTrue(interactive.isSelected)
        XCTAssertFalse(app.secureTextFields["host-password"].exists)
        app.buttons["save-host"].tap()
        let row = app.buttons["host-" + name]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        let fingerprint = app.staticTexts["auth-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        XCTAssertEqual(fingerprint.label, cancel ? fixture.cancelFingerprint : fixture.fingerprint)
        app.buttons["auth-confirm"].tap()
        let challenge = app.secureTextFields["auth-field-0"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 15))
        challenge.tap(); challenge.typeText(fixture.password); app.buttons["auth-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["auth-confirm"].exists)
    }

    private func openPlugins() {
        hostMenu("host-detail-plugins")
        waitEnabled(app.buttons["plugin-install-tmux"])
    }

    private func requestTmuxInstallation() {
        app.buttons["plugin-install-tmux"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "(label == '安装' OR label == 'Install') AND identifier != 'plugin-install-tmux' AND identifier != 'plugin-install-mosh'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let password = app.secureTextFields["plugin-sudo-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20), "Interactive SSH answers must not be reused as a cached sudo password")
        let result = app.staticTexts["plugin-result"]
        XCTAssertTrue(result.label.contains("sudo"))
        XCTAssertFalse(app.buttons["plugin-sudo-retry"].isEnabled)
    }

    private func answerSudo(_ value: String) {
        let password = app.secureTextFields["plugin-sudo-password"]
        reveal(password); password.tap(); password.typeText(value)
        let retry = app.buttons["plugin-sudo-retry"]
        XCTAssertTrue(retry.isEnabled); retry.tap()
    }

    private func waitEnabled(_ element: XCUIElement, timeout: Double = 25) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.midY < scroll.frame.midY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func returnToHost() { leaveTerminal() }

    private func returnHome() {
        if app.navigationBars.buttons.count > 0 && !app.buttons["home-tab-hosts"].exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 8))
    }

    private func closePluginTerminal() {
        closeTerminal()
    }

    private func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func emit(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "{ printf '%s' '" + String(marker[..<split]) + "'; printf '%s\\n' '" + String(marker[split...]) + "'; }"
    }
}
