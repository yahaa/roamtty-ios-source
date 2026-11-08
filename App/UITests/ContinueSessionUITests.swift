import XCTest

final class ContinueSessionUITests: RoamttyLiveUITestCase {
    /// 新建会话 › 继续会话 lists the tmux sessions on the one host; picking one and 打开会话 attaches it, and opening it
    /// again opens the card it already has instead of a second one. The host page has no 继续.
    func testContinueSessionAttachesARunningTmuxSession() throws {
        let name = "roamtty-ui-continue-" + UUID().uuidString.prefix(8).lowercased()
        let surface = try openTerminal()
        let created = "CONTINUE_" + "CREATED"
        try runCommand("tmux new-session -d -s \(name) -c /tmp && printf '%s\\n' '\(created)'")
        waitForOutput(created, surface: surface)
        leaveTerminal()
        let before = Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(before.count, 1)

        openContinueSheet()
        let row = app.buttons["continue-tmux-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The detached session is listed")
        row.tap()
        let attach = app.buttons["continue-attach"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: attach)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(attach.label, "打开会话")
        capture("继续会话 lists the running tmux sessions")
        attach.tap()
        let attached = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(attached.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        try runCommand("tmux display-message -p 'ATTACHED_#S'")
        waitForOutput("ATTACHED_" + name, surface: attached)
        leaveTerminal()
        let after = Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(after.count, 2, "Continuing a session adds its card")

        // Already open: the row is badged and opens that card, adding none.
        openContinueSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label == '已打开' OR label == 'Open'")).firstMatch.exists)
        row.tap(); app.buttons["continue-attach"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        let again = try runCommand("tmux display-message -p 'AGAIN_#S'")
        waitForOutput("AGAIN_" + name, surface: again)
        leaveTerminal()
        XCTAssertEqual(Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier)), after, "An open session is not attached twice")

        // The host page has no 继续 (it lives in 新建会话), and 打开终端 has no tmux tab.
        try openHost()
        for id in ["host-detail-agent", "host-detail-terminal", "host-detail-files"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is on screen")
        }
        XCTAssertFalse(app.buttons["host-detail-continue"].exists, "No 继续 on the host page")
        capture("The host page's actions")
        app.buttons["host-detail-terminal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["launch-folders"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.segmentedControls["launch-source"].exists, "Folders only")
        app.buttons["launch-cancel"].tap()

        openContinueSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap(); app.buttons["continue-attach"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        closeTerminal()
        XCTAssertEqual(Set(sessionCards.allElementsBoundByIndex.map(\.identifier)), before, "Closing ends the continued session's card only")
    }

    /// With only the fixture host saved, 继续会话 skips the host step.
    private func openContinueSheet() {
        showSessionsTab()
        let add = app.buttons["add-session"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        let pick = app.buttons["new-session-pick-continue"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        XCTAssertTrue(app.descendants(matching: .any)["continue-sheet"].firstMatch.waitForExistence(timeout: 5))
    }
}
