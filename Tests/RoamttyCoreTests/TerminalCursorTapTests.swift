import XCTest
@testable import RoamttyCore

/// Android's TerminalCursorTapTest on a plain grid; scripts/test-terminal-url.sh runs the same rules on SwiftTerm.
final class TerminalCursorTapTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)

    /// Rows of text on a 40-column screen; CJK characters take two cells, like a terminal draws them.
    private struct Grid: TerminalTextGrid {
        let lines: [String]
        let columns = 40
        var firstRow: Int { 0 }
        let endRow: Int
        func cells(_ row: Int) -> [TerminalTextCell] {
            var cells: [TerminalTextCell] = []
            for character in row < lines.count ? lines[row] : "" {
                let wide = character.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
                cells.append(TerminalTextCell(String(character), width: wide ? 2 : 1))
                if wide { cells.append(TerminalTextCell("", width: 0)) }
            }
            return cells + Array(repeating: .blank, count: max(0, columns - cells.count))
        }
        func wraps(_ row: Int) -> Bool { false }
    }
    private func screen(_ lines: [String], rows: Int = 12) -> Grid { Grid(lines: lines, endRow: rows) }

    func testClaudeCodeInputBetweenRulesIsOneBox() {
        let grid = screen(["● done", "", rule, "❯ first line", "  second", "  third wraps", "  the tail", rule, "  ⏵⏵ auto mode on"])
        XCTAssertTrue(TerminalCursorTap.isRule(grid, 2))
        XCTAssertEqual(TerminalCursorTap.inputRows(grid, cursorRow: 4), 3...6)
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 8, cursorRow: 4, column: 4, row: 3), .rows(-1))
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 8, cursorRow: 4, column: 4, row: 2), nil, "the rule")
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 8, cursorRow: 4, column: 4, row: 0), nil, "output")
    }

    func testCodexComposerBetweenBlankRowsAboveItsStatusLine() {
        let grid = screen(["  /review - review changes", "", "› first line", "  second", "  third", "", "  model · 100% left"])
        XCTAssertEqual(TerminalCursorTap.inputRows(grid, cursorRow: 3), 2...4)
    }

    func testShellPromptWithOutputAboveIsNotABox() {
        XCTAssertNil(TerminalCursorTap.inputRows(screen(["", "file-a", "file-b", "$ ls"]), cursorRow: 3))
        XCTAssertNil(TerminalCursorTap.inputRows(screen(["x", "", "a", "b", "c", "d", "e", "f", "g", "h", "i", "$ ls"]), cursorRow: 11),
                     "Nothing below but the screen edge")
        XCTAssertNil(TerminalCursorTap.move(screen(["", "file-a", "file-b", "$ ls"]), cursorColumn: 4, cursorRow: 3, column: 2, row: 1))
    }

    func testSingleRowInputHasNoOtherRowToJumpTo() {
        XCTAssertNil(TerminalCursorTap.inputRows(screen(["", rule, "❯ hi", rule, "  status"]), cursorRow: 2))
    }

    func testFramedBoxRowsAreTextButItsBordersAreRules() {
        let grid = screen(["╭──────────────────╮", "│ > hello          │", "╰──────────────────╯"])
        XCTAssertTrue(TerminalCursorTap.isRule(grid, 0))
        XCTAssertFalse(TerminalCursorTap.isRule(grid, 1))
        XCTAssertTrue(TerminalCursorTap.isRule(grid, 2))
    }

    /// Android's tapOnTheCursorLineMovesTheCursorThereWithArrows: "❯ hello 中文abc" with the cursor at its end.
    func testTapAlongTheCursorRowCountsWideGlyphsOnce() {
        let grid = screen(["❯ hello 中文abc"])
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 15, cursorRow: 0, column: 6, row: 0), .along(-7))
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 15, cursorRow: 0, column: 30, row: 0), .along(0), "past the end")
        XCTAssertEqual(TerminalCursorTap.move(grid, cursorColumn: 8, cursorRow: 0, column: 15, row: 0), .along(5))
        XCTAssertEqual(TerminalCursorTap.steps(grid, cursorColumn: 8, cursorRow: 0, column: 9), 0, "the right half of 中")
        XCTAssertEqual(TerminalCursorTap.steps(grid, cursorColumn: 8, cursorRow: 0, column: 10), 1, "文")
    }
}
