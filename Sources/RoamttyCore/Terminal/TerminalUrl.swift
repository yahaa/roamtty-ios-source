// Behavioral port of Roamtty Android's TerminalUrl.java and TerminalTextLine.java: the web URL under a tapped
// terminal cell, across soft wraps, TUI hard wraps and Markdown-style "label (url)" links.
import Foundation

/// One terminal cell as the URL finder reads it. A wide character's first cell has width 2 and its stub width 0.
public struct TerminalTextCell: Equatable, Sendable {
    public var text: String
    public var width: Int
    public var underlined: Bool
    public init(_ text: String, width: Int = 1, underlined: Bool = false) { self.text = text; self.width = width; self.underlined = underlined }
    public static let blank = TerminalTextCell(" ")
}

/// The rows the URL finder may read. Rows are numbered from `firstRow` up to (not including) `endRow`; history rows
/// may be negative. `wraps(row)` says the row soft-wraps into the next.
public protocol TerminalTextGrid {
    var columns: Int { get }
    var firstRow: Int { get }
    var endRow: Int { get }
    func cells(_ row: Int) -> [TerminalTextCell]
    func wraps(_ row: Int) -> Bool
}

/// The cells of one grid row a link covers: `start` up to `end` (exclusive), as columns.
public struct TerminalLinkSpan: Equatable, Sendable {
    public let row: Int
    public let start: Int
    public let end: Int
    public init(row: Int, start: Int, end: Int) { self.row = row; self.start = start; self.end = end }

    /// One character's cells, in reading order, merged into a span per run on a row.
    struct Cell { let row: Int; let column: Int; let width: Int }
    static func merge(_ cells: [Cell]) -> [TerminalLinkSpan] {
        var spans: [TerminalLinkSpan] = []
        for cell in cells {
            if let last = spans.last, last.row == cell.row, last.end == cell.column {
                spans[spans.count - 1] = TerminalLinkSpan(row: last.row, start: last.start, end: cell.column + cell.width)
            } else {
                spans.append(TerminalLinkSpan(row: cell.row, start: cell.column, end: cell.column + cell.width))
            }
        }
        return spans
    }
}

/// A tapped web link and the cells it covers, so a press can mark exactly those.
public struct TerminalWebLink: Equatable, Sendable {
    public let url: String
    public let spans: [TerminalLinkSpan]
}

/// Finds web URLs at terminal cell positions.
public enum TerminalUrl {
    static let maxLinkRows = 128
    static let maxLinkLength = 8192

    public static func at(_ grid: TerminalTextGrid, column: Int, row: Int) -> String? { link(grid, column: column, row: row)?.url }

    /// The URL under a cell with the cells it covers.
    public static func link(_ grid: TerminalTextGrid, column: Int, row: Int) -> TerminalWebLink? {
        guard column >= 0, column < grid.columns, row >= grid.firstRow, row < grid.endRow else { return nil }
        let reader = Reader(grid)
        if let rendered = reader.parenthesizedLink(column: column, row: row) { return rendered.link }
        if let hardWrapped = reader.hardWrappedUrl(column: column, row: row) { return hardWrapped.link }
        let line = reader.logicalLine(row)
        let offset = line.offset(atCell: line.cell(column: column, row: row))
        var next = 0
        while let (start, matchEnd) = findUrl(line.text, from: next) {
            if offset < start { return nil }
            let candidateEnd = quotedItemEnd(line.text, start: start, end: matchEnd)
            next = candidateEnd // Resume after this item, including separately quoted URLs.
            if offset >= candidateEnd { continue }
            // The logical-line reader is bounded. Never open a URL cut off by its scan limit.
            if candidateEnd == line.text.count && grid.wraps(line.lastRow) { return nil }
            let end = trimEnd(line.text, start: start, end: candidateEnd)
            if offset >= end || reader.endsAtAmbiguousWrap(line, end: candidateEnd) { return nil }
            return validatedUrl(String(line.text[start..<end])).map { TerminalWebLink(url: $0, spans: TerminalLinkSpan.merge(line.cells(start..<end))) }
        }
        return nil
    }

    // MARK: Matching

