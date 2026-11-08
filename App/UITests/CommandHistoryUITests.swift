import Foundation
import XCTest

final class CommandHistoryUITests: RoamttyLiveUITestCase {
    func testRemoteHistoryRefreshFilterAndRun() throws {
        let surface = try openTerminal(mode: "SSH")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let executed = "HISTORY_EXECUTED_" + token
        let command = emit(executed)
        let prepared = "HISTORY_PREPARED_" + token

        // Only this shell disables automatic history writes. The app's separate SSH
        // history reader still reads the real user's ~/.bash_history. The fixture is
        // one UUID-owned byte record; cleanup removes that exact record and no others.
        let record = Data(("\n" + command + "\n").utf8).base64EncodedString()
        let seed = """
        import base64, os
        from pathlib import Path
        path = Path.home() / '.bash_history'
        with path.open('ab') as history:
            history.write(base64.b64decode('\(record)'))
            history.flush()
            os.fsync(history.fileno())
        print('\(prepared)', flush=True)
        """
        try runCommand("unset HISTFILE; " + python(seed))
        waitForOutput(prepared, surface: surface)

        openCommands()
        let search = app.textFields["history-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        // Noncontiguous characters require the real fuzzy filter, rather than a
        // full-string match against a test-only row.
        let fuzzy = String(token.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element)).lowercased()
        replace(search, with: fuzzy)
        let refresh = app.buttons["history-refresh"]
        waitUntilEnabled(refresh); refresh.tap(); waitUntilEnabled(refresh)
        let remote = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-command-' AND label == %@", command)).firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 15), "Refresh must load the fixture from actual remote shell history")
        XCTAssertTrue(app.staticTexts["history-source"].label.lowercased().hasSuffix("~/.bash_history"))
        replace(search, with: "absent-" + UUID().uuidString)
        XCTAssertFalse(remote.exists, "A nonmatching query must hide the remote history row")
        replace(search, with: fuzzy)
        capture("Remote history command found by fuzzy search")
        // As on Android, a tap closes the sheet and runs the command.
        XCTAssertTrue(remote.waitForExistence(timeout: 8)); remote.tap()
        waitForOutput(executed, surface: surface)

        let cleaned = "HISTORY_CLEANED_" + token
        let cleanup = """
        import base64, os
        from pathlib import Path
        owned = base64.b64decode('\(record)')
        path = Path.home() / '.bash_history'
        with path.open('r+b') as history:
            original = history.read()
            assert original.count(owned) == 1
            remaining = original.replace(owned, b'', 1)
            history.seek(0)
            history.write(remaining)
            history.truncate()
            history.flush()
            os.fsync(history.fileno())
        assert owned not in path.read_bytes()
        print('\(cleaned)', flush=True)
        """
        try runCommand(python(cleanup)); waitForOutput(cleaned, surface: surface)
        closePlainTerminal()
    }

    func testNativeTerminalSelectionCopyAndClipboardPasteReachRemoteOnce() throws {
        let surface = try openTerminal(mode: "SSH")
        let token = String(UUID().uuidString.prefix(8))
        let payload = "CLIPBOARD_" + token
        // Clear only this terminal's screen and scrollback, then copy its real
        // selected rendered text. The test never reads a pre-existing clipboard.
        // The terminal runs under the status bar, so the payload fills the top rows
        // and the press lands on it below the status bar.
        try runCommand("printf '\\033[3J\\033[2J\\033[H'; for row in 1 2 3 4 5 6 7 8 9 10 11 12; do " + emit(payload) + "; done")
        waitForOutput(payload, surface: surface)
        // Long-press opens SwiftTerm's native selection and edit menu.
        let press = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1))
        press.press(forDuration: 1.2)
        let selectAll = nativeMenu(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3)); selectAll.tap()
        capture("Native terminal selection")
        // With text selected, a second long-press offers Copy.
        press.press(forDuration: 1.2)
        let copy = nativeMenu(NSPredicate(format: "label == 'Copy' OR label == '拷贝' OR label == '复制'"))
        if !copy.waitForExistence(timeout: 3) { saveFailureScreenshot("copy") }
        XCTAssertTrue(copy.exists); copy.tap()

        // Android's 粘贴 stages the clipboard in the prompt editor rather than typing it.
        clearDraft()
        terminalMenu("menu-paste")
        let editor = app.textViews["prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let copied = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(copied.contains(payload), "Native Copy must publish the selected terminal text")
        XCTAssertLessThan(copied.utf8.count, 4096, "The cleared test terminal must contain only a small owned payload and prompt")
        XCTAssertTrue(copied.unicodeScalars.allSatisfy { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }, "Selection copies rendered text, never terminal control sequences")

        // Expected bytes come from the clipboard content just exposed through the
        // prompt editor, with the terminal's documented newline convention.
        let normalized = copied.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let expected = Data(normalized.utf8)
        XCTAssertFalse(expected.isEmpty)
        let prefix = "NATIVE_PASTE_" + token
        try runCommand(byteReceiver(prefix: prefix, count: expected.count))
        waitForOutput(prefix + "_READY", surface: surface)
        // The receiver was typed through the editor; stage the clipboard there again and send it.
        clearDraft()
        terminalMenu("menu-paste")
        XCTAssertTrue(app.textViews["prompt-editor"].waitForExistence(timeout: 5))
        app.buttons["prompt-send"].tap()
        if copied.contains("\n") || copied.contains("\r") {
            let send = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-send").firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 5), "Native multiline clipboard paste must use the same confirmation as other input")
            send.tap()
        }
        waitForOutput(prefix + "_BYTES=" + expected.map { String(format: "%02x", $0) }.joined() + "_END", surface: surface)
        capture("Actual clipboard bytes reached remote PTY exactly once")
        closePlainTerminal()
    }

    private func openCommands() {
        openTools(); app.buttons["common-commands"].tap()
        XCTAssertTrue(app.textFields["history-search"].waitForExistence(timeout: 8))
    }

    private func nativeMenu(_ predicate: NSPredicate) -> XCUIElement {
        let kinds = NSPredicate(format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)
        return app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, kinds])).firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    private func closePlainTerminal() {
        closeTerminal()
    }

    private func emit(_ value: String) -> String {
        let middle = value.index(value.startIndex, offsetBy: value.count / 2)
        return "printf '%s' " + quote(String(value[..<middle])) + "; printf '%s\\n' " + quote(String(value[middle...]))
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func python(_ source: String) -> String { "python3 -u -c \"import base64; exec(base64.b64decode('" + Data(source.utf8).base64EncodedString() + "'))\"" }

    private func byteReceiver(prefix: String, count: Int) -> String {
        python("""
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004l')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if select.select([0], [], [], 1)[0]:
                    chunk = os.read(0, \(count) - len(received))
                    if not chunk:
                        break
                    received.extend(chunk)
            if select.select([0], [], [], 0.3)[0]:
                received.extend(os.read(0, 4096))
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex() + '_END', flush=True)
        """)
    }
}
