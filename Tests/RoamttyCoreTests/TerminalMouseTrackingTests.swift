import XCTest
@testable import RoamttyCore

final class TerminalMouseTrackingTests: XCTestCase {
    private func tracking(_ chunks: String...) -> TerminalMouseTracking {
        var tracking = TerminalMouseTracking()
        for chunk in chunks { tracking.consume(Array(chunk.utf8)) }
        return tracking
    }

    func testMoshResizeFrameKeepsTrackingThroughTheEncodingReset() {
        // What mosh-server sends after a resize while tmux has mouse on.
        let resize = "\u{1b}[r\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[?25l\u{1b}[?1002l\u{1b}[?1002h\u{1b}[?1004l\u{1b}[?1006l\u{1b}[?1006h"
        XCTAssertEqual(tracking("\u{1b}[?1002h\u{1b}[?1006h", resize).mode, 1002)
    }

    func testTmuxModeSequence() {
        XCTAssertEqual(tracking("\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?2004l\u{1b}[?1006h\u{1b}[?1002h").mode, 1002)
        XCTAssertEqual(tracking("\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h").mode, 1003)
        XCTAssertEqual(tracking("\u{1b}[?1000;1006h").mode, 1000)
    }

    func testTrackingResetsAndFullReset() {
        XCTAssertNil(tracking("\u{1b}[?1002h", "\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1001l\u{1b}[?1000l").mode)
        XCTAssertNil(tracking("\u{1b}[?1002h", "\u{1b}c").mode)
        XCTAssertEqual(tracking("\u{1b}[?1002h", "\u{1b}[?1015l\u{1b}[?1006l\u{1b}[?1005l").mode, 1002)
    }

    func testSequencesSplitAcrossChunks() {
        XCTAssertEqual(tracking("\u{1b}", "[?10", "03", "h").mode, 1003)
        var split = TerminalMouseTracking()
        split.consume(Array("\u{1b}[?10".utf8))
        XCTAssertFalse(split.atBoundary)
        split.consume(Array("02h".utf8))
        XCTAssertTrue(split.atBoundary)
    }

    func testIgnoresLookalikes() {
        // Not private modes, intermediates, or text inside an OSC title.
        XCTAssertNil(tracking("\u{1b}[1002h", "\u{1b}[?1002$p", "\u{1b}]0;[?1002h\u{07}").mode)
        XCTAssertNil(tracking("plain 1002h text").mode)
    }

    func testBoundaryWaitsForStringsAndCharacters() {
        var title = TerminalMouseTracking()
        title.consume(Array("\u{1b}]2;roamtty".utf8))
        XCTAssertFalse(title.atBoundary)
        title.consume(Array("\u{1b}\\".utf8))
        XCTAssertTrue(title.atBoundary)

        let wide = Array("终".utf8)
        var character = TerminalMouseTracking()
        character.consume(wide.prefix(2))
        XCTAssertFalse(character.atBoundary)
        character.consume(wide.suffix(1))
        XCTAssertTrue(character.atBoundary)
    }
}
