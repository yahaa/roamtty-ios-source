import Foundation
import XCTest

final class TerminalGestureUITests: RoamttyLiveUITestCase {
    func testPlainSSHKeyboardPinchAndGestureBytes() throws {
        let surface = try openTerminal(mode: "SSH")
        XCTAssertTrue(terminalTransport.hasPrefix("SSH"))
        // As on Android, a tap on the cursor's line opens the keyboard.
        let escape = app.buttons["cursor-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: escape.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        surface.typeText("printf 'KEYBOARD_'; printf 'VERIFIED\\n'\n")
        waitForOutput("KEYBOARD_VERIFIED", surface: surface)

        let original = try terminalColumns(surface)
        surface.pinch(withScale: 1.4, velocity: 1)
        let enlarged = try terminalColumns(surface)
        XCTAssertLessThan(enlarged, original, "Pinching must resize the actual remote PTY columns")
        capture("Plain SSH keyboard and enlarged terminal font")

        try runCommand(receiver(prefix: "GESTURE", count: 8, reportProgress: true))
        waitForOutput("GESTURE_READY", surface: surface)
        surface.doubleTap()
        waitForOutput("GESTURE_PROGRESS=09", surface: surface)
        let left = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
        let right = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
        right.press(forDuration: 0.01, thenDragTo: left)
        waitForOutput("GESTURE_PROGRESS=091b5b44", surface: surface)
        left.press(forDuration: 0.01, thenDragTo: right)
        waitForOutput("GESTURE_PROGRESS=091b5b441b5b43", surface: surface)
        XCTAssertTrue(escape.waitForExistence(timeout: 6)); escape.tap()
        waitForOutput("GESTURE_BYTES=091b5b441b5b431b", surface: surface)
        capture("Double tap, horizontal swipes and Escape received by remote PTY")
        closePlainTerminal()
    }

    func testTmuxVerticalSwipeScrollsHistory() throws { try swipeScrollsTmuxHistory(mosh: false) }
    /// mosh resends its modes after every resize; tracking must survive the 1006 reset/set pair.
    func testMoshTmuxVerticalSwipeScrollsHistory() throws { try swipeScrollsTmuxHistory(mosh: true) }
    private func swipeScrollsTmuxHistory(mosh: Bool) throws {
        let surface = try openTerminal(preferMosh: mosh)
        XCTAssertEqual(terminalTransport.hasSuffix("mosh"), mosh)
        try runCommand("seq -f 'HIST_%03g' 1 400")
        waitForOutput("HIST_400", surface: surface)
        // A downward drag sends wheel-up events; tmux enters copy-mode and shows earlier lines.
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        for _ in 0..<2 { upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.2) }
        let scrolled = NSPredicate { element, _ in !((element as? XCUIElement)?.value as? String ?? "HIST_400").contains("HIST_400") }
        expectation(for: scrolled, evaluatedWith: surface).expectationDescription = "tmux scrolled back through its history"
        waitForExpectations(timeout: 10)
        capture("Vertical swipe scrolled tmux history" + (mosh ? " over mosh" : ""))
        closeTerminal()
    }

