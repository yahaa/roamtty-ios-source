import XCTest

/// Uses the real host editor, trust policy, Keychain and SSH server. The encrypted
/// key is the Android transport fixture seeded into this simulator app's Documents.
final class AuthenticationUITests: RoamttyLiveUITestCase {
    func testUnsavedPasswordCancelCorrectionAndRelaunchRequireExplicitLogin() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = Fixture(host: try XCTUnwrap(environment["ROAMTTY_TEST_HOST"]),
                              port: environment["ROAMTTY_TEST_PORT"] ?? "22",
                              username: try XCTUnwrap(environment["ROAMTTY_TEST_USERNAME"]),
                              password: try XCTUnwrap(environment["ROAMTTY_TEST_PASSWORD"]))
        XCTAssertFalse(fixture.password.isEmpty, "This test requires the live fixture password")
        let name = "UI Unsaved Password " + String(UUID().uuidString.prefix(6))
        createHostEditor(name: name, fixture: fixture, method: "Password")
        let editorPassword = app.secureTextFields["host-password"]
        XCTAssertTrue(editorPassword.exists)
        let initial = editorPassword.value as? String ?? ""
        XCTAssertTrue(initial.isEmpty || initial == editorPassword.placeholderValue)
        XCTAssertEqual(app.switches["host-save-password"].value as? String, "0")
        saveAndOpenHost(name)

