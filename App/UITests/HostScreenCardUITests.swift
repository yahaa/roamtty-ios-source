import XCTest

/// Opt-in end-to-end screen-card parity check using an existing saved host, without changing its data.
final class HostScreenCardUITests: XCTestCase {
    func testRecentlyOpenedHostMovesFirstAndSurvivesRelaunch() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_HOST_CARD_FIXTURE"] == "1" else {
            throw XCTSkip("Requires isolated simulator host-card fixtures")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "HostCardRecency"
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        let pictured = app.buttons["host-screen-pictured"]
        let headless = app.buttons["host-screen-headless"]
        XCTAssertTrue(headless.waitForExistence(timeout: 10))
        XCTAssertLessThan(pictured.frame.minY, headless.frame.minY)

        // Opening a host is a user action; even an offline host should become easy to find again.
        headless.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let cancel = app.buttons["auth-cancel"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        back.tap()
        XCTAssertTrue(headless.waitForExistence(timeout: 10))
        XCTAssertLessThan(headless.frame.minY, pictured.frame.minY)

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        XCTAssertTrue(pictured.waitForExistence(timeout: 10))
        XCTAssertLessThan(headless.frame.minY, pictured.frame.minY)
        // Search preserves the same order; background reachability never promotes another host.
        app.buttons["search-hosts"].tap()
        let search = app.textFields["host-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText("fixture")
        XCTAssertLessThan(headless.frame.minY, pictured.frame.minY)
        app.buttons["host-search-close"].tap()
        capture(app, "Recently used host first after relaunch")
        app.terminate()
    }

    func testLivePreviewPersistsAndStripOpensDetails() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST to a saved desktop host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let hosts = app.buttons["home-tab-hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
        let strip = app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "host-" + host)).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        capture(app, "Screen cards before connecting")
        strip.tap()
        XCTAssertTrue(app.buttons["host-detail-desktop"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let screen = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-screen-' AND label CONTAINS[c] %@", host)).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10)); screen.tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        // Allow connection, capture cadence, and async JPEG write to complete.
        Thread.sleep(forTimeInterval: 30)
        XCTAssertEqual(app.state, .runningForeground)
        ops.tap()
        app.buttons["desktop-op-exit"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        let saved = NSPredicate(format: "value == '已保存桌面预览' OR value == 'Saved desktop preview'")
        expectation(for: saved, evaluatedWith: screen)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '已连接' OR label == 'Connected'")).firstMatch.exists)
        capture(app, "Connected host screen card with saved preview")
        // The strip must keep its detail action even when a desktop is running.
        strip.tap()
        XCTAssertTrue(app.buttons["host-detail-desktop"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        expectation(for: saved, evaluatedWith: screen)
        waitForExpectations(timeout: 15)
        capture(app, "Screen card preview after cold launch")
    }
    /// Simulator fixtures are seeded in isolated stores by the validation script, never in user data.
    func testOfflineAndHeadlessCardsOpenDetails() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_HOST_CARD_FIXTURE"] == "1" else {
            throw XCTSkip("Requires isolated simulator host-card fixtures")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        for theme in ["dark", "light"] {
            app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "HostCardParity-" + theme
            app.launch()
            let hosts = app.buttons["home-tab-hosts"]
            XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
            let headless = app.buttons["host-screen-headless"]
            XCTAssertTrue(headless.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
            XCTAssertTrue(app.staticTexts["tmux"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["mosh"].firstMatch.exists)
            // The fixture points to a closed loopback port. Wait for the real reachability probe.
            let offline = app.staticTexts["离线"].firstMatch
            XCTAssertTrue(offline.waitForExistence(timeout: 15))
            for id in ["pictured", "headless"] {
                let login = app.staticTexts["host-login-" + id]
                let status = app.descendants(matching: .any)["host-status-" + id].firstMatch
                XCTAssertTrue(login.exists)
                XCTAssertEqual(login.label, "fixture@127.0.0.1:9")
                XCTAssertTrue(status.exists)
                XCTAssertLessThan(status.frame.maxY, login.frame.minY, "Reachability belongs above the information strip")
            }
            Thread.sleep(forTimeInterval: 2)
            capture(app, "Offline preview and headless cards - " + theme)
            for id in ["pictured", "headless"] {
                app.buttons["host-screen-" + id].tap()
                XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch.exists)
                // The detail screen may ask for credentials to load its host monitor.
                let cancel = app.buttons["auth-cancel"]
                if cancel.waitForExistence(timeout: 3) { cancel.tap() }
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(headless.waitForExistence(timeout: 10))
            }
            // The flat home header keeps search and tab navigation working.
            app.buttons["search-hosts"].tap()
            let search = app.textFields["host-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.tap(); search.typeText("Ubuntu")
            XCTAssertTrue(app.buttons["host-screen-headless"].exists)
            XCTAssertFalse(app.buttons["host-screen-pictured"].exists)
            app.buttons["host-search-close"].tap()
            XCTAssertTrue(app.buttons["host-screen-pictured"].waitForExistence(timeout: 3))
            app.buttons["home-tab-sessions"].tap()
            XCTAssertTrue(app.buttons["home-tab-sessions"].isSelected)
            app.buttons["home-tab-hosts"].tap()
            XCTAssertTrue(headless.waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
