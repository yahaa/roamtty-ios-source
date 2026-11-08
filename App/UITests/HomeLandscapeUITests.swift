import XCTest

/// Android PR 222: every agent's card is as tall as the next, whatever it has to say, and in landscape the home page has
/// one short bar (tabs, filters, search, add) that slides away as the list scrolls on and comes back as it scrolls back.
/// The cards come from real agent hooks run in tmux panes of the live fixture.
final class HomeLandscapeUITests: RoamttyLiveUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private let hook = "sh ~/.roamtty/agent-hook.sh claude"

    /// Attaches the screen and keeps a copy under /tmp/roamtty-landscape for review.
    private func shot(_ name: String) {
        sleep(1)
        capture(name)
        let directory = URL(fileURLWithPath: "/tmp/roamtty-landscape")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Opens a tmux terminal in `folder` and runs `command` there, then goes back to the host page.
    private func session(_ folder: String, _ command: String) throws {
        _ = try openTerminal(directory: "/tmp")
        try runCommand("mkdir -p ~/\(folder) && cd ~/\(folder) && " + command + "; sleep 600")
        leaveTerminal()
    }

    func testCardsShareHeightAndLandscapeBarSlides() throws {
        try openHost()
        let long = String(repeating: "Posted the review with the cause, the steps, the numbers and a fix. ", count: 4)
        try session("long", "printf '{\"prompt\":\"tidy long\"}' | \(hook) prompt; printf '{\"last_assistant_message\":\"\(long)\"}' | \(hook) stop")
        try session("short", "printf '{\"prompt\":\"tidy short\"}' | \(hook) prompt; printf '{\"last_assistant_message\":\"Done.\"}' | \(hook) stop")
        try session("silent", "printf '{}' | \(hook) stop")
        try session("wait", "printf '{\"prompt\":\"build\"}' | \(hook) prompt; " +
            "printf '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"./gradlew assembleRelease\"}}' | \(hook) tool; " +
            "printf '{\"notification_type\":\"permission_prompt\",\"message\":\"needs permission\"}' | \(hook) notify")
        _ = try openTerminal(directory: "/tmp")
        leaveTerminal()
        let cards = homeSessionCards()
        func any(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        for prefix in ["home-session-approve-", "home-session-reply-", "home-session-no-reply-"] {
            XCTAssertTrue(any(prefix).waitForExistence(timeout: 40), "No \(prefix) card")
        }
        shot("portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let drawer = app.buttons["open-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        sleep(1)
        // One bar: the tabs, filters, search and add on one line, and no "会话 · N" line under it.
        let bar = drawer.frame
        XCTAssertLessThanOrEqual(bar.height, 48)
        for id in ["home-tab-sessions", "home-session-filter-all", "search-hosts", "add-session"] {
            let item = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(item.exists, id)
            XCTAssertEqual(item.frame.midY, bar.midY, accuracy: 2, id)
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '会话 · '")).firstMatch.exists)

        // Every agent card on screen is as tall as the next; plain terminals have one height of their own.
        var heights: [CGFloat] = []
        let list = app.descendants(matching: .any)["home-sessions-list"].firstMatch
        for _ in 0..<4 {
            for index in 0..<cards.count {
                let card = cards.element(boundBy: index)
                guard card.exists, card.frame.minY >= list.frame.minY, card.frame.maxY <= list.frame.maxY else { continue }
                let id = String(card.identifier.dropFirst("home-session-".count))
                if app.descendants(matching: .any)["home-session-time-" + id].exists { heights.append(card.frame.height) }
            }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThanOrEqual(heights.count, 4, "agent cards seen: \(heights)")
        for height in heights { XCTAssertEqual(height, heights[0], accuracy: 1, "agent card heights \(heights)") }

        // Scrolling on slid the bar away; scrolling back brings it back.
        shot("landscape-scrolled")
        XCTAssertLessThanOrEqual(drawer.frame.maxY, bar.minY + 1, "bar still at \(drawer.frame)")
        list.swipeDown(velocity: .slow)
        sleep(1)
        XCTAssertEqual(drawer.frame.minY, bar.minY, accuracy: 1)
        for _ in 0..<4 { list.swipeDown(velocity: .fast) }
        sleep(1)
        shot("landscape")

        app.buttons["home-tab-hosts"].tap()
        XCTAssertTrue(app.buttons["add-host"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["add-host"].frame.midY, bar.midY, accuracy: 2)
        // With no filters between them, search and add still sit at the end of the bar.
        XCTAssertGreaterThan(app.buttons["add-host"].frame.minX, app.windows.firstMatch.frame.width * 0.8)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '主机 · '")).firstMatch.exists)
        shot("landscape-hosts")
    }
}
