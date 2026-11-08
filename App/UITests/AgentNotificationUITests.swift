import XCTest

/// The agent notifications against the live fixture: a stand-in agent in the tmux pane sets the options the hooks
/// set (`pane_current_command` is "claude" through `exec -a`), on a timer, while the test moves the app around.
final class AgentNotificationUITests: RoamttyLiveUITestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// A shell line that turns the pane into an agent running `steps`, each "seconds state tool detail worked reply"
    /// joined by `;` in the stand-in's own script. It reports work at once.
    private func agent(_ steps: [String]) -> String {
        let script = "p=$TMUX_PANE; o() { tmux set-option -q -t \"$p\" \"$@\"; }; " +
            "o -u @roamtty_worked; o -u @roamtty_reply; o @roamtty_task notify-test; " +
            "o @roamtty_agent \"working|$(date +%s)|claude|Bash|make\"; " + steps.joined(separator: "; ") + "; sleep 600"
        return "exec -a claude sh -c '" + script + "'"
    }
    private func after(_ seconds: Int, waiting detail: String) -> String {
        "sleep \(seconds); o @roamtty_agent \"waiting|$(date +%s)|claude|Bash|\(detail)\""
    }
    private func after(_ seconds: Int, working detail: String) -> String {
        "sleep \(seconds); o -u @roamtty_worked; o -u @roamtty_reply; o @roamtty_agent \"working|$(date +%s)|claude|Bash|\(detail)\""
    }
    private func after(_ seconds: Int, finished worked: Int, reply: String) -> String {
        "sleep \(seconds); o @roamtty_worked \(worked); o @roamtty_reply \(reply); o @roamtty_agent \"idle|$(date +%s)|claude||\""
    }

    /// iOS asks once whether the app may notify, when the first agent shows up; answered, it never asks again.
    private static var answered = false
    private func allowNotifications() {
        guard !Self.answered else { return }
        Self.answered = true
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 20) else { return }
        for title in ["Allow", "允许"] where alert.buttons[title].exists { alert.buttons[title].tap(); return }
    }

    /// A notification on the home screen, the lock screen or in Notification Center whose text contains `text`.
    private func springboardItem(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'NotificationShortLookView' AND label CONTAINS %@", text)).firstMatch
    }

    private func openNotificationCenter() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
    }
    private func closeNotificationCenter() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
    }

    func testARequestInTheBackgroundShowsABannerThatOpensItsSession() throws {
        let detail = "lint-" + String(UUID().uuidString.prefix(6))
        try openTerminal()
        try runCommand(agent([after(45, waiting: detail)]))
        allowNotifications()
        leaveTerminal()
        XCUIDevice.shared.press(.home)

        let banner = springboardItem(detail)
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "A request in the background shows a banner")
        // A banner stays only a few seconds: tap it first, check it after.
        let label = banner.label
        saveScreen("notify-waiting-banner")
        banner.tap()
        XCTAssertTrue(label.contains("Claude 等你确认"), label)
        XCTAssertTrue(label.contains("UI Live Host · " + detail), label)
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: surface)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "The banner opens the app on the session's terminal")
        saveScreen("notify-opened-session")
        closeTerminal()
    }

    func testOnlyALongTurnThatEndsOffScreenIsListed() throws {
        let token = String(UUID().uuidString.prefix(6))
        let watched = "watched-" + token, away = "away-" + token, short = "short-" + token
        try openTerminal()
        // A long turn ends on screen, then a short one and a long one after the user left the terminal. The last one
        // stays: the next turn would take its notification back. Each state lasts past a poll (every 3 seconds).
        try runCommand(agent([after(15, finished: 75, reply: watched), after(8, working: "make"),
                              after(8, finished: 20, reply: short), after(8, working: "make"), after(30, finished: 90, reply: away)]))
        allowNotifications()
        // The first turn ends while its terminal is on screen.
        sleep(20)
        leaveTerminal()
        sleep(52)

        XCUIDevice.shared.press(.home)
        openNotificationCenter()
        let listed = springboardItem(away)
        let found = listed.waitForExistence(timeout: 10)
        saveScreen("notify-done-center")
        XCTAssertTrue(found, "A long turn that ended off screen is listed")
        XCTAssertTrue(listed.label.contains("Claude 已完成"), listed.label)
        XCTAssertTrue(listed.label.contains("UI Live Host · 1 分钟 · " + away), listed.label)
        capture("Agent finished in Notification Center"); saveScreen("notify-done-listed")
        XCTAssertFalse(springboardItem(watched).exists, "A turn that ended on screen is not notified")
        XCTAssertFalse(springboardItem(short).exists, "A short turn is not notified")
        closeNotificationCenter()
        app.activate()
    }

    func testTheSettingChoosesWhichNotificationsCome() throws {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8)); app.buttons["open-drawer"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5)); app.buttons["open-settings"].tap()
        let all = app.buttons["settings-notify-all"], waitingOnly = app.buttons["settings-notify-waitingOnly"], off = app.buttons["settings-notify-off"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertTrue(all.isSelected); XCTAssertFalse(waitingOnly.isSelected); XCTAssertFalse(off.isSelected)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Agent 等你确认或做完一轮'")).firstMatch.exists)
        waitingOnly.tap()
        XCTAssertTrue(waitingOnly.isSelected); XCTAssertFalse(all.isSelected)
        capture("Notification setting"); saveScreen("notify-settings")
        app.buttons["settings-done"].tap()
        app.buttons["open-drawer"].tap(); app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-notify-waitingOnly"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-notify-waitingOnly"].isSelected, "The choice is kept")
        app.buttons["settings-done"].tap()
    }

    /// Also to the Mac's /tmp/roamtty-parity, for a look without the result bundle.
    private func saveScreen(_ name: String) {
        let directory = URL(fileURLWithPath: "/tmp/roamtty-parity")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
