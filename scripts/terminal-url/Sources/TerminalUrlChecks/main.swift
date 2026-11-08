// Ports Android's TerminalUrlTest onto SwiftTerm: the app's URL finder over the app's SwiftTerm grid adapter.
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
func at(_ t: Terminal, _ column: Int, _ row: Int) -> String? { TerminalUrl.at(SwiftTermTextGrid(terminal: t), column: column, row: row) }
func expect(_ actual: String?, _ expected: String?, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL line \(line) \(name): expected \(expected ?? "nil"), got \(actual ?? "nil")") }
}
func expectTrue(_ value: Bool, _ name: String, line: Int = #line) { checks += 1; if !value { failures += 1; print("FAIL line \(line) \(name)") } }
func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

// onlyTheTappedLinkOpens
do {
    let t = terminal(100, 4, "see https://one.test/a and http://two.test:8080/b?x=1&y=2#part end")
    expect(at(t, 4, 0), "https://one.test/a", "tapped 1")
    expect(at(t, 30, 0), "http://two.test:8080/b?x=1&y=2#part", "tapped 2")
    expect(at(t, 0, 0), nil, "before"); expect(at(t, 23, 0), nil, "between"); expect(at(t, 90, 0), nil, "after")
}
// softWrappedUrlIsWholeFromEveryRow
do {
    let t = terminal(12, 6, "go https://example.test/long/path?q=hello%20world#end")
    for row in 0..<4 { expect(at(t, 5, row), "https://example.test/long/path?q=hello%20world#end", "soft wrap row \(row)") }
}
// tuiWrappedPrUrlIsWholeFromEitherDisplayedRow
do {
    let t = terminal(40, 5, "  PR: \u{1b}[4m#127\u{1b}[0m (\u{1b}[4mhttps://github.com/yahaa/\u{1b}[0m\r\n  \u{1b}[4mroamtty/pull/127\u{1b}[0m)\r\n  APK: ready")
    for col in 12..<37 { expect(at(t, col, 0), "https://github.com/yahaa/roamtty/pull/127", "tui pr row0 col \(col)") }
    for col in 2..<18 { expect(at(t, col, 1), "https://github.com/yahaa/roamtty/pull/127", "tui pr row1 col \(col)") }
    expect(at(t, 11, 0), nil, "paren"); expect(at(t, 37, 0), nil, "after"); expect(at(t, 0, 1), nil, "indent"); expect(at(t, 18, 1), nil, "close")
}
// tuiCursorPositionedUrlKeepsItsQueryAndFragment
do {
    let t = terminal(40, 5, "\u{1b}[1;3HPR: (\u{1b}[4mhttps://github.com/yahaa/\u{1b}[0m\u{1b}[2;3H\u{1b}[4mroamtty/pull/127?x=1&y=2#discussion\u{1b}[0m)")
    expect(at(t, 10, 1), "https://github.com/yahaa/roamtty/pull/127?x=1&y=2#discussion", "cursor positioned")
}
// tuiWrappedUrlAllowsColorChangesAndWideCharacters
do {
    let t = terminal(40, 5, "中文 (\u{1b}[4;31mhttps://example.test/\u{1b}[0m\r\n  \u{1b}[4;32m中文/path\u{1b}[0m)")
    expect(at(t, 8, 0), "https://example.test/中文/path", "wide 0"); expect(at(t, 2, 1), "https://example.test/中文/path", "wide 1"); expect(at(t, 3, 1), "https://example.test/中文/path", "wide 1b")
}
// tuiWrappedUrlKeepsCombiningMarksAtTheLastColumn
do {
    let t = terminal(17, 5, "(\u{1b}[4mhttps://t.test/e\u{301}\u{1b}[0m\r\n  \u{1b}[4m/tail\u{1b}[0m)")
    expect(at(t, 16, 0), "https://t.test/e\u{301}/tail", "combining 0"); expect(at(t, 3, 1), "https://t.test/e\u{301}/tail", "combining 1")
}
// tuiWrappedUrlNeverConsumesAnotherUrl
do {
    var t = terminal(40, 5, "(\u{1b}[4mhttps://one.test/\u{1b}[0m\r\n  \u{1b}[4mhttps://two.test/path\u{1b}[0m)")
    expect(at(t, 5, 0), nil, "other url 0"); expect(at(t, 8, 1), "https://two.test/path", "other url 1")
    t = terminal(40, 5, "(\u{1b}[4mhttps://one.test/\u{1b}[0m\r\n  \u{1b}[4mhttps://\u{1b}[0m\r\n  \u{1b}[4mtwo.test/path\u{1b}[0m)")
    expect(at(t, 5, 0), nil, "other url b0"); expect(at(t, 5, 1), nil, "other url b1")
}
// incompleteOrBrokenStyledLinkNeverOpensItsPrefix
for tail in ["  \u{1b}[4mpath\u{1b}[0m", "  plain prose)", "  \u{1b}[4mpath has spaces\u{1b}[0m)", "\r\n  \u{1b}[4mpath\u{1b}[0m)"] {
    let t = terminal(40, 6, "(\u{1b}[4mhttps://one.test/\u{1b}[0m\r\n" + tail)
    expect(at(t, 5, 0), nil, "broken styled \(tail.debugDescription)")
}
// styledProseDoesNotHideAnIndependentUrl
expect(at(terminal(60, 4, "(\u{1b}[4msee https://one.test\u{1b}[0m)"), 9, 0), "https://one.test", "styled prose")
// tuiWrappedLinkSurvivesInScrollback
do {
    let t = terminal(40, 3, "(\u{1b}[4mhttps://github.com/\u{1b}[0m\r\n  \u{1b}[4myahaa/roamtty/\u{1b}[0m\r\n  \u{1b}[4mpull/127\u{1b}[0m)\r\none\r\ntwo\r\nthree")
    expect(at(t, 5, -3), "https://github.com/yahaa/roamtty/pull/127", "scrollback -3"); expect(at(t, 5, -1), "https://github.com/yahaa/roamtty/pull/127", "scrollback -1")
}
// styledSoftWrapDoesNotDiscardRealOrAmbiguousSpaces
expect(at(terminal(21, 5, "(\u{1b}[4mhttps://example.co/中文\u{1b}[0m)"), 5, 0), nil, "ambiguous styled wide")
expect(at(terminal(20, 5, "(\u{1b}[4mhttps://one.test/a   b\u{1b}[0m)"), 5, 0), nil, "styled spaces")
// closedStyledLinkDoesNotConsumeTheFollowingRow
do {
    let t = terminal(40, 5, "(\u{1b}[4mhttps://one.test/\u{1b}[0m)\r\n  \u{1b}[4mnext\u{1b}[0m)")
    expect(at(t, 5, 0), "https://one.test/", "closed 0"); expect(at(t, 3, 1), nil, "closed 1")
}
// multipleStyledLinksKeepTheirOwnParenthesesAndCellPositions
do {
    let t = terminal(100, 4, "中文 e\u{301} (note) (\u{1b}[4mhttps://one.test/a_(b)\u{1b}[0m) (\u{1b}[4mhttps://two.test/c\u{1b}[0m)")
    expect(at(t, 17, 0), "https://one.test/a_(b)", "multi 1"); expect(at(t, 48, 0), "https://two.test/c", "multi 2")
    expect(at(t, 14, 0), nil, "multi gap"); expect(at(t, 39, 0), nil, "multi gap 2")
}
// tuiWrappedLinkLimitsNeverOpenItsPrefix
expect(at(terminal(80, 200, "(\u{1b}[4mhttps://one.test/" + rep("\u{1b}[0m\r\n  \u{1b}[4ma", 130) + "\u{1b}[0m)"), 5, 0), nil, "row limit")
expect(at(terminal(100, 200, "(\u{1b}[4mhttps://one.test/" + rep("a", 8200) + "\u{1b}[0m)"), 5, 0), nil, "length limit")
// hardWrappedBareUrlIsWholeFromEitherRow
for style in ["", "\u{1b}[4m"] {
    let t = terminal(40, 5, "  PR: " + style + "https://github.com/yahaa/\u{1b}[0m\r\n  " + style + "roamtty/pull/135\u{1b}[0m\r\n")
    for col in 6..<31 { expect(at(t, col, 0), "https://github.com/yahaa/roamtty/pull/135", "hard row0 \(col) \(style.isEmpty)") }
    for col in 2..<18 { expect(at(t, col, 1), "https://github.com/yahaa/roamtty/pull/135", "hard row1 \(col) \(style.isEmpty)") }
    expect(at(t, 18, 1), nil, "hard after")
}
// tuiIndentedUnderlinedUrlIsWholeFromEveryRow
do {
    let rows = ["https://accounts.google.com/o/oauth2/auth?", "access_type=offline&client_id=107100606059", "1-tmhssin2h21lcre235vtolojh4g403ep.apps.go",
        "ogleusercontent.com&code_challenge=5h3QeZa", "lJ95XrRbFJvWmYgE63kAuG-gHDursxB9rAB4&code_", "challenge_method=S256&prompt=consent&redir",
        "ect_uri=https%3A%2F%2Fantigravity.google%2", "Foauth-callback&response_type=code&scope=h", "ttps%3A%2F%2Fwww.googleapis.com%2Fauth%2Fc",
        "loud-platform+https%3A%2F%2Fwww.googleapis", ".com%2Fauth%2Fuserinfo.email+https%3A%2F%2", "Fwww.googleapis.com%2Fauth%2Fuserinfo.prof",
        "ile+https%3A%2F%2Fwww.googleapis.com%2Faut", "h%2Fcclog+https%3A%2F%2Fwww.googleapis.com", "%2Fauth%2Fexperimentsandconfigs+https%3A%2",
        "F%2Fwww.googleapis.com%2Fauth%2Faicode+ope", "nid&state=jyiNUdcGeMnVnfmq9LF7Zg"]
    var text = "\r\n Your browser should open automatically.\r\n\r\n"
    for row in rows { text += " \u{1b}[4m\u{1b}[34m" + row + "\u{1b}[0m\u{1b}[39m\u{1b}[49m\r\n" }
    text += "\r\n If you aren't automatically redirected,\r\n"
    let t = terminal(44, 40, text), url = rows.joined()
    for (r, row) in rows.enumerated() { for col in [1, 10, row.count] { expect(at(t, col, r + 3), url, "agy row \(r) col \(col)") } }
}
// hardWrappedUrlStopsAtTuiRuleBelowIt
do {
    let t = terminal(44, 8, "\u{1b}[4mhttps://accounts.google.com/o/oauth2/auth?a\u{1b}[0m\r\n\u{1b}[4mccess_type=offline&state=abc\u{1b}[0m\r\n" + rep("\u{2500}", 44) + "\r\n")
    for row in 0..<2 { expect(at(t, 3, row), "https://accounts.google.com/o/oauth2/auth?access_type=offline&state=abc", "rule row \(row)") }
}
// fullWidthUrlRowJoinsAShortIndentedContinuation
do {
    let t = terminal(45, 6, rep("x", 50) + "\u{1b}[H\u{25cf}\u{1b}[1X\u{1b}[CPR:\u{1b}[1X\u{1b}[Chttps://github.com/yahaa/roamtty/pull/1\u{1b}[2;1H \u{1b}[1X\u{1b}[C71\u{1b}[K\r\n\r\n* Brewed")
    for row in 0..<2 { expect(at(t, row == 0 ? 20 : 2, row), "https://github.com/yahaa/roamtty/pull/171", "full width row \(row)") }
}
// hardWrappedUrlGluedToALabelIsWholeFromEitherRow
do {
    let t = terminal(45, 4, "  PR\u{ff1a}https://github.com/yahaa/roamtty/pull/1\u{1b}[2;1H  71\u{1b}[K\r\n")
    expect(at(t, 20, 0), "https://github.com/yahaa/roamtty/pull/171", "glued 0"); expect(at(t, 2, 1), "https://github.com/yahaa/roamtty/pull/171", "glued 1")
    expect(at(t, 2, 0), nil, "glued label")
}
// hardWrappedUrlIgnoresBlankCellsAfterItsFirstFragment
expect(at(terminal(40, 5, "  PR: https://github.com/yahaa/\r\n  roamtty/pull/135\r\n"), 35, 0), nil, "blank after fragment")
// hardWrapFollowedByASoftWrapKeepsTheWholeUrl
do {
    let url = "https://github.com/yahaa/roamtty/pull/135/files/aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let t = terminal(40, 6, "  PR: https://github.com/yahaa/\r\n  roamtty/pull/135/files/aaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n")
    expectTrue(SwiftTermTextGrid(terminal: t).wraps(1), "row 1 soft wraps")
    expectTrue(!SwiftTermTextGrid(terminal: t).wraps(0), "row 0 does not soft wrap")
    for row in 0..<3 { expect(at(t, row == 0 ? 10 : 3, row), url, "hard+soft row \(row)") }
}
// hardWrappedUrlJoinsWideContinuationsByCellWidth
expect(at(terminal(20, 4, "https://x.test/a/b/c\r\n\u{4e2d}\u{6587}"), 3, 0), "https://x.test/a/b/c\u{4e2d}\u{6587}", "wide continuation")
// overlongHardWrappedUrlNeverOpensItsFirstFragment
do {
    var text = "see https://one.test/\r\n"
    for _ in 0..<100 { text += "  " + rep("a", 100) + "\r\n" }
    expect(at(terminal(105, 140, text), 8, 0), nil, "overlong")
}
// urlFollowedByShortProseRowIsNotExtended
do {
    let t = terminal(40, 5, "see https://one.test/a\r\nnext line\r\n")
    expect(at(t, 6, 0), "https://one.test/a", "short prose"); expect(at(t, 1, 1), nil, "short prose row")
}
// hardLineBreakDoesNotJoinUrls
do {
    let t = terminal(40, 4, "https://one.test\r\nhttps://two.test")
    expect(at(t, 3, 0), "https://one.test", "break 1"); expect(at(t, 3, 1), "https://two.test", "break 2"); expect(at(t, 20, 0), nil, "break gap")
}
// wideCombiningAndColoredTextKeepCellPositions
do {
    let t = terminal(80, 4, "中文🙂 e\u{301} \u{1b}[32mhttps://example.test/中文\u{1b}[0m done")
    expect(at(t, 8, 0), nil, "wide before"); expect(at(t, 9, 0), "https://example.test/中文", "wide start")
    expect(at(t, 33, 0), "https://example.test/中文", "wide end"); expect(at(t, 34, 0), nil, "wide after")
}
// punctuationAndMarkdownWrappersAreNotPartOfUrl
do {
    let t = terminal(100, 4, "[docs](https://example.test/a_(b)). https://two.test/path，继续")
    expect(at(t, 10, 0), "https://example.test/a_(b)", "markdown"); expect(at(t, 33, 0), nil, "markdown punct")
    expect(at(t, 40, 0), "https://two.test/path", "fullwidth comma"); expect(at(t, 57, 0), nil, "after comma")
}
// apostrophesRemainPartOfUrlPathsQueriesAndFragments
for url in ["https://example.test/Guns_N'_Roses", "https://example.test/rockin'", "https://example.test/?name=O'Brien#it's-here"] {
    let t = terminal(100, 4, "see " + url + " end")
    for col in 4..<(4 + url.count) { expect(at(t, col, 0), url, "apostrophe \(url) \(col)") }
    expect(at(t, 4 + url.count, 0), nil, "apostrophe after")
}
// enclosingSingleQuotesAreExcludedButInnerApostrophesRemain
do {
    let url = "https://example.test/Guns_N'_Roses"
    var t = terminal(100, 4, "see '" + url + "'. end")
    for col in 5..<(5 + url.count) { expect(at(t, col, 0), url, "quoted \(col)") }
    expect(at(t, 4, 0), nil, "open quote"); expect(at(t, 5 + url.count, 0), nil, "close quote"); expect(at(t, 6 + url.count, 0), nil, "dot")
    t = terminal(100, 4, "'https://example.test/path!' and ('https://two.test/rockin'')")
    expect(at(t, 4, 0), "https://example.test/path!", "quoted bang"); expect(at(t, 39, 0), "https://two.test/rockin'", "quoted rockin")
}
// apostrophesSurviveAutomaticAndTuiLineWrapping
expect(at(terminal(20, 5, "https://example.test/Guns_N'_Roses"), 8, 1), "https://example.test/Guns_N'_Roses", "apostrophe soft wrap")
do {
    let t = terminal(40, 5, "(\u{1b}[4mhttps://example.test/Guns_N\u{1b}[0m\r\n  \u{1b}[4m'_Roses\u{1b}[0m)")
    expect(at(t, 2, 0), "https://example.test/Guns_N'_Roses", "apostrophe tui 0"); expect(at(t, 2, 1), "https://example.test/Guns_N'_Roses", "apostrophe tui 1")
}
// adjacentQuotedItemsDoNotBecomeOneUrl
for separator in [",", ";"] {
    let text = "['https://one.test/a'" + separator + "'https://two.test/b']"
    let t = terminal(100, 4, text)
    let two = text.distance(from: text.startIndex, to: text.range(of: "https://two")!.lowerBound)
    let sep = text.distance(from: text.startIndex, to: text.range(of: separator)!.lowerBound)
    expect(at(t, 5, 0), "https://one.test/a", "items 1"); expect(at(t, two + 5, 0), "https://two.test/b", "items 2"); expect(at(t, sep, 0), nil, "items sep")
}
do {
    let t = terminal(100, 4, "['https://one.test/a','plain text']")
    expect(at(t, 5, 0), "https://one.test/a", "items plain"); expect(at(t, 25, 0), nil, "items plain text")
}
// localAndIpv6UrlsAndUppercaseSchemeWork
do {
    let t = terminal(100, 4, "HTTP://localhost:3000/ http://127.0.0.1:8080/ http://[::1]:3000/")
    expect(at(t, 0, 0), "HTTP://localhost:3000/", "upper"); expect(at(t, 23, 0), "http://127.0.0.1:8080/", "ipv4"); expect(at(t, 46, 0), "http://[::1]:3000/", "ipv6")
}
// scrolledTranscriptUrlsRemainClickable
do {
    let t = terminal(40, 3, "https://old.test\r\none\r\ntwo\r\nthree")
    expect(at(t, 5, -1), "https://old.test", "transcript"); expect(at(t, 5, 0), nil, "transcript row 0")
}
// alternateScreenUsesItsOwnContent
expect(at(terminal(40, 4, "https://old.test\u{1b}[?1049h\u{1b}[Hhttps://tui.test"), 5, 0), "https://tui.test", "alternate")
// invalidCellsAndNonWebTextAreIgnored
do {
    let t = terminal(100, 4, "file:///tmp/a javascript:alert(1) https:///path https://")
    for col in 0..<100 { expect(at(t, col, 0), nil, "invalid \(col)") }
    expect(at(t, -1, 0), nil, "neg col"); expect(at(t, 100, 0), nil, "big col"); expect(at(t, 0, -1), nil, "neg row"); expect(at(t, 0, 4), nil, "big row")
}
// hugeWrappedOutputDoesNotOpenATruncatedUrl
expect(at(terminal(20, 200, "https://example.test/" + rep("a", 3500)), 4, 0), nil, "huge")
// ambiguousWideCharacterWrapNeverOpensATruncatedUrl
do {
    let t = terminal(20, 4, "https://example.co/中文")
    expect(at(t, 0, 0), nil, "ambiguous 0"); expect(at(t, 0, 1), nil, "ambiguous 1")
}
// Opening a link percent-encodes only what is outside ASCII.
expect(terminalLinkTarget("https://example.test/中文?q=a%20b")?.absoluteString, "https://example.test/%E4%B8%AD%E6%96%87?q=a%20b", "link target")
expect(terminalLinkTarget("javascript:alert(1)")?.absoluteString, nil, "link target scheme")

// agentWrappedUrlEndsAtItsShortLastRowWhateverLongLineFollows (roamtty #275)
do {
    let t = terminal(46, 8, "  PR: \u{1b}[4;33mhttps://github.com/yahaa/roamtty/pull/27\u{1b}[0m\r\n  \u{1b}[4;33m5\u{1b}[0m\r\n" +
        "  安装包：Roamtty-tap-path-20261103-release-de\r\n  bugsigned.apk\r\n")
    expect(at(t, 20, 0), "https://github.com/yahaa/roamtty/pull/275", "short last row 0")
    expect(at(t, 2, 1), "https://github.com/yahaa/roamtty/pull/275", "short last row 1")
    expect(at(t, 10, 2), nil, "short last row: the next line")
}
// agentWrappedUrlStopsAtFullWidthTextGluedToItsTail
do {
    let t = terminal(46, 8, "  新版本已可安装：http://192.0.2.20:18780/#and\r\n  roid（77c9886）\r\n")
    expect(at(t, 30, 0), "http://192.0.2.20:18780/#android", "glued tail 0")
    expect(at(t, 3, 1), "http://192.0.2.20:18780/#android", "glued tail 1")
    expect(at(t, 8, 1), nil, "glued tail text")
}

// Android's TerminalPathTest: file paths, with their line, under a tap.
func path(_ t: Terminal, _ column: Int, _ row: Int) -> TerminalPathLink? { TerminalPath.at(SwiftTermTextGrid(terminal: t), column: column, row: row) }
func expectPath(_ link: TerminalPathLink?, _ expected: String?, line expectedLine: Int = 0, rows: Set<Int>? = nil, fallback: String? = nil,
                _ name: String, line: Int = #line) {
    checks += 1
    guard let expected else {
        if link != nil { failures += 1; print("FAIL line \(line) \(name): expected nil, got \(link!.path)") }
        return
    }
    guard let link else { failures += 1; print("FAIL line \(line) \(name): expected \(expected), got nil"); return }
    var problems: [String] = []
    if link.path != expected { problems.append("path \(link.path)") }
    if link.line != expectedLine { problems.append("line \(link.line)") }
    if let rows, link.rows != rows { problems.append("rows \(link.rows.sorted())") }
    let actualFallback = link.candidates.count > 1 ? link.candidates[1].path : nil
    if actualFallback != fallback { problems.append("fallback \(actualFallback ?? "nil")") }
    if !problems.isEmpty { failures += 1; print("FAIL line \(line) \(name): " + problems.joined(separator: ", ")) }
}
// compilerErrorOpensAtItsLine
do {
    let t = terminal(80, 4, "src/Post.tsx:42:7 - error TS2322: Type")
    for col in 0..<17 { expectPath(path(t, col, 0), "src/Post.tsx", line: 42, rows: [0], "compiler col \(col)") }
    expectPath(path(t, 17, 0), nil, "after location"); expectPath(path(t, 20, 0), nil, "message")
}
// grepSourceTextAfterTheLocationIsNotPartOfThePath
do {
    let t = terminal(80, 4, "src/a.ts:42:const value = 1\r\nREADME.md:Usage notes\r\nlib/b.kt:7:3:fun x()")
    expectPath(path(t, 3, 0), "src/a.ts", line: 42, "grep"); expectPath(path(t, 10, 0), "src/a.ts", line: 42, "grep line")
    expectPath(path(t, 13, 0), nil, "the source text is not the path")
    expectPath(path(t, 2, 1), "README.md", "grep without line"); expectPath(path(t, 11, 1), nil, "grep text")
    expectPath(path(t, 2, 2), "lib/b.kt", line: 7, "grep with column")
}
// stackTracesAndQuotesKeepOnlyThePath
do {
    let t = terminal(80, 4, "    at run (/home/v/app/index.js:10:5)\r\n  File \"/srv/a.py\", line 3")
    expectPath(path(t, 20, 0), "/home/v/app/index.js", line: 10, "stack trace")
    expectPath(path(t, 10, 1), "/srv/a.py", "python")
}
// bareNamesNeedAnExtension
do {
    let t = terminal(80, 4, "edit README.md, Makefile and v2.0 or 1.2.3 then ./run done.")
    expectPath(path(t, 6, 0), "README.md", "bare name")
    expectPath(path(t, 17, 0), nil, "Makefile"); expectPath(path(t, 30, 0), nil, "v2.0"); expectPath(path(t, 37, 0), nil, "1.2.3")
    expectPath(path(t, 50, 0), "./run", "./run"); expectPath(path(t, 0, 0), nil, "edit")
}
// urlsAndFoldersAreNotFiles
do {
    let t = terminal(80, 4, "see http://x.test/a.js and ~/code/ and 12:30")
    expectPath(path(t, 10, 0), nil, "url"); expectPath(path(t, 30, 0), nil, "folder"); expectPath(path(t, 41, 0), nil, "time")
}
// softWrappedPathMarksEveryRow
do {
    let t = terminal(10, 4, "x app/src/main/Long.kt:9 y")
    let link = path(t, 3, 1)
    expectPath(link, "app/src/main/Long.kt", line: 9, rows: [0, 1, 2], "soft wrap")
    expectTrue(link?.covers(row: 2) == true && link?.covers(row: 3) == false, "soft wrap covers")
}
// pathATuiBrokeAcrossRowsIsJoinedWithThePieceAsFallback
do {
    let t = terminal(30, 6, "  app/src/main/kotlin/io/iterm\r\n  ux/app/ui/MobileTerminalCli\r\n  ent.kt:51:5 done\r\nnext")
    let pieces = ["app/src/main/kotlin/io/iterm", "ux/app/ui/MobileTerminalCli", "ent.kt"]
    for row in 0..<3 {
        expectPath(path(t, 4, row), "app/src/main/kotlin/io/itermux/app/ui/MobileTerminalClient.kt", line: 51, rows: [0, 1, 2],
                   fallback: pieces[row], "hard wrap row \(row)")
    }
    expectPath(path(t, 15, 2), nil, "hard wrap: done")
}
// wordWrappedPathIsNotGluedToTheWordBeforeIt
expectPath(path(terminal(40, 4, "  Edited the files and then\r\n  docs/design/dev-bridge-145-v2.html\r\n"), 5, 1),
           "docs/design/dev-bridge-145-v2.html", rows: [1], "word wrap")
// separateShortLinesAreNotJoined
expectPath(path(terminal(40, 4, "src/a.ts\r\nsrc/b.ts\r\n"), 2, 1), "src/b.ts", rows: [1], "short lines")
// wideTextBeforeAPathShiftsItsCells
expectPath(path(terminal(40, 4, "修改了 src/a.ts 文件"), 9, 0), "src/a.ts", "wide text before")

// Spans: the cells a press marks (Android's TerminalLink.spans as row, start, end triples).
func flat(_ spans: [TerminalLinkSpan]?) -> [Int] { (spans ?? []).flatMap { [$0.row, $0.start, $0.end] } }
func expectSpans(_ actual: [TerminalLinkSpan]?, _ expected: [Int], _ name: String, line: Int = #line) {
    checks += 1
    if flat(actual) != expected { failures += 1; print("FAIL line \(line) \(name): expected \(expected), got \(flat(actual))") }
}
do {
    let t = terminal(80, 4, "src/Post.tsx:42:7 - error TS2322: Type")
    for col in [0, 8, 16] { expectSpans(path(t, col, 0)?.spans, [0, 0, 17], "compiler spans \(col)") }
    let g = terminal(80, 4, "src/a.ts:42:const value = 1\r\nREADME.md:Usage notes\r\nlib/b.kt:7:3:fun x()")
    expectSpans(path(g, 3, 0)?.spans, [0, 0, 11], "grep spans"); expectSpans(path(g, 2, 1)?.spans, [1, 0, 9], "grep plain spans")
    expectSpans(path(g, 2, 2)?.spans, [2, 0, 12], "grep column spans")
    expectSpans(path(terminal(80, 4, "    at run (/home/v/app/index.js:10:5)"), 20, 0)?.spans, [0, 12, 37], "trace spans")
    expectSpans(path(terminal(80, 4, "edit README.md, Makefile"), 6, 0)?.spans, [0, 5, 14], "bare name spans")
    expectSpans(path(terminal(10, 4, "x app/src/main/Long.kt:9 y"), 3, 1)?.spans, [0, 2, 10, 1, 0, 10, 2, 0, 4], "soft wrap spans")
    let hard = terminal(30, 6, "  app/src/main/kotlin/io/iterm\r\n  ux/app/ui/MobileTerminalCli\r\n  ent.kt:51:5 done\r\nnext")
    for row in 0..<3 { expectSpans(path(hard, 4, row)?.spans, [0, 2, 30, 1, 2, 29, 2, 2, 13], "hard wrap spans \(row)") }
    expectSpans(path(terminal(40, 4, "  Edited the files and then\r\n  docs/design/dev-bridge-145-v2.html\r\n"), 5, 1)?.spans, [1, 2, 36], "word wrap spans")
    expectSpans(path(terminal(40, 4, "修改了 src/a.ts 文件"), 9, 0)?.spans, [0, 7, 15], "wide text spans")
    func link(_ t: Terminal, _ c: Int, _ r: Int) -> TerminalWebLink? { TerminalUrl.link(SwiftTermTextGrid(terminal: t), column: c, row: r) }
    expectSpans(link(terminal(100, 4, "see https://one.test/a. end"), 6, 0)?.spans, [0, 4, 22], "url spans")
    let pr = terminal(40, 5, "  PR: \u{1b}[4m#127\u{1b}[0m (\u{1b}[4mhttps://github.com/yahaa/\u{1b}[0m\r\n  \u{1b}[4mroamtty/pull/127\u{1b}[0m)\r\n  APK: ready")
    expectSpans(link(pr, 2, 1)?.spans, [0, 12, 37, 1, 2, 18], "parenthesized spans")
    let agent = terminal(46, 8, "  PR: \u{1b}[4;33mhttps://github.com/yahaa/roamtty/pull/27\u{1b}[0m\r\n  \u{1b}[4;33m5\u{1b}[0m\r\n" +
        "  安装包：Roamtty-tap-path-20261103-release-de\r\n  bugsigned.apk\r\n")
    expectSpans(link(agent, 2, 1)?.spans, [0, 6, 46, 1, 2, 3], "hard wrapped url spans")
    expectSpans(link(terminal(12, 6, "go https://example.test/long/path?q=hello%20world#end"), 5, 1)?.spans,
                [0, 3, 12, 1, 0, 12, 2, 0, 12, 3, 0, 12, 4, 0, 5], "soft wrapped url spans")
}

print("\(checks - failures)/\(checks) terminal URL checks passed")
exit(failures == 0 ? 0 : 1)
