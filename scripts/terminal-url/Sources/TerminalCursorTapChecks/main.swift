// Ports Android's TerminalCursorTapTest and TerminalGesturesTest tap cases onto SwiftTerm: the app's cursor-tap rules
// over the app's SwiftTerm grid adapter, on real Claude Code, Codex and bash screens.
import Foundation
import SwiftTerm

final class Silent: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
let delegate = Silent()
var failures = 0, checks = 0

func terminal(_ columns: Int, _ rows: Int, _ text: String) -> Terminal {
    let t = Terminal(delegate: delegate, options: TerminalOptions(cols: columns, rows: rows, scrollback: 400))
    t.feed(text: text)
    return t
}
func screen(_ captured: (text: String, cursorRow: Int, cursorColumn: Int)) -> Terminal {
    terminal(60, 24, "\u{1b}[H" + captured.text + "\u{1b}[\(captured.cursorRow + 1);\(captured.cursorColumn + 1)H")
}
func grid(_ t: Terminal) -> SwiftTermTextGrid { SwiftTermTextGrid(terminal: t) }
/// The tap as the app makes it: with the cursor wherever the terminal has it.
func tap(_ t: Terminal, _ column: Int, _ row: Int) -> TerminalCursorTap.Move? {
    let cursor = t.getCursorLocation()
    return TerminalCursorTap.move(grid(t), cursorColumn: cursor.x, cursorRow: cursor.y, column: column, row: row)
}
/// The ←/→ sent once the app has echoed the cursor onto its row.
func echoed(_ t: Terminal, _ column: Int) -> Int {
    let cursor = t.getCursorLocation()
    return TerminalCursorTap.steps(grid(t), cursorColumn: cursor.x, cursorRow: cursor.y, column: column)
}
func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL line \(line) \(name): expected \(expected), got \(actual)") }
}

// Real screens: the box is found for both agents, and never at a shell prompt.
do {
    let claude = screen(claudeScreen), codex = screen(codexScreen), bash = screen(bashScreen)
    expect(TerminalCursorTap.inputRows(grid(claude), cursorRow: claudeScreen.cursorRow), 18...21, "claude box")
    expect(TerminalCursorTap.inputRows(grid(codex), cursorRow: codexScreen.cursorRow), 17...20, "codex box")
    expect(TerminalCursorTap.inputRows(grid(bash), cursorRow: bashScreen.cursorRow), nil, "bash prompt")
    expect(TerminalCursorTap.isRule(grid(claude), 17), true, "claude upper rule")
    expect(TerminalCursorTap.isRule(grid(claude), 22), true, "claude lower rule")

    // Claude: the cursor ends "  the edge of the box ok" (row 21). A tap on "first" goes up three rows.
    expect(tap(claude, 4, 18), .rows(-3), "claude up")
    expect(tap(claude, 4, 17), nil, "claude rule")
    expect(tap(claude, 4, 23), nil, "claude status")
    expect(tap(claude, 4, 2), nil, "claude banner")
    expect(tap(claude, 10, 21), .along(-14), "claude same row")
    expect(tap(claude, 50, 21), .along(0), "claude past the end")
    // Claude puts the cursor at the end of the shorter "❯ first line abc" row.
    claude.feed(text: "\u{1b}[19;17H")
    expect(echoed(claude, 4), -12, "claude echo left")
    // Down to the CJK row; 你好 are one press each.
    claude.feed(text: "\u{1b}[19;3H")
    expect(tap(claude, 19, 20), .rows(2), "claude down")
    claude.feed(text: "\u{1b}[21;3H")
    expect(echoed(claude, 19), 16, "claude onto 你")
    expect(echoed(claude, 22), 18, "claude after 好")

    // Codex: same shape between blank rows, above its status line.
    expect(tap(codex, 2, 17), .rows(-3), "codex up")
    expect(tap(codex, 2, 21), nil, "codex blank row")
    expect(tap(codex, 2, 22), nil, "codex status")
    expect(tap(codex, 2, 14), nil, "codex output")

    // bash: taps on output above the prompt never send ↑ (history); along the prompt line they move.
    expect(tap(bash, 3, 5), nil, "bash output")
    expect(tap(bash, 0, 0), nil, "bash command")
    expect(tap(bash, 12, 6), .along(-5), "bash typed text")
}

// A soft-wrapped command line is one line: the tap on its first row moves along it, not up.
do {
    let t = terminal(20, 6, "$ echo " + String(repeating: "x", count: 25))
    let cursor = t.getCursorLocation()
    expect(cursor.y, 1, "wrapped cursor row")
    expect(tap(t, 7, 0), .along(-(32 - 7)), "wrapped first row")
}

// Framed boxes: the frame's rows are rules, the rows between are text.
do {
    let t = terminal(40, 12, "out\r\n╭────────────────╮\r\n│ hello          │\r\n│ world          │\r\n╰────────────────╯\r\n status")
    expect(TerminalCursorTap.isRule(grid(t), 1), true, "top frame")
    expect(TerminalCursorTap.isRule(grid(t), 2), false, "framed text")
    t.feed(text: "\u{1b}[4;9H")
    expect(TerminalCursorTap.inputRows(grid(t), cursorRow: 3), 2...3, "framed box")
}

print("TerminalCursorTapChecks: \(checks - failures)/\(checks) passed")
if failures > 0 { exit(1) }