    /// A swipe keeps reaching a full-screen agent that tracks the mouse once a line was typed and sent, as Codex draws:
    /// on the alternate screen, with any-event tracking, redrawing its status all the time.
    func testVerticalSwipeReachesAgentAfterTypingALine() throws { try swipeReachesAgentAfterTyping(mosh: false) }
    /// mosh resizes with the keyboard and resends its modes each time, so this is the case phones see most.
    func testMoshVerticalSwipeReachesAgentAfterTypingALine() throws { try swipeReachesAgentAfterTyping(mosh: true) }
    /// Chinese and Japanese keyboards add a phrase-boundary recognizer inside the terminal, which is how phones type here.
    func testVerticalSwipeReachesAgentAfterPinyinInput() throws {
        app.terminate()
        app.launchArguments += ["-AppleKeyboards", "(\"zh_Hans-Pinyin@sw=Pinyin;hw=Automatic\")", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        try swipeReachesAgentAfterTyping(mosh: false, sent: "你") { surface in
            // Pinyin stays marked text until the space bar picks the first candidate. Real key taps: typeText skips the input method.
            for key in ["n", "i", "h", "a", "o"] {
                let tapped = self.app.keys[key]
                XCTAssertTrue(tapped.waitForExistence(timeout: 5), "No key \(key); keys: \(self.app.keys.allElementsBoundByIndex.map(\.label))")
                tapped.tap()
            }
            let space = self.app.keys.matching(NSPredicate(format: "label IN {' ', '空格', '选定', '确认', 'space', 'Space', 'confirm'}")).firstMatch
            XCTAssertTrue(space.waitForExistence(timeout: 5), "No space key; keys: \(self.app.keys.allElementsBoundByIndex.map(\.label))")
            space.tap()
            surface.typeText("\n")
        }
    }
    private func swipeReachesAgentAfterTyping(mosh: Bool, line: String = "hello", sent: String = "hello", type: ((XCUIElement) -> Void)? = nil) throws {
        let surface = try openTerminal(preferMosh: mosh)
        try runCommand(fakeMouseAgent())
        waitForOutput("AGENT_READY", surface: surface)
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func wheelCount() -> Int {
            let value = (surface.value as? String ?? "").replacingOccurrences(of: "\n", with: "")
            return value.components(separatedBy: "WHEEL=").dropFirst().compactMap { Int($0.prefix(5)) }.last ?? -1
        }
        func swipeReachesAgent(_ moment: String) {
            let before = wheelCount()
            upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.2)
            let moved = NSPredicate { _, _ in wheelCount() > before }
            let expectation = XCTNSPredicateExpectation(predicate: moved, object: surface)
            expectation.expectationDescription = "A swipe reached the agent \(moment)"
            if XCTWaiter.wait(for: [expectation], timeout: 5) == .completed { return }
            saveFailureScreenshot("swipe-\(moment)")
            XCTFail("A swipe \(moment) sent the agent no wheel events (still \(before))")
        }
        swipeReachesAgent("before-typing")
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if let type { type(surface) } else { surface.typeText(line + "\n") }
        waitForOutput("SENT=" + sent, surface: surface)
        swipeReachesAgent("with-keyboard-up")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 20))
        swipeReachesAgent("after-keyboard-hid")
        capture("Swipe reached the agent after typing a line")
    }

    /// As on Android, a quick flick keeps scrolling after the finger lifts; a drag that stops first does not.
    func testTmuxFlickKeepsScrollingAfterRelease() throws {
        let surface = try openTerminal()
        try runCommand("seq -f 'FLING_%04g' 1 1500")
        waitForOutput("FLING_1500", surface: surface)
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func lastLine() -> Int {
            let value = surface.value as? String ?? ""
            let numbers = value.components(separatedBy: "FLING_").dropFirst().compactMap { Int($0.prefix(4)) }
            return numbers.max() ?? 0
        }
        func settled() -> Int {
            var previous = -1, current = lastLine()
            while current != previous { previous = current; Thread.sleep(forTimeInterval: 1); current = lastLine() }
            return current
        }
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.3)
        let afterDrag = settled()
        let dragged = 1500 - afterDrag
        XCTAssertGreaterThan(dragged, 0, "The drag entered tmux copy-mode")
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 3000, thenHoldForDuration: 0)
        let flicked = afterDrag - settled()
        XCTAssertGreaterThan(flicked, dragged * 3 / 2, "A flick over the same distance carries on after release")
        capture("Flick kept scrolling tmux history after release")
        closeTerminal()
    }

    func testCursorRowTapAndDoubleTapAfterKeyboardIsPutAway() throws {
        let surface = try openTerminal()
        let escape = app.buttons["cursor-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 6))
        func tapCursorRow() {
            // The cursor row shows Esc, or Enter for a few seconds after typing.
            let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        }
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Fill the screen so the cursor sits on the bottom row, as in a working shell.
        surface.typeText("seq 1 120; echo TYPED_\\\nDONE\n")
        waitForOutput("TYPED_DONE", surface: surface)
        let hide = app.buttons["cursor-hide-keyboard"]
        // Enter puts the keyboard away by itself after 15 s.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 20))
        capture("Keyboard put away after typing")
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterAutoHide") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard after it hid itself")
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        // Tapping the cursor's line again brings the keyboard back.
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterHide") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard again")
        // A reading tap away from the cursor puts it away; a double tap then brings the pet's arrows.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterReadingTap") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard after a reading tap")
        hide.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).doubleTap()
        if !app.buttons["pet-arrow-up"].waitForExistence(timeout: 3) { saveFailureScreenshot("doubleTapArrows") }
        XCTAssertTrue(app.buttons["pet-arrow-up"].exists, "A double tap must bring the pet's arrow keys")
    }

    /// Claude Code's /usage panel hides the cursor and parks it on its tab bar near the top; the line the
    /// user typed /usage on must still bring the keyboard back once it was put away.
    func testTypedLineOpensKeyboardWhileHostHidesCursor() throws {
        let surface = try openTerminal(mode: "SSH")
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Typing a /usage line, then Enter, replaces it with a panel whose hidden cursor sits on row 4.
        surface.typeText("printf '\\033[?1049h\\033[2J\\033[30;1H/usage'; read -r x; printf '\\033[2J\\033[HPANEL_\\nSHOWN\\033[?25l\\033[4;20H'; read -r y\n")
        sleep(2); XCTAssertTrue(row.waitForExistence(timeout: 6))
        let typedLine = row.frame.midY - surface.frame.minY
        surface.typeText("\n")
        waitForOutput("PANEL_SHOWN", surface: surface)
        let hide = app.buttons["cursor-hide-keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: typedLine)).tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("hiddenCursorTypedLine") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "With the cursor hidden, a tap on the typed line must open the keyboard")
    }

    func testKeyboardReopenedAfterEnterStaysUp() throws {
        let surface = try openTerminal()
        func tapCursorRow() {
            // The cursor row shows Esc, or Enter for a few seconds after typing.
            let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        }
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        surface.typeText("seq 1 120; echo REOPEN_\\\nDONE\n")
        waitForOutput("REOPEN_DONE", surface: surface)
        // A reading tap puts the keyboard away before Enter's own 15 s timer does.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // That earlier timer must not take the keyboard the user just asked for away again.
        sleep(16)
        if !app.keyboards.firstMatch.exists { saveFailureScreenshot("keyboardTakenAway") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard opened from the cursor row must stay up")
    }

    /// As on Android, a tap on typed text moves the cursor there: along the cursor's row with ←/→, and in a multi-line
    /// input box (Claude Code's, between ─ rules) up or down first, then along once the app has echoed the cursor.
    func testTapMovesTheCursorInsideAMultiLineInput() throws {
        let surface = try openTerminal()
        try runCommand(boxEditor())
        // The editor counts the sizes it has drawn at: putting the prompt editor or the keyboard away resizes it.
        func status(_ pattern: String) -> Int? {
            let value = (surface.value as? String ?? "").replacingOccurrences(of: "\n", with: "")
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return Int(value[range])
        }
        func sizes(_ phase: String) -> Int? { status("EDITOR_" + phase + "_([0-9]+)") }
        waitForOutput("EDITOR_READY_", surface: surface)
        let drawn = sizes("READY") ?? 0
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        // Bring the keyboard up first, so the box does not move under the taps. A tap past the typed text sends nothing.
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.9, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The editor parks the cursor on its output row, then on the end of the last input row: the cursor's key
        // follows it, which measures the rows. Cells are measured from the column count, so taps stay near the left.
        let resized = expectation(for: NSPredicate { _, _ in (sizes("CAL") ?? 0) > drawn }, evaluatedWith: surface)
        resized.expectationDescription = "The keyboard resized the editor"
        wait(for: [resized], timeout: 10); sleep(1)
        let output = row.frame.midY
        let size = sizes("CAL") ?? 0
        waitForOutput("EDITOR_READY_\(size)", surface: surface); sleep(1)
        let last = row.frame.midY, rowHeight = (last - output) / 4
        let value = surface.value as? String ?? ""
        let sizePattern = try NSRegularExpression(pattern: "SIZE_([0-9]+)x([0-9]+)")
        guard let match = sizePattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
              let range = Range(match.range(at: 2), in: value), let columns = Double(value[range]), rowHeight > 4 else {
            return XCTFail("The editor must report its size and the cursor rows must be measurable")
        }
        let cellWidth = surface.frame.width / columns
        // Input rows: 0 "❯ first line abc", 1 "  second", 2 "  third 你好 tail" (row 2 is the cursor's, `last`).
        func tap(column: Double, inputRow: Int) {
            let y = last + CGFloat(inputRow - 2) * rowHeight - surface.frame.minY
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: CGFloat(column) * cellWidth, dy: y)).tap()
        }
        // Up two rows: the editor keeps its column (the end of row 0), then 12 ← reach "first".
        tap(column: 4, inputRow: 0)
        waitForOutput("AT_0_4 KEYS_14", surface: surface)
        // Down two rows onto 好: 你 is one ← / → press.
        tap(column: 10, inputRow: 2)
        waitForOutput("AT_2_9 KEYS_21", surface: surface)
        // Along the cursor's own row.
        tap(column: 3, inputRow: 2)
        waitForOutput("AT_2_3 KEYS_27", surface: surface)
        // Past the end of a row stops at its end.
        tap(column: 20, inputRow: 1)
        waitForOutput("AT_1_8 KEYS_33", surface: surface)
        capture("Taps moved the cursor across a multi-line input")
        // Output above the box is not the input: nothing is sent.
        tap(column: 4, inputRow: -2)
        sleep(2)
        XCTAssertEqual(status("KEYS_([0-9]+)"), 33, "A tap on output must send no arrows")
        closeTerminal()
    }

    func testBracketedPasteAndReconnectAfterRemoteShellExit() throws {
        let surface = try openTerminal(mode: "SSH")
        let payload = "one\ntwo\n"
        let expected = Data(("\u{1b}[200~one\rtwo\r\u{1b}[201~").utf8)
        try runCommand(receiver(prefix: "BRACKETED", count: expected.count, bracketed: true))
        waitForOutput("BRACKETED_READY", surface: surface)
        typeIntoTerminal(payload)
        XCTAssertFalse(app.buttons["terminal-paste-send"].exists, "Bracketed paste must be sent with delimiters without a multiline warning")
        waitForOutput("BRACKETED_BYTES=" + expected.map { String(format: "%02x", $0) }.joined(), surface: surface)
        try runCommand("kill -HUP $$")
        let reconnect = app.buttons["terminal-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 20))
        // The notice says what happened; the raw error waits behind 查看详情 (roamtty #277).
        XCTAssertTrue(app.staticTexts["terminal-connection-summary"].exists)
        let details = app.buttons["terminal-connection-details"]
        if details.exists {
            XCTAssertFalse(app.staticTexts["terminal-notice"].exists)
            details.tap()
            XCTAssertTrue(app.staticTexts["terminal-notice"].waitForExistence(timeout: 3))
        }
        capture("Connection notice with its details")
        reconnect.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        let resumed = try runCommand("printf 'RECONNECT_'; printf 'VERIFIED\\n'")
        waitForOutput("RECONNECT_VERIFIED", surface: resumed)
        XCTAssertFalse((resumed.value as? String ?? "").contains("BRACKETED_BYTES"), "A replacement session must have a fresh renderer and must not replay old input")
        capture("Plain SSH reconnected after server closed the shell")
        closePlainTerminal()
    }

    /// The lines here come through the prompt editor, so SwiftTerm's input buffer holds none of them, as after a paste:
    /// the keyboard must still repeat a held delete, and the host's line editor shows what each press did.
    func testHoldingKeyboardDeleteClearsARemoteLineAndATapDeletesOneCharacter() throws {
        let surface = try openTerminal(mode: "SSH")
        func stage(_ line: String) {
            typeIntoTerminal(line)
            app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
            let escape = app.buttons["cursor-escape"]
            XCTAssertTrue(escape.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: escape.frame.midY - surface.frame.minY)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        }
        let delete = app.keyboards.firstMatch.keys.matching(NSPredicate(format: "label IN {'delete', '删除', 'Delete'}")).firstMatch

        // Left in place, this prefix stops the command after it from printing anything.
        stage("false && ")
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.press(forDuration: 2.5)
        surface.typeText("echo HOLD_$((40+2))\n")
        waitForOutput("HOLD_42", surface: surface)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clearing must leave the keyboard up")

        // The trailing backslash keeps the line open until one tap removes it, and only it.
        stage("echo TAP_$((40+2)) \\")
        delete.tap()
        surface.typeText("\n")
        waitForOutput("TAP_42", surface: surface)

        // A press too short to be a hold only deletes: the rest of the line still runs.
        stage("echo SHORT_$((40+2)) \\")
        delete.press(forDuration: 0.3)
        surface.typeText("\n")
        waitForOutput("SHORT_42", surface: surface)
    }

    private func terminalColumns(_ surface: XCUIElement) throws -> Int {
        let token = String(UUID().uuidString.prefix(6))
        try runCommand("set -- $(stty size); printf 'PTY_'; printf '\(token)_%s_%s\\n' \"$1\" \"$2\"")
        let marker = "PTY_" + token + "_"
        waitForOutput(marker, surface: surface)
        let value = surface.value as? String ?? ""
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: marker) + "[0-9]+_([0-9]+)")
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value), let columns = Int(value[range]) else {
            XCTFail("The remote stty output must contain the PTY column count"); return 0
        }
        return columns
    }

    private func closePlainTerminal() {
        closeTerminal()
        XCTAssertEqual(homeSessionCards().count, 0, "Explicitly closing plain SSH must remove its session card")
    }

    /// A small editor drawn like Claude Code's input: an output row, a ─ rule, three input rows, a rule and a status line
    /// at the bottom. ↑/↓ keep the column like Claude Code; ←/→ move one character, a wide one included. The status line
    /// shows the phase and how many sizes it has seen, the cursor (input row, character) and how many arrows arrived.
    private func boxEditor() -> String {
        let source = """
        import os, select, termios, time, tty
        lines = ['\\u276f first line abc', '  second', '  third \\u4f60\\u597d tail']
        def w(ch): return 2 if '\\u4e00' <= ch <= '\\u9fff' else 1
        line, idx, sticky, keys, sizes, phase, since, size = 2, len(lines[2]), None, 0, 0, 'CAL', 0, None
        def cells(l, i): return sum(w(c) for c in lines[l][:i])
        def at(l, col):
            i = c = 0
            while i < len(lines[l]) and c + w(lines[l][i]) <= col:
                c += w(lines[l][i]); i += 1
            return i
        def draw():
            rows, cols = size
            top = rows - 7
            out = ['\\x1b[2J']
            def put(r, text): out.append('\\x1b[%d;1H%s' % (r + 1, text))
            put(top, 'OUTPUT_ABOVE_THE_BOX')
            put(top + 1, '\\u2500' * cols)
            for k, text in enumerate(lines): put(top + 2 + k, text)
            put(top + 5, '\\u2500' * cols)
            put(rows - 1, 'EDITOR_%s_%d AT_%d_%d KEYS_%d SIZE_%dx%d' % (phase, sizes, line, idx, keys, rows, cols))
            out.append('\\x1b[%d;1H' % (top + 1) if phase == 'CAL' else '\\x1b[%d;%dH' % (top + 3 + line, cells(line, idx) + 1))
            os.write(1, ''.join(out).encode())
        saved = termios.tcgetattr(0)
        buf = b''
        try:
            tty.setraw(0)
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                now = tuple(reversed(os.get_terminal_size(0)))
                if now != size:
                    size, sizes, phase, since = now, sizes + 1, 'CAL', time.monotonic(); draw()
                if phase == 'CAL' and time.monotonic() - since > 3:
                    phase = 'READY'; draw()
                if not select.select([0], [], [], 0.1)[0]:
                    continue
                buf += os.read(0, 256)
                while buf:
                    if buf[:1] == b'q':
                        deadline = 0; break
                    if buf[:1] == b'\\x1b' and len(buf) < 3:
                        break
                    if buf[:1] != b'\\x1b' or buf[1:2] not in (b'[', b'O'):
                        buf = buf[1:]; continue
                    key, buf = buf[2:3], buf[3:]
                    keys += 1
                    if phase != 'READY':
                        continue
                    if key in (b'A', b'B'):
                        if sticky is None: sticky = cells(line, idx)
                        line = max(0, min(2, line + (-1 if key == b'A' else 1))); idx = at(line, sticky)
                    elif key in (b'C', b'D'):
                        sticky = None; idx = max(0, min(len(lines[line]), idx + (1 if key == b'C' else -1)))
                draw()
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }

    /// A stand-in for Codex's interface: alternate screen, any-event SGR mouse tracking, a status redrawn ten times a
    /// second, and a count of the wheel events and the last line it was sent.
    private func fakeMouseAgent() -> String {
        let source = """
        import os, re, select, termios, tty
        saved = termios.tcgetattr(0)
        wheel, line, sent, pending, frame = 0, '', '', b'', 0
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?1049h\\x1b[?1003h\\x1b[?1006h\\x1b[2J\\x1b[1;1HAGENT_READY')
            while line != 'quit':
                if select.select([0], [], [], 0.1)[0]:
                    pending += os.read(0, 4096)
                    wheel += len(re.findall(rb'\\x1b\\[<6[45];\\d+;\\d+M', pending))
                    typed = re.sub(rb'\\x1b\\[<\\d+;\\d+;\\d+[Mm]', b'', pending).decode(errors='ignore')
                    pending = b''
                    for character in typed:
                        if character in '\\r\\n': sent, line = line, ''
                        else: line += character
                frame += 1
                os.write(1, ('\\x1b[3;1HWHEEL=%05d\\x1b[K\\x1b[5;1HSENT=%s\\x1b[K\\x1b[7;1HWorking %d\\x1b[K\\x1b[12;1H> %s\\x1b[K' % (wheel, sent, frame, line)).encode())
        finally:
            os.write(1, b'\\x1b[?1006l\\x1b[?1003l\\x1b[?1049l')
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }

    private func receiver(prefix: String, count: Int, bracketed: Bool = false, reportProgress: Bool = false) -> String {
        let source = """
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?1l\\x1b[?2004\(bracketed ? "h" : "l")')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if select.select([0], [], [], 1)[0]:
                    chunk = os.read(0, \(count) - len(received))
                    if not chunk:
                        break
                    received.extend(chunk)
                    if \(reportProgress ? "True" : "False"):
                        os.write(1, ('\\r\\n\(prefix)_PROGRESS=' + received.hex() + '\\r\\n').encode())
        finally:
            os.write(1, b'\\x1b[?2004l')
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex(), flush=True)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }
}
