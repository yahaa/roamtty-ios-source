import Foundation
import XCTest

final class SessionCapacityUITests: RoamttyLiveUITestCase {
    private struct OwnedSession {
        let cardID: String
        let token: String
    }

    func testEightSessionsStayIsolatedAndForceDeleteEndsRemoteTmux() throws {
        try openHost()
        let runID = nonce()
        var sessions: [OwnedSession] = []
        var remoteTmux: String?

        for index in 0..<8 {
            let before = try homeSessionIDs()
            try openHost()
            let surface = try openTerminal(preferMosh: false, mode: index == 0 ? "tmux" : "SSH")
            let token = runID + "_" + String(index)
            let ready = "CAPACITY_READY_" + nonce()
            var command = "export ROAMTTY_UI_CAPACITY=" + quote(token)
            if index == 0 {
                // Discover the actual session name through this terminal, then mark only that owned tmux session.
                command += "; owned=$(tmux display-message -p -t \"$TMUX_PANE\" '#{session_name}')"
                    + " && tmux set-environment -t \"=$owned\" ROAMTTY_UI_CAPACITY \"$ROAMTTY_UI_CAPACITY\""
                    + " && { printf 'CAPACITY_TMUX_'; printf " + quote(runID + ":%s:END\\n") + " \"$owned\"; }"
            }
            command += " && " + emit(ready)
            try runCommand(command)
            waitForOutput(ready, surface: surface)
            if index == 0 { remoteTmux = try tmuxName(from: surface, runID: runID) }
            leaveTerminal()
            let after = try homeSessionIDs()
            XCTAssertEqual(after.count, index + 1, "Every successful launch must add one session card")
            XCTAssertTrue(before.isSubset(of: after), "Launching a session must retain existing cards")
            let added = after.subtracting(before)
            XCTAssertEqual(added.count, 1)
            let cardID = try XCTUnwrap(added.first)
            sessions.append(OwnedSession(cardID: cardID, token: token))
            waitFor(NSPredicate(format: "label CONTAINS '已连接' OR label CONTAINS 'Connected'"), element: status(cardID))
        }
        let eightIDs = Set(sessions.map(\.cardID))
        XCTAssertEqual(eightIDs.count, 8)
        capture("Eight independent connected session cards")

        try openHost()
        app.buttons["host-detail-terminal"].tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15))
        waitFor(NSPredicate(format: "isEnabled == true"), element: launch, timeout: 20)
        launch.tap()
        let limit = app.alerts.firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 8), "A ninth session must report the per-host limit")
        XCTAssertTrue(limit.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Maximum 8 sessions per host' OR label CONTAINS '每台主机最多 8 个会话'")).firstMatch.exists)
        let acknowledge = limit.buttons.matching(NSPredicate(format: "label == '好' OR label == 'OK'")).firstMatch
        XCTAssertTrue(acknowledge.exists); acknowledge.tap()
        waitFor(NSPredicate(format: "exists == false"), element: limit)
        XCTAssertEqual(try homeSessionIDs(), eightIDs, "The rejected ninth launch must not alter any session card")

        // Each fresh marker requires its own remote variable to match, so shared shell state or old scrollback cannot
        // satisfy these checks.
        for session in sessions.reversed() {
            try openCard(session.cardID)
            let isolated = "CAPACITY_ISOLATED_" + nonce()
            let surface = try runCommand("test \"$ROAMTTY_UI_CAPACITY\" = " + quote(session.token) + " && " + emit(isolated))
            waitForOutput(isolated, surface: surface)
            // Detaching leaves the tmux card disconnected, the state 强制删除 is offered in.
            if session.cardID == sessions[0].cardID {
                try runCommand("tmux detach-client")
                let back = app.buttons["terminal-leave"]
                XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
            } else { leaveTerminal() }
        }

        let tmux = sessions[0]
        let name = try XCTUnwrap(remoteTmux)
        XCTAssertEqual(try homeSessionIDs(), eightIDs, "A detached tmux session keeps its card")
        waitFor(NSPredicate(format: "label CONTAINS '已断开' OR label CONTAINS 'Disconnected' OR label CONTAINS '离线' OR label CONTAINS 'Offline'"), element: status(tmux.cardID), timeout: 15)
        let card = app.descendants(matching: .any)[tmux.cardID].firstMatch
        card.press(forDuration: 1.0)
        let forget = app.buttons["home-session-forget-" + String(tmux.cardID.dropFirst("home-session-".count))]
        XCTAssertTrue(forget.waitForExistence(timeout: 5)); forget.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '删除' OR label == 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        waitFor(NSPredicate(format: "exists == false"), element: card)
        XCTAssertEqual(try homeSessionIDs(), eightIDs.subtracting([tmux.cardID]))

        // The card goes first and the session ends over a login of its own, so give the server a moment.
        try openCard(sessions[1].cardID)
        let removed = "CAPACITY_TMUX_REMOVED_" + nonce()
        let target = quote("=" + name)
        let check = "for i in $(seq 1 40); do tmux has-session -t " + target + " 2>/dev/null || break; sleep 0.5; done; "
            + "! tmux has-session -t " + target + " 2>/dev/null && " + emit(removed)
        let surface = try runCommand(check)
        waitForOutput(removed, surface: surface)
        capture("Force-deleted card also ends its exact remote tmux session")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Ending the remote session must report no failure")
        leaveTerminal()

        // Close the SSH connections created by this case; closing asks nothing.
        for cardID in try homeSessionIDs().sorted() {
            try openCard(cardID)
            closeTerminal()
            waitFor(NSPredicate(format: "exists == false"), element: app.descendants(matching: .any)[cardID].firstMatch)
        }
        XCTAssertEqual(try homeSessionIDs().count, 0)
    }

    /// The session cards on the home sessions tab, reached back from wherever the test is.
    private func homeSessionIDs() throws -> Set<String> {
        for _ in 0..<3 where !app.buttons["home-tab-sessions"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        showSessionsTab()
        _ = app.buttons["add-session"].waitForExistence(timeout: 5)
        return Set(sessionCards.allElementsBoundByIndex.map(\.identifier))
    }

    private func status(_ cardID: String) -> XCUIElement {
        app.descendants(matching: .any)["home-session-status-" + String(cardID.dropFirst("home-session-".count))].firstMatch
    }

    private func openCard(_ cardID: String) throws {
        _ = try homeSessionIDs()
        let card = app.descendants(matching: .any)[cardID].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10))
        waitForConnected(timeout: 25)
    }

    private func waitFor(_ predicate: NSPredicate, element: XCUIElement, timeout: Double = 8) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: timeout), .completed)
    }

    private func tmuxName(from surface: XCUIElement, runID: String) throws -> String {
        let text = (surface.value as? String ?? "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let pattern = NSRegularExpression.escapedPattern(for: "CAPACITY_TMUX_" + runID + ":") + "(roamtty-[A-Fa-f0-9]{12}):END"
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "The real tmux shell must report its owned session name")
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return String(text[range])
    }

    private func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func emit(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "{ printf '%s' " + quote(String(marker[..<split])) + "; printf '%s\\n' " + quote(String(marker[split...])) + "; }"
    }
}
