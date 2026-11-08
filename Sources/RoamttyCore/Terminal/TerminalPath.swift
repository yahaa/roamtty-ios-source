// Behavioral port of Roamtty Android's TerminalPath.java (roamtty #275): the file path, with its ":line[:column]",
// under a tapped terminal cell. Only text that looks like a path qualifies; whether the file exists is for the app to ask.
import Foundation

/// A path printed in the terminal and the line it points at (1-based, or 0 for none).
public struct TerminalPathCandidate: Equatable, Sendable {
    public let path: String
    public let line: Int
    public init(path: String, line: Int) { self.path = path; self.line = line }
}

/// A tapped path: the candidates to try in order and the rows it covers.
public struct TerminalPathLink: Equatable, Sendable {
    /// The path as read, then, for a path joined across a TUI's hard line break, the tapped row's piece alone: the
    /// join is a guess from the layout, so the piece is tried when the joined path names no file.
    public let candidates: [TerminalPathCandidate]
    /// The cells the path (with its location) covers, so a press can mark exactly those.
    public let spans: [TerminalLinkSpan]
    /// The grid rows the path's characters sit on.
    public var rows: Set<Int> { Set(spans.map(\.row)) }
    public var path: String { candidates[0].path }
    public var line: Int { candidates[0].line }
    public func covers(row: Int) -> Bool { rows.contains(row) }
}

public enum TerminalPath {
    /// Rows a hard-wrapped path may span; paths longer than this are not joined.
    static let maxJoinedRows = 8
    static let maxPathLength = 4096
    /// Cells a TUI may leave unused at the right edge of a row it filled.
    static let maxRightMargin = 4

    public static func at(_ grid: TerminalTextGrid, column: Int, row: Int) -> TerminalPathLink? {
        guard column >= 0, column < grid.columns, row >= grid.firstRow, row < grid.endRow else { return nil }
        let reader = TerminalUrl.Reader(grid)
        let line = reader.logicalLine(row)
        let text = line.text
        let offset = line.offset(atCell: line.cell(column: column, row: row))
        guard offset < text.count, isPathCharacter(text[offset]) else { return nil }
        var start = offset, end = offset
        while start > 0 && isPathCharacter(text[start - 1]) { start -= 1 }
        while end < text.count && isPathCharacter(text[end]) { end += 1 }
        // The logical-line reader is bounded: a token cut off by its limit is not a whole path.
        if end == text.count && reader.wraps(line.lastRow) { return nil }
        let alone = parse(Array(text[start..<end]), tapped: offset - start, cells: line.cells(start..<end))

        // TUIs such as coding agents break a long path with a newline and indentation, which carries no soft-wrap
        // flag. Join the pieces the layout says belong together, like a hard-wrapped URL.
        var joined = Array(text[start..<end]), joinedCells = line.cells(start..<end)
        var tapped = offset - start
        var rows = line.lastRow - line.firstRow + 1
        var first = line, pieceStart = start
        while pieceStart == indentEnd(first.text) && rows < maxJoinedRows {
            let y = first.firstRow - 1
            guard y >= grid.firstRow, continues(reader, y) else { break }
            let previous = reader.logicalLine(y)
            let pieceEnd = contentEnd(previous.text)
            pieceStart = pieceEnd
            while pieceStart > 0 && isPathCharacter(previous.text[pieceStart - 1]) { pieceStart -= 1 }
            if pieceStart == pieceEnd { break }
            joined.insert(contentsOf: previous.text[pieceStart..<pieceEnd], at: 0)
            joinedCells.insert(contentsOf: previous.cells(pieceStart..<pieceEnd), at: 0)
            tapped += pieceEnd - pieceStart
            first = previous; rows += 1
        }
        var last = line, pieceEnd = end
        while pieceEnd == contentEnd(last.text) && rows < maxJoinedRows {
            let y = last.lastRow
            guard y + 1 < grid.endRow, continues(reader, y) else { break }
            let next = reader.logicalLine(y + 1)
            let pieceStart = indentEnd(next.text)
            pieceEnd = pieceStart
            while pieceEnd < next.text.count && isPathCharacter(next.text[pieceEnd]) { pieceEnd += 1 }
            if pieceEnd == pieceStart { break }
            joined += next.text[pieceStart..<pieceEnd]
            joinedCells += next.cells(pieceStart..<pieceEnd)
            last = next; rows += 1
        }
        if joined.count == end - start { return alone }
        guard let whole = parse(joined, tapped: tapped, cells: joinedCells) else { return alone }
        guard let alone, alone.candidates != whole.candidates else { return whole }
        return TerminalPathLink(candidates: whole.candidates + alone.candidates, spans: whole.spans)
    }

