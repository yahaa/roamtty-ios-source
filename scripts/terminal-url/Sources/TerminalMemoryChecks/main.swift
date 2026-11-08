// Real-model lifecycle and exact UTF-8 tail regressions for the app's accessibility export.
import Foundation
import SwiftTerm

final class Silent: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
let delegate = Silent()
var failures = 0, checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(name)") }
}
func makeTerminal(cols: Int = 80, rows: Int = 24) -> Terminal {
    Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 2000))
}
func populate(_ terminal: Terminal) {
    terminal.feed(text: (0..<2200).map { "line \($0) " + String(repeating: "x", count: 60) + "\r\n" }.joined())
}
// Exercise the exact public API used by the app, against its previous full-export contract.
func tail(_ terminal: Terminal, _ limit: Int, kind: Terminal.BufferKind = .active) -> Data {
    terminal.getBufferTailAsData(maxBytes: limit, kind: kind)
}

@inline(never) func releasesModel(resets: Int) -> Bool {
    weak var released: Terminal?
    do {
        let terminal = makeTerminal()
        released = terminal
        populate(terminal)
        for _ in 0..<resets {
            terminal.feed(text: "\u{1b}c")
            populate(terminal)
        }
    }
    return released == nil
}
for resets in [0, 1, 5] {
    for iteration in 0..<10 {
        expect(releasesModel(resets: resets), "model releases with \(resets) resets, iteration \(iteration)")
    }
}

func checkTails(_ terminal: Terminal, _ fixture: String, kind: Terminal.BufferKind = .active) {
    let full = terminal.getBufferAsData(kind: kind)
    for limit in [-1, 0, 1, 2, 3, 4, 5, 7, 16, 63, 1024, 16_384, full.count + 1, Int.max] {
        expect(tail(terminal, limit, kind: kind) == Data(full.suffix(max(0, limit))), "\(fixture) byte suffix \(limit)")
    }
}
do {
    let terminal = makeTerminal(cols: 8, rows: 2)
    expect(terminal.getBufferAsData() == Data("\n\n".utf8), "blank rows export newlines")
    checkTails(terminal, "empty")
    terminal.feed(text: "a  ")
    expect(terminal.getBufferAsData() == Data("a  \n\n".utf8), "export keeps typed spaces and final blank row")
    checkTails(terminal, "trimmed tiny")
    terminal.feed(text: "\r\n中é")
    checkTails(terminal, "multibyte")
    // A byte suffix is allowed to start inside a scalar; String decoding replaces invalid UTF-8.
    expect(tail(terminal, 2) == Data([0xa9, 10]), "tail can split UTF8 scalar")
    terminal.feed(text: "abcdefghijk\r\n\r\nlast   ")
    checkTails(terminal, "wrapped and blank")
    terminal.feed(text: "\u{1b}[?1049hALT中\r\nend")
    checkTails(terminal, "alternate active")
    checkTails(terminal, "alternate explicit", kind: .alt)
    checkTails(terminal, "normal while alternate", kind: .normal)
    terminal.feed(text: "\u{1b}[?1049l")
    checkTails(terminal, "restored normal")
}
do {
    let terminal = makeTerminal()
    populate(terminal)
    checkTails(terminal, "full 2000 scrollback")
    terminal.feed(text: "\u{1b}c")
    populate(terminal)
    checkTails(terminal, "full after reset")
    terminal.resize(cols: 57, rows: 18)
    checkTails(terminal, "reflowed")
}

// A row wider than the requested suffix still uses exactly the full export's byte boundary.
do {
    let terminal = makeTerminal(cols: 20_000, rows: 1)
    terminal.feed(text: String(repeating: "é", count: 19_000))
    checkTails(terminal, "single large multibyte row")
}
// Blank history requires one newline byte per row; do not infer the needed row count from columns.
do {
    let terminal = makeTerminal()
    terminal.feed(text: String(repeating: "\r\n", count: 2200))
    checkTails(terminal, "full blank scrollback")
}

// Timing is evidence, never a pass/fail threshold. Consume bytes so optimized builds retain the work.
@inline(never) func benchmark(_ name: String, iterations: Int, body: () -> Data) {
    var bytes = 0
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations { bytes += body().count }
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    print(String(format: "BENCH %@: %.3f ms / %d exports, %d consumed bytes", name, elapsed, iterations, bytes))
}
let terminal = makeTerminal()
populate(terminal)
benchmark("full export + suffix, 2000 history", iterations: 100) { Data(terminal.getBufferAsData().suffix(16_384)) }
benchmark("accessibility tail, 2000 history", iterations: 100) { tail(terminal, 16_384) }
print("\(checks - failures)/\(checks) terminal memory checks passed")
exit(failures == 0 ? 0 : 1)
