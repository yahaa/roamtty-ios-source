// Checks that the app finds how many lines SwiftTerm's full scrollback has dropped, which keeps a reader's place.
import Foundation
import SwiftTerm

final class Silent: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
let delegate = Silent()
var failures = 0, checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL line \(line) \(name): expected \(expected), got \(actual)") }
}
func text(_ t: Terminal, _ row: Int) -> String? { t.getScrollInvariantLine(row: row)?.translateToString(trimRight: true) }
/// Feeds numbered lines and returns the app's count from `earlier`, as the app works it out after each chunk.
func feed(_ t: Terminal, _ lines: Range<Int>, since earlier: Int) -> Int {
    let chunk = lines.map { "line \($0)\r\n" }.joined()
    t.feed(text: chunk)
    return t.droppedScrollbackLines(since: earlier, fed: chunk.utf8.count)
}

// 5 rows and 20 lines of scrollback keep 25 lines. The first 4 line feeds move the cursor down the screen, the
// next 20 fill the scrollback, and each one after that drops a line.
do {
    let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 20))
    expect(t.droppedScrollbackLines(since: 0, fed: 0), 0, "fresh")
    var dropped = feed(t, 0..<24, since: 0)
    expect(dropped, 0, "just full")
    let top = t.getTopVisibleRow()
    dropped = feed(t, 24..<30, since: dropped)
    // What the view used to go by: once the scrollback is full, the visible top no longer moves.
    expect(t.getTopVisibleRow(), top, "SwiftTerm keeps its top row when full")
    expect(dropped, 6, "dropped once full")
    expect(text(t, dropped), "line 6", "first kept line")
    expect(text(t, dropped - 1), nil, "line before is gone")
    var next = 30
    for size in [1, 3, 7, 40, 1] {
        dropped = feed(t, next..<(next + size), since: dropped); next += size
        expect(dropped, next - 24, "count after \(size) more")
        expect(text(t, dropped), "line \(dropped)", "first kept after \(size) more")
        expect(text(t, dropped - 1), nil, "window start after \(size) more")
    }
    // A stale or wrong earlier answer still finds the window.
    expect(t.droppedScrollbackLines(since: 0, fed: 0), 58, "from zero")
    expect(t.droppedScrollbackLines(since: 70, fed: 0), 58, "from inside")
    expect(t.droppedScrollbackLines(since: 5_000, fed: 0), 58, "from past the end")
    // Clearing the scrollback numbers the lines on screen from 0 again; the cursor's empty row is row 4.
    t.feed(text: "\u{1b}[3J")
    dropped = t.droppedScrollbackLines(since: dropped, fed: 4)
    expect(dropped, 0, "after clearing scrollback")
    dropped = feed(t, 100..<160, since: 58)
    expect(dropped, 40, "count after refill")
    expect(text(t, dropped), "line 136", "first kept after refill")
    expect(text(t, dropped - 1), nil, "window start after refill")
}
// A long chunk without line ends wraps into lines, which drop as well.
do {
    let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 4, scrollback: 6))
    let chunk = String(repeating: "x", count: 10 * 30)
    t.feed(text: chunk)
    let dropped = t.droppedScrollbackLines(since: 0, fed: chunk.utf8.count)
    expect(dropped, 20, "wrapped count")
    expect(text(t, dropped - 1), nil, "wrapped window start")
}

// The app keeps 2000 lines of history, as Android does, through a reset (ESC c) and a resize too.
do {
    let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5))
    t.changeScrollback(2000)
    var dropped = feed(t, 0..<2100, since: 0)
    expect(dropped, 2100 - 4 - 2000, "2000 kept")
    t.feed(text: "\u{1b}c")
    dropped = feed(t, 0..<2100, since: 0)
    expect(dropped, 2100 - 4 - 2000, "2000 kept after reset")
    t.resize(cols: 30, rows: 8)
    dropped = feed(t, 0..<50, since: dropped)
    expect(text(t, dropped + 2000 + 8 - 1) != nil && text(t, dropped + 2000 + 8) == nil, true, "2000 kept after resize")
}

print("\(checks - failures)/\(checks) terminal scrollback checks passed")
exit(failures == 0 ? 0 : 1)
