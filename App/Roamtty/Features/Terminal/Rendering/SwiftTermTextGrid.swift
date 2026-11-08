import SwiftTerm
#if canImport(RoamttyCore)
import RoamttyCore
#endif

/// SwiftTerm's active buffer as `TerminalUrl` reads it. Row 0 is the top visible row; history rows above it are
/// negative, and rows below the viewport are not read.
struct SwiftTermTextGrid: TerminalTextGrid {
    let terminal: Terminal
    private var top: Int { terminal.getTopVisibleRow() }
    var columns: Int { terminal.cols }
    var firstRow: Int { -top }
    var endRow: Int { terminal.rows }

    func cells(_ row: Int) -> [TerminalTextCell] {
        let absolute = top + row
        return (0..<terminal.cols).map { column in
            let data = terminal.buffer.getChar(atBufferRelative: Position(col: column, row: absolute))
            let width = Int(data.width)
            let character = width == 0 ? "" : String(terminal.getCharacter(for: data))
            return TerminalTextCell(character, width: width, underlined: data.attribute.style.contains(.underline))
        }
    }

    private static func blank(_ cell: TerminalTextCell?) -> Bool {
        guard let cell else { return true }
        if cell.width == 0 { return false }
        return cell.text.isEmpty || cell.text == " " || cell.text == "\0"
    }

    /// SwiftTerm keeps its soft-wrap flag on the continuing row and does not publish it, but its text extraction ends
    /// a line between two rows only when the second does not continue the first.
    func wraps(_ row: Int) -> Bool {
        guard row >= firstRow, row + 1 < endRow else { return false }
        // tmux redraws a full row without an erase, which leaves a stale wrap flag on the row below; Android clears
        // the flag when a row's last cell is written. A full row followed by one that starts blank reads as a break.
        let last = cells(row).last, next = cells(row + 1).first
        if !Self.blank(last) && Self.blank(next) { return false }
        let absolute = top + row
        let text = terminal.getText(start: Position(col: terminal.cols - 1, row: absolute), end: Position(col: 1, row: absolute + 1))
        return !text.contains("\n")
    }
}