        let login = app.buttons["host-monitor-login"]
        XCTAssertTrue(login.waitForExistence(timeout: 5)); reveal(login); login.tap()
        let password = app.secureTextFields["auth-field-0"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["auth-title"].label, name)
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists, "The password request precedes the first network connection")
        app.buttons["auth-cancel"].tap()
        let retry = app.buttons["host-monitor-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        assertNoAutomaticAuthenticationPrompt()

        reveal(retry); retry.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        let wrongPassword = fixture.password == "roamtty-ui-wrong-password" ? "roamtty-ui-also-wrong" : "roamtty-ui-wrong-password"
        password.tap(); password.typeText(wrongPassword)
        // The password is hidden until asked for, then shown as typed, and hidden again (roamtty #277).
        let visibility = app.buttons["auth-field-0-visibility"]
        XCTAssertTrue(visibility.exists); XCTAssertEqual(visibility.label, "显示密码")
        visibility.tap()
        let shown = app.textFields["auth-field-0"]
        XCTAssertTrue(shown.waitForExistence(timeout: 3)); XCTAssertEqual(shown.value as? String, wrongPassword)
        XCTAssertEqual(visibility.label, "隐藏密码")
        visibility.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        app.buttons["auth-confirm"].tap()
        acceptFirstTrust()
        let status = app.staticTexts["host-monitor-status"]
        let rejected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '认证失败' OR label CONTAINS 'Authentication failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [rejected], timeout: 20), .completed, "The real server must reject the incorrect password")
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        assertNoAutomaticAuthenticationPrompt()

        reveal(retry); retry.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5), "Explicit retry must ask again rather than reuse the rejected password")
        password.tap(); password.typeText(fixture.password)
        app.buttons["auth-confirm"].tap()
        assertLiveMetrics()
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists)
        capture("Corrected one-time password reaches live metrics")

        app.terminate(); app.launch()
        showHostsTab()
        let host = app.buttons["host-" + name]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        XCTAssertTrue(login.waitForExistence(timeout: 5), "An unsaved password must not authenticate automatically after relaunch")
        XCTAssertFalse(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        reveal(login); login.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5), "The one-time password must not have been persisted")
        let freshValue = password.value as? String ?? ""
        XCTAssertTrue(freshValue.isEmpty || freshValue == password.placeholderValue)
        password.tap(); password.typeText(fixture.password)
        app.buttons["auth-confirm"].tap()
        assertLiveMetrics()
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists, "The accepted host pin should survive while the password does not")
    }

    func testInteractiveHostEditorAnswersActualServerChallenge() throws {
        let fixture = try credentials()
        let name = "UI Interactive " + String(UUID().uuidString.prefix(6))
        createHostEditor(name: name, fixture: fixture, method: "Interactive")
        XCTAssertFalse(app.secureTextFields["host-password"].exists)
        saveAndOpenHost(name)
        acceptFirstTrust()
        let challenge = app.secureTextFields["auth-field-0"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 15), "The real keyboard-interactive server must request its answer")
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists)
        challenge.tap(); challenge.typeText(fixture.password)
        app.buttons["auth-confirm"].tap()
        assertLiveMetrics()
        XCTAssertTrue(app.staticTexts["交互式认证"].exists || app.staticTexts["Interactive"].exists)
        capture("Keyboard-interactive authentication and live metrics")
    }

    func testEncryptedKeyImportsThroughFilesAndPromptsAgainAfterRelaunch() throws {
        let fixture = try credentials()
        let name = "UI Encrypted Key " + String(UUID().uuidString.prefix(6))
        createHostEditor(name: name, fixture: fixture, method: "Private key")
        let importKey = app.buttons["host-import-key"]
        reveal(importKey); importKey.tap()
        selectSeededKeyInFiles()
        XCTAssertTrue(importKey.waitForExistence(timeout: 8))
        XCTAssertTrue((importKey.value as? String ?? "").contains("roamtty-ui-encrypted-key"), "The native picker must return the seeded encrypted fixture")
        // Leave the editor's optional passphrase empty to exercise the real login prompt.
        let optionalPassphrase = app.secureTextFields["host-key-passphrase"]
        let displayedPassphrase = optionalPassphrase.value as? String ?? ""
        XCTAssertTrue(displayedPassphrase.isEmpty || displayedPassphrase == optionalPassphrase.placeholderValue)
        saveAndOpenHost(name)
        answerKeyPassphrase()
        acceptFirstTrust()
        assertLiveMetrics()

        // Hosts, imported key and trust survive. The passphrase must be requested
        // again because it lives only in the terminated process's memory.
        app.terminate(); app.launch()
        showHostsTab()
        let host = app.buttons["host-\(name)"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        answerKeyPassphrase()
        assertLiveMetrics()
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists, "The accepted host pin should survive relaunch")
        capture("Imported encrypted key reconnects after a fresh passphrase")
    }

    func testCancelFirstTrustRequiresExplicitRetryAndDoesNotSavePin() throws {
        _ = try credentials()
        showHostsTab()
        let host = app.buttons["host-UI Live Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        let fingerprint = app.staticTexts["auth-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        let firstFingerprint = fingerprint.label
        XCTAssertTrue(firstFingerprint.hasPrefix("SHA256:"))
        app.buttons["auth-cancel"].tap()
        let retry = app.buttons["host-monitor-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        XCTAssertFalse(fingerprint.waitForExistence(timeout: 2), "Rejecting trust must not trigger an automatic retry")
        reveal(retry); retry.tap()
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15), "A rejected fingerprint must not have been pinned")
        XCTAssertEqual(fingerprint.label, firstFingerprint)
        app.buttons["auth-confirm"].tap()
        assertLiveMetrics()
        capture("Explicit trust retry reaches live host metrics")
    }

    private struct Fixture {
        let host: String
        let port: String
        let username: String
        let password: String
    }

    private func credentials() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ROAMTTY_TEST_HOST"], let username = environment["ROAMTTY_TEST_USERNAME"],
              let password = environment["ROAMTTY_TEST_PASSWORD"], !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw XCTSkip("Set the dedicated live SSH fixture environment to exercise authentication UI")
        }
        return Fixture(host: host, port: environment["ROAMTTY_TEST_PORT"] ?? "22", username: username, password: password)
    }

    private func createHostEditor(name: String, fixture: Fixture, method: String) {
        let add = addHostButton
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        for (identifier, value) in [("host-name", name), ("host-address", fixture.host),
                                    ("host-port", fixture.port), ("host-username", fixture.username)] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 3)); reveal(field); replace(field, with: value)
        }
        let picker = app.segmentedControls["host-auth-method"]
        reveal(picker)
        let chinese: String
        switch method {
        case "Interactive": chinese = "交互式认证"
        case "Password": chinese = "密码"
        default: chinese = "私钥"
        }
        let option = picker.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", method, chinese)).firstMatch
        XCTAssertTrue(option.exists); option.tap()
        XCTAssertTrue(option.isSelected)
    }

    private func saveAndOpenHost(_ name: String) {
        app.buttons["save-host"].tap()
        let host = app.buttons["host-\(name)"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 8))
    }

    private func acceptFirstTrust() {
        let fingerprint = app.staticTexts["auth-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        XCTAssertTrue(fingerprint.label.hasPrefix("SHA256:"))
        app.buttons["auth-confirm"].tap()
    }

    private func answerKeyPassphrase() {
        let field = app.secureTextFields["auth-field-0"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "An encrypted imported key must request its passphrase")
        let message = app.staticTexts["auth-message"].label
        XCTAssertTrue(message.contains("口令") || message.contains("passphrase"))
        field.tap(); field.typeText("itermux-test-passphrase")
        app.buttons["auth-confirm"].tap()
    }

    private func assertLiveMetrics() {
        let memory = app.descendants(matching: .any)["host-gauge-memory"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 20), "A real authenticated metrics command must finish")
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-disk"].firstMatch.exists)
        XCTAssertFalse(app.buttons["auth-confirm"].exists)
    }

    private func assertNoAutomaticAuthenticationPrompt() {
        let prompt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.buttons["auth-confirm"])
        prompt.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prompt], timeout: 3), .completed, "Cancelled or rejected authentication must wait for an explicit retry")
    }

    private func reveal(_ element: XCUIElement) {
        // The home pager behind the editor is a scroll view too: scroll the editor's own.
        let editor = app.scrollViews["host-editor-scroll"]
        let scroll = editor.exists ? editor : app.scrollViews.firstMatch
        for _ in 0..<5 {
            if element.isHittable { return }
            // Drag within the upper half: a swipe from the centre can start on the keyboard.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
        if !element.isHittable { saveFailureScreenshot("reveal") }
        XCTAssertTrue(element.isHittable)
    }

    private func selectSeededKeyInFiles() {
        let filename = "roamtty-ui-encrypted-key"
        func fixtureCell() -> XCUIElement {
            app.cells.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        }
        if fixtureCell().waitForExistence(timeout: 3) { fixtureCell().tap(); return }
        let browse = app.buttons.matching(NSPredicate(format: "label == 'Browse' OR label == '浏览'")).firstMatch
        if browse.exists { browse.tap() }
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS 'On My iPhone' OR label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone'")).firstMatch
        if local.waitForExistence(timeout: 3) { local.tap() }
        let roamtty = app.cells.matching(NSPredicate(format: "label == 'Roamtty' OR label BEGINSWITH 'Roamtty,'")).firstMatch
        if roamtty.waitForExistence(timeout: 3) { roamtty.tap() }
        let file = fixtureCell()
        XCTAssertTrue(file.waitForExistence(timeout: 8), "Seed Documents/roamtty-ui-encrypted-key.txt in the dedicated simulator before this test")
        file.tap()
    }
}