    /// `https?://` followed by characters a URL may hold: not spaces, separators, controls, `<>"\``, or the
    /// full-width punctuation that ends a URL in Chinese prose.
    static func isUrlCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if "\t\n\u{0B}\u{0C}\r ".unicodeScalars.contains(scalar) { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control: return false
        default: break
        }
        return !"<>\"`，。！？；：、（）【】《》“”‘’".contains(character)
    }

    static func hasWebScheme<C: Collection>(_ text: C) -> Bool where C.Element == Character {
        func starts(_ prefix: String) -> Bool {
            var index = text.startIndex
            for expected in prefix {
                guard index != text.endIndex, text[index].lowercased() == String(expected) else { return false }
                index = text.index(after: index)
            }
            return true
        }
        return starts("http://") || starts("https://")
    }

    /// The next `https?://…` match at or after `from`, as character offsets.
    static func findUrl(_ text: [Character], from: Int) -> (Int, Int)? {
        var index = max(0, from)
        while index < text.count {
            if text[index] == "h" || text[index] == "H" {
                for scheme in ["https://", "http://"] where scheme.count < text.count - index {
                    let candidate = text[index..<(index + scheme.count)]
                    guard candidate.map({ $0.lowercased() }).joined() == scheme else { continue }
                    var end = index + scheme.count
                    while end < text.count && isUrlCharacter(text[end]) { end += 1 }
                    if end > index + scheme.count { return (index, end) }
                }
            }
            index += 1
        }
        return nil
    }

    /// The whole of `url` is a web URL with an authority, as Java's `URI` parses it.
    static func validatedUrl(_ url: String) -> String? {
        let characters = Array(url)
        guard let (start, end) = findUrl(characters, from: 0), start == 0, end == characters.count else { return nil }
        let rest = url[url.range(of: "://")!.upperBound...]
        let authorityEnd = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard !authority.isEmpty else { return nil }
        // Java's URI rejects these anywhere; brackets belong to an IPv6 host only.
        let illegal = Set("{}|\\^`".unicodeScalars)
        if url.unicodeScalars.contains(where: illegal.contains) { return nil }
        if rest[authorityEnd...].contains(where: { $0 == "[" || $0 == "]" }) { return nil }
        if authority.contains("[") || authority.contains("]") {
            guard authority.hasPrefix("["), let close = authority.firstIndex(of: "]"),
                  authority[authority.index(after: close)...].allSatisfy({ $0 == ":" || $0.isASCII && $0.isNumber }) else { return nil }
        }
        if rest.filter({ $0 == "#" }).count > 1 { return nil }
        let scalars = Array(url.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "%" {
            guard index + 2 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit, scalars[index + 2].properties.isASCIIHexDigit else { return nil }
        }
        return url
    }

    static func quotedItemEnd(_ text: [Character], start: Int, end: Int) -> Int {
        guard start > 0, text[start - 1] == "'" else { return end }
        var index = start
        while index + 2 < end {
            // Separately quoted list items provide an explicit boundary; internal apostrophes such as Guns_N'_Roses
            // and a trailing apostrophe in rockin' remain URL characters.
            if text[index] == "'" && (text[index + 1] == "," || text[index + 1] == ";") && text[index + 2] == "'" { return index + 1 }
            index += 1
        }
        return end
    }

    static func trimEnd(_ text: [Character], start: Int, end initial: Int) -> Int {
        var end = initial
        guard end > start, ".,;:!?)]}'".contains(text[end - 1]) else { return end }
        let opening: [Character] = ["(", "[", "{"], closing: [Character] = [")", "]", "}"]
        var balance = [0, 0, 0]
        for index in start..<end {
            if let open = opening.firstIndex(of: text[index]) { balance[open] += 1 }
            if let close = closing.firstIndex(of: text[index]) { balance[close] -= 1 }
        }
        while end > start {
            let last = text[end - 1]
            if ".,;:!?".contains(last) { end -= 1 } else if let bracket = closing.firstIndex(of: last), balance[bracket] < 0 { end -= 1; balance[bracket] += 1 }
            // Apostrophes are legal URL characters. Strip only an enclosing quote paired with one immediately before
            // the scheme; punctuation inside that pair belongs to the URL.
            else if last == "'" && start > 0 && text[start - 1] == "'" { return end - 1 } else { break }
        }
        return end
    }

    static func webPrefix(_ text: [Character]) -> Bool {
        if hasWebScheme(text) { return true }
        let lower = text.map { $0.lowercased() }.joined()
        return "http://".hasPrefix(lower) || "https://".hasPrefix(lower)
    }

    static func hasBoxDrawing(_ text: [Character]) -> Bool {
        text.contains { $0.unicodeScalars.first.map { (0x2500...0x259F).contains($0.value) } ?? false }
    }

    /// A matched but incomplete rendered link must not fall back to opening its first fragment.
    struct Match {
        let url: String?
        var cells: [TerminalLinkSpan.Cell] = []
        var link: TerminalWebLink? { url.map { TerminalWebLink(url: $0, spans: TerminalLinkSpan.merge(cells)) } }
    }

    /// A row's characters with the cells each starts at, as Termux keeps them: a wide character takes one entry for
    /// its two cells, a blank cell reads as a space.
    struct Row {
        var text: [Character] = []
        var widths: [Int] = []
        var startColumns: [Int] = []
        var underlines: [Bool] = []
        init(_ cells: [TerminalTextCell], columns: Int) {
            for column in 0..<columns {
                let cell = column < cells.count ? cells[column] : .blank
                underlines.append(cell.underlined)
                if cell.width == 0 && widths.last == 2 && startColumns.last == column - 1 { continue }
                let character = cell.text.isEmpty || cell.text == "\0" ? " " : Character(cell.text)
                text.append(character); widths.append(max(1, cell.width)); startColumns.append(column)
            }
        }
        var spaceUsed: Int { text.count }
        var contentLength: Int {
            var end = text.count
            while end > 0 && text[end - 1] == " " { end -= 1 }
            return end
        }
        func findStartOfColumn(_ column: Int) -> Int {
            for index in startColumns.indices where column < startColumns[index] + widths[index] { return index }
            return text.count
        }
        func underlined(_ column: Int) -> Bool { column >= 0 && column < underlines.count && underlines[column] }
    }

    /// A bounded logical line, preserving terminal cells across soft wraps.
    struct LogicalLine {
        let text: [Character]
        let widths: [Int]
        let firstRow: Int
        let lastRow: Int
        let columns: Int
        func cell(column: Int, row: Int) -> Int { (row - firstRow) * columns + column }
        /// The grid cell of each character in `range`.
        func cells(_ range: Range<Int>) -> [TerminalLinkSpan.Cell] {
            var cell = widths[0..<range.lowerBound].reduce(0, +)
            return range.map { index in
                defer { cell += widths[index] }
                let row = min(cell / max(1, columns), lastRow - firstRow)
                return TerminalLinkSpan.Cell(row: firstRow + row, column: cell - row * columns, width: widths[index])
            }
        }
        func offset(atCell cell: Int) -> Int {
            var width = 0
            for index in text.indices {
                if width + widths[index] > cell { return index }
                width += widths[index]
            }
            return text.count
        }
    }

    final class Reader {
        let grid: TerminalTextGrid
        private var rows: [Int: Row] = [:]
        private var wrapFlags: [Int: Bool] = [:]
        init(_ grid: TerminalTextGrid) { self.grid = grid }
        var columns: Int { grid.columns }

        func row(_ y: Int) -> Row {
            if let row = rows[y] { return row }
            let row = Row(grid.cells(y), columns: columns)
            rows[y] = row
            return row
        }
        func wraps(_ y: Int) -> Bool {
            if let value = wrapFlags[y] { return value }
            let value = grid.wraps(y)
            wrapFlags[y] = value
            return value
        }

        func logicalLine(_ row: Int) -> LogicalLine {
            var first = row, last = row
            while first > grid.firstRow && row - first < 64 && wraps(first - 1) { first -= 1 }
            while last < grid.endRow - 1 && last - first < 128 && wraps(last) { last += 1 }
            var text: [Character] = [], widths: [Int] = []
            for y in first...last { let line = self.row(y); text += line.text; widths += line.widths }
            return LogicalLine(text: text, widths: widths, firstRow: first, lastRow: last, columns: columns)
        }

        func endsAtAmbiguousWrap(_ line: LogicalLine, end: Int) -> Bool {
            // A wide glyph can wrap early, leaving a blank final cell. The buffer cannot distinguish that padding
            // from a real space before prose, so neither join it nor open a partial URL.
            guard end + 1 < line.text.count, line.text[end] == " ", line.widths[end + 1] == 2 else { return false }
            let cells = line.widths[0..<end].reduce(0, +)
            return cells % line.columns == line.columns - 1
        }

        // MARK: "label (url)" links

        func parenthesizedLink(column: Int, row: Int) -> Match? {
            // Markdown TUIs render "label (url)" with only the URL underlined. They can wrap with explicit
            // newlines/cursor moves and indentation, which carry no terminal soft-wrap flag. Use both the enclosing
            // punctuation and the link's style, never arbitrary adjacent text.
            let tapped = self.row(row)
            var styleColumn = column
            if column > 0 && tapped.findStartOfColumn(column) == tapped.findStartOfColumn(column - 1) { styleColumn -= 1 }
            guard tapped.underlined(styleColumn) else { return nil }
            let first = max(grid.firstRow, row - TerminalUrl.maxLinkRows + 1)
            var y = row
            while y >= first {
                let line = self.row(y)
                var lastOpening = line.spaceUsed - 1
                while lastOpening >= 0 && line.text[lastOpening] != "(" { lastOpening -= 1 }
                if lastOpening >= 0 {
                    for index in 0...lastOpening {
                        let cell = line.startColumns[index]
                        if line.text[index] == "(" && cell + 1 < columns && !line.underlined(cell) && line.underlined(cell + 1),
                           let match = readParenthesizedLink(startColumn: cell + 1, startRow: y, tappedColumn: column, tappedRow: row) {
                            return match
                        }
                    }
                }
                y -= 1
            }
            return nil
        }

        private func readParenthesizedLink(startColumn: Int, startRow: Int, tappedColumn: Int, tappedRow: Int) -> Match? {
            var url: [Character] = []
            var cells: [TerminalLinkSpan.Cell] = []
            var tapped = false
            var completeUrl: String?
            var y = startRow
            rows: while y < grid.endRow && y - startRow < TerminalUrl.maxLinkRows {
                let line = self.row(y)
                var offset = line.findStartOfColumn(y == startRow ? startColumn : 0)
                if y != startRow && !wraps(y - 1) {
                    // Layout padding is allowed only at the row boundary, not inside a URL fragment.
                    while offset < line.spaceUsed && line.text[offset] == " " { offset += 1 }
                    if offset == line.spaceUsed { break }
                    if TerminalUrl.hasWebScheme(line.text[offset...]) { break }
                }
                while offset < line.spaceUsed {
                    let character = line.text[offset], cell = line.startColumns[offset], width = line.widths[offset]
                    let linkStyle = line.underlined(cell)
                    if character == ")" && !linkStyle {
                        completeUrl = TerminalUrl.validatedUrl(String(url))
                        break rows
                    }
                    if character == " " {
                        if wraps(y) { break rows }
                        if line.text[offset...].contains(where: { $0 != " " }) { break rows }
                        break
                    }
                    if !linkStyle { break rows }
                    url.append(character)
                    cells.append(TerminalLinkSpan.Cell(row: y, column: cell, width: width))
                    if url.count <= 8 && !TerminalUrl.webPrefix(url) { return nil }
                    if y == tappedRow && tappedColumn >= cell && tappedColumn < cell + width { tapped = true }
                    if url.count > TerminalUrl.maxLinkLength { break rows }
                    offset += 1
                }
                y += 1
            }
            return tapped ? Match(url: completeUrl, cells: cells) : nil
        }

        // MARK: Hard-wrapped bare URLs

        /// A row's first whitespace-free token (after its indent when `fromIndent`) and its character range.
        func rowToken(_ y: Int, fromIndent: Bool) -> (token: [Character], range: Range<Int>) {
            let text = self.row(y).text
            var start = 0
            if fromIndent { while start < text.count && text[start] == " " { start += 1 } }
            var end = start
            while end < text.count && text[end] != " " { end += 1 }
            return (Array(text[start..<end]), start..<end)
        }

        func cellWidth(_ y: Int, _ range: Range<Int>) -> Int { range.reduce(0) { $0 + row(y).widths[$1] } }

        func freeCells(_ y: Int) -> Int {
            let line = row(y)
            return columns - line.widths[0..<line.contentLength].reduce(0, +)
        }

        private func lastToken(_ y: Int) -> [Character]? {
            let line = row(y)
            let text = line.text[0..<line.contentLength]
            guard !text.isEmpty else { return nil }
            if let space = text.lastIndex(of: " ") { return Array(text[(space + 1)...]) }
            return Array(text)
        }

        /// The row ends in a token that the next row's first token would not have fitted behind.
        private func continues(_ y: Int) -> Bool {
            guard y + 1 < grid.endRow, lastToken(y) != nil else { return false }
            let soft = wraps(y)
            let (next, range) = rowToken(y + 1, fromIndent: !soft)
            if next.isEmpty || TerminalUrl.hasWebScheme(next) || TerminalUrl.hasBoxDrawing(next) { return false }
            return soft || freeCells(y) <= cellWidth(y + 1, range)
        }

        /// The URL inside a token, which a label can precede without a space, as in "PR：https://…".
        private func schemeTail(_ token: [Character]?) -> [Character]? {
            guard let token else { return nil }
            var index = 0
            while index + 7 <= token.count {
                if TerminalUrl.hasWebScheme(token[index...]) { return Array(token[index...]) }
                index += 1
            }
            return nil
        }

        /// TUIs hard-wrap long bare URLs with a newline plus indentation, so no soft-wrap flag marks the join. A URL
        /// token that fills its row continues with the next row's first token; without this only the first fragment
        /// (".../pull/1" of ".../pull/135") would open.
        func hardWrappedUrl(column: Int, row: Int) -> Match? {
            var top = row
            while top >= max(grid.firstRow, row - TerminalUrl.maxLinkRows) {
                if let token = schemeTail(lastToken(top)), continues(top), let match = join(from: top, first: token, column: column, row: row) {
                    return match
                }
                if top < row && !continues(top) { break }
                top -= 1
            }
            return nil
        }

        private func join(from top: Int, first: [Character], column: Int, row: Int) -> Match? {
            let topLine = self.row(top)
            let topStart = topLine.contentLength - first.count
            var url = first
            var cells = (topStart..<topLine.contentLength).map { TerminalLinkSpan.Cell(row: top, column: topLine.startColumns[$0], width: topLine.widths[$0]) }
            // Index of the tapped character in the joined URL, or -1.
            var tapped = -1
            var hardWrapped = false
            if top == row {
                let offset = topLine.findStartOfColumn(column)
                if offset >= topStart && offset < topLine.contentLength { tapped = offset - topStart }
            }
            // A link broken inside itself fills each row up to the TUI's edge. A continuation row that stops short of
            // where the first row ended is the link's end, whatever long word follows it.
            let topFree = freeCells(top)
            var y = top
            while y + 1 < grid.endRow && y - top < TerminalUrl.maxLinkRows && continues(y) && (y == top || freeCells(y) <= topFree + 1) {
                var (next, range) = rowToken(y + 1, fromIndent: !wraps(y))
                // Text glued after the link on its last row, such as "（abc）", is not part of it.
                let cut = next.firstIndex { !TerminalUrl.isUrlCharacter($0) }
                if let cut { next = Array(next[..<cut]); range = range.lowerBound..<(range.lowerBound + cut) }
                if !wraps(y) { hardWrapped = true }
                if y + 1 == row {
                    let offset = self.row(row).findStartOfColumn(column)
                    if range.contains(offset) { tapped = url.count + offset - range.lowerBound }
                }
                url += next
                let nextLine = self.row(y + 1)
                cells += range.map { TerminalLinkSpan.Cell(row: y + 1, column: nextLine.startColumns[$0], width: nextLine.widths[$0]) }
                if url.count > TerminalUrl.maxLinkLength { return tapped >= 0 ? Match(url: nil) : nil }
                if cut != nil || range.upperBound < self.row(y + 1).contentLength { break }
                y += 1
            }
            // Plain terminal soft wraps are read by the ordinary matcher.
            guard hardWrapped, tapped >= 0 else { return nil }
            let end = TerminalUrl.trimEnd(url, start: 0, end: url.count)
            if tapped >= end { return nil } // Trailing punctuation such as a closing parenthesis.
            guard let valid = TerminalUrl.validatedUrl(String(url[0..<end])) else { return nil }
            return Match(url: valid, cells: Array(cells.prefix(end)))
        }
    }
}

/// Where a tapped web URL opens: its percent-encoded form, so non-ASCII paths still make a valid `URL`.
public func terminalLinkTarget(_ link: String) -> URL? {
    // Existing escapes stay as they are; only characters outside ASCII are encoded.
    let encoded = link.unicodeScalars.map { scalar -> String in
        scalar.isASCII ? String(scalar) : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
    }.joined()
    guard let url = URL(string: encoded), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return url
}
