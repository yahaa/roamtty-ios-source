// Checks that the app blanks the half a wide character leaves behind when output overwrites the other half.
import Foundation
import SwiftTerm

final class Silent: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
let delegate = Silent()
var failures = 0, checks = 0

func terminal(_ columns: Int, _ text: String) -> Terminal {
    let t = Terminal(delegate: delegate, options: TerminalOptions(cols: columns, rows: 3, scrollback: 10))
    t.feed(text: text)
    return t
}
/// Row 0 as SwiftTerm's view draws it: a wide character covers the next cell, and any other right half is a block.
func drawn(_ t: Terminal) -> String {
    let line = t.getLine(row: 0)!
    var text = "", col = 0
    while col < t.cols {
        let cell = line[col]
        if cell.width == 0 { text += "█"; col += 1; continue }
        let ch = t.getCharacter(for: cell)
        text += ch == "\0" ? " " : String(ch)
        col += Int(cell.width)
    }
    return String(text.reversed().drop(while: { $0 == " " }).reversed())
}
func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL line \(line) \(name): expected \(expected), got \(actual)") }
}

// The diff mosh-server sent for a line of Chinese redrawn one column to the left: it leaves the old last cell alone.
do {
    let t = terminal(46, "x所以修正前后的数字不能直接对比。\r\n  验证结果：\r\n\u{1b}[1;1H所以修正前后的数字不能直接对比。\u{1b}[2;11H\u{1b}[K")
    expect(drawn(t), "所以修正前后的数字不能直接对比。█", "unrepaired")
    expect(t.blankSplitWideCharacters(), true, "mosh shift repaired")
    expect(drawn(t), "所以修正前后的数字不能直接对比。", "mosh shift")
}
// A narrow character over the left half leaves the right half as a block.
do {
    let t = terminal(10, "对比\rA")
    expect(t.blankSplitWideCharacters(), true, "left half changed")
    expect(drawn(t), "A 比", "left half")
}
// A narrow character over the right half is hidden by the left half until it is blanked.
do {
    let t = terminal(10, "对比\u{1b}[1;2Hx")
    expect(drawn(t), "对比", "hidden")
    expect(t.blankSplitWideCharacters(), true, "right half changed")
    expect(drawn(t), " x比", "right half")
}
// A wide character written one column over breaks both of its neighbours.
do {
    let t = terminal(10, "对比。\u{1b}[1;2H比")
    expect(t.blankSplitWideCharacters(), true, "shifted changed")
    expect(drawn(t), " 比 。", "shifted")
}
// The blank keeps the colours of the text it sits in, not SwiftTerm's inverted background.
do {
    let t = terminal(10, "\u{1b}[48;5;237mx对比\r对比")
    _ = t.blankSplitWideCharacters()
    let blank = t.getLine(row: 0)![4]
    expect(blank.attribute.bg, Attribute.Color.ansi256(code: 237), "blank colours")
    expect(blank.attribute.style, CharacterStyle.none, "blank style")
}
// Intact wide characters, and an orphan at the start of a row, are handled without touching the rest.
do {
    let t = terminal(20, "中文 mixed 文字")
    expect(t.blankSplitWideCharacters(), false, "intact")
    expect(drawn(t), "中文 mixed 文字", "intact text")
    let u = terminal(10, "对比\u{1b}[1;1H\u{1b}[P")
    expect(drawn(u), "█比", "deleted left half")
    expect(u.blankSplitWideCharacters(), true, "row start changed")
    expect(drawn(u), " 比", "row start")
}

print("\(checks - failures)/\(checks) terminal wide cell checks passed")
exit(failures == 0 ? 0 : 1)