    /// A path, its line and its rows from a run of path characters, if the tapped character belongs to it.
    static func parse(_ run: [Character], tapped: Int, cells: [TerminalLinkSpan.Cell]) -> TerminalPathLink? {
        var start = 0, end = run.count
        // Sentence punctuation and an enclosing quote are not part of the path.
        while end > start && ".,;'".contains(run[end - 1]) { end -= 1 }
        while start < end && run[start] == "'" { start += 1 }
        guard tapped >= start, tapped < end, end - start <= maxPathLength else { return nil }
        if String(run[start..<end]).contains("://") { return nil }
        // The path ends at its first colon. "grep -n" glues the matched source text on after the location, as in
        // "src/a.ts:42:const x", so whatever follows "path:line[:column]" is not it.
        var lineNumber = 0
        var pathEnd = end
        if let colon = run[start..<end].firstIndex(of: ":") {
            pathEnd = colon
            if let (number, locationEnd) = location(run, colon: colon, end: end) { lineNumber = number; end = locationEnd } else { end = colon }
            if tapped >= end { return nil }
        }
        let path = String(run[start..<pathEnd])
        guard looksLikePath(path) else { return nil }
        return TerminalPathLink(candidates: [TerminalPathCandidate(path: path, line: lineNumber)], spans: TerminalLinkSpan.merge(Array(cells[start..<end])))
    }

    /// `:line` or `:line:column` at `colon`, followed by another colon or the end, as compilers, linters, grep and
    /// agents print it: the line and where the location ends.
    static func location(_ run: [Character], colon: Int, end: Int) -> (Int, Int)? {
        func digits(from index: Int) -> Int {
            var cursor = index
            while cursor < end && run[cursor].isASCII && run[cursor].isNumber { cursor += 1 }
            return cursor - index
        }
        let lineDigits = digits(from: colon + 1)
        guard (1...9).contains(lineDigits), let number = Int(String(run[(colon + 1)..<(colon + 1 + lineDigits)])), number > 0 else { return nil }
        let afterLine = colon + 1 + lineDigits
        if afterLine < end && run[afterLine] == ":" {
            let columnDigits = digits(from: afterLine + 1)
            let afterColumn = afterLine + 1 + columnDigits
            if (1...9).contains(columnDigits) && (afterColumn == end || run[afterColumn] == ":") { return (number, afterColumn) }
        }
        return afterLine == end || run[afterLine] == ":" ? (number, afterLine) : nil
    }

    /// Row y ends a logical line whose last token the next row's first token would not have fitted behind, so a TUI
    /// that breaks lines itself moved it down. Borders and links are never continuations.
    static func continues(_ reader: TerminalUrl.Reader, _ y: Int) -> Bool {
        guard y + 1 < reader.grid.endRow, !reader.wraps(y) else { return false }
        let (next, range) = reader.rowToken(y + 1, fromIndent: true)
        if next.isEmpty || TerminalUrl.hasWebScheme(next) || TerminalUrl.hasBoxDrawing(next) { return false }
        let free = reader.freeCells(y)
        // A path broken inside itself fills the row up to the TUI's own margin; a word wrap that moved a whole word
        // down usually leaves more room, and joining it would glue on that word.
        return free <= maxRightMargin && free <= reader.cellWidth(y + 1, range)
    }

    private static func indentEnd(_ text: [Character]) -> Int {
        var index = 0
        while index < text.count && text[index] == " " { index += 1 }
        return index
    }

    private static func contentEnd(_ text: [Character]) -> Int {
        var end = text.count
        while end > 0 && text[end - 1] == " " { end -= 1 }
        return end
    }

    static func looksLikePath(_ path: String) -> Bool {
        if path.isEmpty || path.contains(":") || path.contains("//") { return false }
        guard let slash = path.lastIndex(of: "/") else { return isFileName(path) }
        // "/", "./", "~/" and "a/" alone name a folder, not a file to show.
        if path.hasSuffix("/") { return false }
        return path[path.index(after: slash)...].contains { $0.isLetter }
    }

    /// A bare file name needs an extension with a letter, so "1.2.3" or "v2.0" do not qualify.
    private static func isFileName(_ name: String) -> Bool {
        let characters = Array(name)
        guard let dot = characters.lastIndex(of: "."), dot > 0 else { return false }
        let ext = characters[(dot + 1)...]
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), ext.contains(where: { $0.isLetter }) else { return false }
        let before = characters[dot - 1]
        return before.isLetter || (before.isASCII && before.isNumber) || before == "_" || before == "-"
    }

    static func isPathCharacter(_ character: Character) -> Bool {
        if "._-/~+@:".contains(character) { return true }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }
}
