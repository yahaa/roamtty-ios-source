import XCTest

final class NavigationUITests: RoamttyLiveUITestCase {
    func testHostSearchEditDeleteAndOfflineStatusPersist() {
        let suffix = String(UUID().uuidString.prefix(6))
        let name = "Navigation " + suffix
        let username = "offline_" + suffix.lowercased()
        openEditor(name: name, username: username, port: "1")
        app.buttons["save-host"].tap()
        let card = app.buttons["host-" + name]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        waitFor(NSPredicate(format: "label CONTAINS '离线' OR label CONTAINS 'Offline'"), element: status(of: card), timeout: 10)

        app.buttons["search-hosts"].tap()
        let search = app.textFields["host-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        let liveAddress = ProcessInfo.processInfo.environment["ROAMTTY_TEST_HOST"]
        for query in [name.uppercased(), "127.0.0.1", username] {
            replace(search, with: query)
            XCTAssertTrue(card.exists, "Host search must match name, address and username")
            // A fixture served on loopback shares this address, and then the live host rightly matches too.
            if query != liveAddress { XCTAssertFalse(app.buttons["host-UI Live Host"].exists) }
        }
        replace(search, with: "no-such-host-" + suffix)
        XCTAssertFalse(card.exists)
        XCTAssertFalse(app.buttons["host-UI Live Host"].exists)
        app.buttons["host-search-close"].tap()
        XCTAssertFalse(search.exists)
        XCTAssertTrue(card.waitForExistence(timeout: 3)); card.tap()

        hostMenu("host-detail-edit")
        let edited = "Edited " + suffix
        replace(app.textFields["host-name"], with: edited)
        replace(app.textFields["host-username"], with: "changed_" + suffix.lowercased())
        let mode = app.segmentedControls["host-session-mode"]
        let ssh = mode.buttons["普通 SSH"]
        reveal(ssh, in: app.scrollViews["host-editor-scroll"])
        ssh.tap()
        XCTAssertTrue(ssh.isSelected)
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.navigationBars[edited].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["host-" + name].exists)
        XCTAssertTrue(app.buttons["host-" + edited].waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        showHostsTab()
        let saved = app.buttons["host-" + edited]
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(saved.label.contains("changed_" + suffix.lowercased()))
        // Cards show installed plugins; an unprobed host shows tmux only in tmux mode, so plain SSH drops it.
        XCTAssertFalse(saved.label.contains("tmux"), "The plain SSH mode must persist")
        waitFor(NSPredicate(format: "label CONTAINS '离线' OR label CONTAINS 'Offline'"), element: status(of: saved), timeout: 10)
        capture("Edited offline host persisted after relaunch")
        saved.tap()

        openDeleteConfirmation()
        let cancel = app.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // iOS 26 presents this confirmation as a popover without a Cancel
            // button. Its native cancellation gesture is a tap outside it;
            // the lower host-information rows have no action to invoke.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
        waitFor(NSPredicate(format: "exists == false"), element: app.buttons.matching(identifier: "host-delete-confirm").firstMatch, timeout: 3)
        XCTAssertTrue(app.navigationBars[edited].exists, "Cancelling deletion must retain the host")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 3), "Cancelling deletion must retain the saved host card")
        capture("Native deletion cancellation retains the host")
        saved.tap()
        openDeleteConfirmation()
        app.buttons.matching(identifier: "host-delete-confirm").firstMatch.tap()
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["host-" + edited].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["host-" + edited].exists, "Deletion must survive an app restart")
    }

    func testInvalidPortsKeepEditorOpenAndCancelDiscardsDraft() {
        let name = "Unsaved " + String(UUID().uuidString.prefix(6))
        openEditor(name: name, username: "offline", port: "0")
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.staticTexts["editor-error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["host-name"].exists)
        replace(app.textFields["host-port"], with: "65536")
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.staticTexts["editor-error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["cancel-host-editor"].exists)
        app.buttons["cancel-host-editor"].tap()
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["host-" + name].exists)
        addHostButton.tap()
        XCTAssertTrue(app.textFields["host-name"].waitForExistence(timeout: 3))
        XCTAssertNotEqual(app.textFields["host-name"].value as? String, name)
        XCTAssertEqual(app.textFields["host-port"].value as? String, "22")
        app.buttons["cancel-host-editor"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["host-" + name].exists)
    }

    func testGuideAboutAndDrawerReturnUseSelectedLanguage() {
        openDrawerItem("open-settings")
        XCTAssertTrue(app.buttons["language-en"].waitForExistence(timeout: 5)); app.buttons["language-en"].tap()
        app.buttons["settings-done"].tap()
        openDrawerItem("open-guide")
        XCTAssertTrue(app.navigationBars["Guide"].waitForExistence(timeout: 5))
        let guide = app.scrollViews["guide-scroll"]
        for title in ["Connect a host", "Sessions and AI agents", "Terminal gestures", "Transfer files"] {
            let section = app.staticTexts[title]
            reveal(section, in: guide)
            XCTAssertTrue(section.isHittable)
        }
        let downloads = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Roamtty/Downloads")).firstMatch
        XCTAssertTrue(downloads.exists)
        capture("Guide in English")
        app.buttons["guide-done"].tap()

        openDrawerItem("open-about")
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        let about = app.scrollViews["about-scroll"]
        reveal(app.staticTexts["Privacy"], in: about)
        let privacy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "device-only Keychain")).firstMatch
        XCTAssertTrue(privacy.exists)
        reveal(app.staticTexts["Open source"], in: about)
        let licenses = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SwiftTerm · MIT")).firstMatch
        XCTAssertTrue(licenses.exists)
        XCTAssertTrue(licenses.label.contains("libssh2 · BSD"))
        capture("About privacy and open-source notices")
        app.buttons["about-done"].tap()
        openDrawerItem("drawer-hosts")
        XCTAssertTrue(addHostButton.isHittable)
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "Hosts")
        XCTAssertFalse(app.buttons["open-guide"].exists, "Selecting Hosts must close the drawer")

        openDrawerItem("open-settings")
        app.buttons["language-zh"].tap(); app.buttons["settings-done"].tap()
        openDrawerItem("open-guide")
        XCTAssertTrue(app.navigationBars["使用指南"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["连接主机"].exists)
        app.buttons["guide-done"].tap()
        XCTAssertEqual(app.buttons["home-tab-hosts"].label, "主机")
    }

    private func openEditor(name: String, username: String, port: String) {
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 8)); addHostButton.tap()
        for (identifier, value) in [("host-name", name), ("host-address", "127.0.0.1"), ("host-port", port), ("host-username", username)] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            reveal(field, in: app.scrollViews["host-editor-scroll"])
            replace(field, with: value)
        }
    }

    private func openDeleteConfirmation() {
        let menu = app.buttons["host-detail-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
        let delete = app.buttons["host-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3)); delete.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "host-delete-confirm").firstMatch.waitForExistence(timeout: 3))
    }

    private func openDrawerItem(_ identifier: String) {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 5)); app.buttons["open-drawer"].tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 3)); item.tap()
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        for attempt in 0...6 {
            // The scroll view's accessibility frame can extend behind the
            // software keyboard. Keep both touch points in visible content.
            let frame = scroll.frame.intersection(app.frame)
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
            let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
            if element.exists && element.isHittable && visible.contains(element.frame) { return }
            guard attempt < 6 else {
                XCTFail("The control did not become visible above the keyboard: \(element.frame) hittable \(element.isHittable), "
                        + "visible \(visible), keyboard \(keyboard.exists) keys \(app.keys.count)")
                return
            }
            XCTAssertGreaterThan(bottom - top, 80)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.midX, dy: top + visible.height * 0.75)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: top + visible.height * 0.15)))
        }
    }

    /// The card's reachability pill sits beside its button; both are keyed by the host id the login line carries.
    private func status(of card: XCUIElement) -> XCUIElement {
        let login = card.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'host-login-'")).firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        return app.descendants(matching: .any)["host-status-" + login.identifier.dropFirst("host-login-".count)]
    }

    private func waitFor(_ predicate: NSPredicate, element: XCUIElement, timeout: Double,
                         file: StaticString = #filePath, line: UInt = #line) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: timeout), .completed, file: file, line: line)
    }
}
