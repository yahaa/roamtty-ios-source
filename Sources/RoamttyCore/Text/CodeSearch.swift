import Foundation

/// UTF-16 ranges in original document rows, excluding any rendered line-number gutter.
public struct CodeMatch: Equatable, Sendable {
    public let row: Int
    public let start: Int
    public let end: Int
    public init(row: Int, start: Int, end: Int) { self.row = row; self.start = start; self.end = end }
}

public func findCodeMatches(_ document: CodeDocument, query: String, limit: Int = 10_000) -> [CodeMatch] {
    guard !query.isEmpty, limit > 0 else { return [] }
    var matches: [CodeMatch] = []
    for (row, line) in document.lines.enumerated() {
        let value = line.text as NSString
        var start = 0
        while start < value.length {
            let found = value.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: value.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            matches.append(CodeMatch(row: row, start: found.location, end: found.location + found.length))
            if matches.count >= limit { return matches }
            start = found.location + found.length
        }
    }
    return matches
}

public func codeMatchIndex(current: Int, delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((current % count + delta % count) % count + count) % count
}
