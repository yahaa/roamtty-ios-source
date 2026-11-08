// Behavioral port of Roamtty Android's TerminalCursorTap.java: a tap on typed text moves the cursor there with arrow
// keys, like tapping into a text field.
import Foundation

/// Within the cursor's own line a tap is a run of ←/→. In a multi-line input box (see `inputRows`) a tap on another
/// row first sends ↑/↓; the caller waits for the app to redraw the cursor on that row, then sends ←/→ from wherever
/// the app put it, since every editor keeps its own column memory.
public enum TerminalCursorTap {
    /// A box taller than this is more likely output than an input box.
    public static let maxInputRows = 24
    /// How long a row change waits for the app to echo the cursor onto the tapped row.
    public static let echoTimeout: TimeInterval = 1.5

    public enum Move: Equatable, Sendable {
        /// Signed ←/→ presses: negative is ←.
        case along(Int)
        /// Signed ↑/↓ presses: negative is ↑. Then `steps(…)` on the tapped row once the cursor is there.
        case rows(Int)
    }

    /// What a tap at `column`, `row` does with the cursor at `cursorColumn`, `cursorRow`; nil when it is not on the input.
    public static func move(_ grid: TerminalTextGrid, cursorColumn: Int, cursorRow: Int, column: Int, row: Int) -> Move? {
        guard grid.columns > 0, cursorRow >= 0, cursorRow < grid.endRow, row >= 0, row < grid.endRow else { return nil }
        let line = TerminalUrl.Reader(grid).logicalLine(cursorRow)
        // SwiftTerm can read a never-written row below as continuing the line; a blank row is not typed text.
        var lastRow = line.lastRow
        while lastRow > cursorRow && isBlank(grid, lastRow) { lastRow -= 1 }
        if row >= line.firstRow && row <= lastRow {
            return .along(steps(line, cursorColumn: cursorColumn, cursorRow: cursorRow, column: column, row: row))
        }
        guard let input = inputRows(grid, cursorRow: cursorRow), input.contains(row) else { return nil }
        return .rows(row - cursorRow)
    }

    /// Signed ←/→ presses from the cursor to `column` on its own row, never past the text's end.
    public static func steps(_ grid: TerminalTextGrid, cursorColumn: Int, cursorRow: Int, column: Int) -> Int {
        guard grid.columns > 0, cursorRow >= 0, cursorRow < grid.endRow else { return 0 }
        let line = TerminalUrl.Reader(grid).logicalLine(cursorRow)
        return steps(line, cursorColumn: cursorColumn, cursorRow: cursorRow, column: column, row: cursorRow)
    }

    /// Wide glyphs take one arrow press; combining marks stay with their base glyph.
    private static func steps(_ line: TerminalUrl.LogicalLine, cursorColumn: Int, cursorRow: Int, column: Int, row: Int) -> Int {
        let cursorCell = line.cell(column: cursorColumn, row: cursorRow)
        var end = line.text.count
        while end > 0 && line.text[end - 1] == " " { end -= 1 }
        let contentEnd = line.widths[0..<end].reduce(0, +)
        let tapped = line.cell(column: max(0, min(line.columns - 1, column)), row: row)
        let target = max(0, min(max(cursorCell, contentEnd), tapped))
        return line.offset(atCell: target) - line.offset(atCell: cursorCell)
    }

    /// The rows of the multi-line input box holding the cursor, or nil when the cursor is not in one. Agent TUIs fence
    /// their input: Claude Code between ─ rules, Codex between blank rows, with a status line below. So the box is the
    /// run of text rows around the cursor that has a rule or blank row on both sides and something drawn just below.
    /// A shell prompt has nothing below it, so ↑ there (history) is never sent.
    public static func inputRows(_ grid: TerminalTextGrid, cursorRow: Int) -> ClosedRange<Int>? {
        let rows = grid.endRow
        guard cursorRow >= 0, cursorRow < rows else { return nil }
        var top = cursorRow, bottom = cursorRow
        while top > 0 && isText(grid, top - 1) { top -= 1; if cursorRow - top >= maxInputRows { return nil } }
        while bottom < rows - 1 && isText(grid, bottom + 1) { bottom += 1; if bottom - top >= maxInputRows { return nil } }
        if top == 0 || bottom == rows - 1 { return nil }
        let fencedBelow = isRule(grid, bottom + 1) || (bottom + 2 < rows && !isBlank(grid, bottom + 2)) || (bottom + 3 < rows && !isBlank(grid, bottom + 3))
        return top < bottom && fencedBelow ? top...bottom : nil
    }

    private static func rowText(_ grid: TerminalTextGrid, _ row: Int) -> [Character] { TerminalUrl.Row(grid.cells(row), columns: grid.columns).text }
    private static func isBlank(_ grid: TerminalTextGrid, _ row: Int) -> Bool { rowText(grid, row).allSatisfy(\.isWhitespace) }
    private static func isText(_ grid: TerminalTextGrid, _ row: Int) -> Bool { !isBlank(grid, row) && !isRule(grid, row) }

    /// A row drawn mostly with box-drawing characters (U+2500-U+257F), like ──── or ╭────╮.
    public static func isRule(_ grid: TerminalTextGrid, _ row: Int) -> Bool {
        var drawn = 0, box = 0
        for character in rowText(grid, row) where !character.isWhitespace {
            drawn += 1
            if let scalar = character.unicodeScalars.first, (0x2500...0x257F).contains(scalar.value) { box += 1 }
        }
        return drawn >= 8 && box * 5 >= drawn * 4
    }
}
