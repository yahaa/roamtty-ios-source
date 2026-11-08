import XCTest
@testable import RoamttyCore

final class TerminalDeleteHoldTests: XCTestCase {
    private func deletes(_ hold: inout TerminalDeleteHold, from start: Double, to end: Double, every step: Double) -> [TerminalDeleteHold.Action] {
        stride(from: start, through: end, by: step).map { hold.onDelete(at: $0) }
    }

    /// The timing the iOS 26 keyboard was measured to send, phase by phase.
    func testHeldKeyClearsOnceAndSwallowsEveryLaterRepeat() {
        var hold = TerminalDeleteHold()
        XCTAssertEqual(hold.onDelete(at: 0), .delete)
        // About 500 ms later it repeats every 100 ms, and clears 600 ms into that.
        XCTAssertEqual(deletes(&hold, from: 0.5, to: 1.05, every: 0.1), Array(repeating: .delete, count: 6))
        XCTAssertEqual(hold.onDelete(at: 1.1), .clear)
        XCTAssertEqual(deletes(&hold, from: 1.2, to: 2.6, every: 0.1), Array(repeating: .ignore, count: 15))
        // Then it slows to about 350 ms: still the same hold.
        XCTAssertEqual(deletes(&hold, from: 3, to: 10, every: 0.35), Array(repeating: .ignore, count: 21))
        // After the key is let go, a delete is a delete again.
        XCTAssertEqual(hold.onDelete(at: 11), .delete)
    }

    func testTapsNeverClear() {
        var slow = TerminalDeleteHold()
        XCTAssertFalse(deletes(&slow, from: 0, to: 5, every: 0.3).contains(.clear))
        var fast = TerminalDeleteHold()
        XCTAssertFalse(deletes(&fast, from: 0, to: 5, every: 0.16).contains(.clear))
    }

    func testAShortHoldDoesNotClearAndATapAfterItIsADelete() {
        var hold = TerminalDeleteHold()
        XCTAssertEqual(deletes(&hold, from: 0, to: 0.5, every: 0.05), Array(repeating: .delete, count: 11))
        XCTAssertEqual(hold.onDelete(at: 0.7), .delete)
        XCTAssertEqual(hold.onDelete(at: 0.9), .delete)
    }

    func testAPauseRestartsTheThreshold() {
        var hold = TerminalDeleteHold()
        XCTAssertFalse(deletes(&hold, from: 0, to: 0.55, every: 0.05).contains(.clear))
        XCTAssertEqual(deletes(&hold, from: 0.8, to: 1.35, every: 0.05), Array(repeating: .delete, count: 12))
        XCTAssertEqual(hold.onDelete(at: 1.41), .clear)
    }

    func testOtherInputEndsAClearedHold() {
        var hold = TerminalDeleteHold()
        _ = deletes(&hold, from: 0, to: 0.55, every: 0.05)
        XCTAssertEqual(hold.onDelete(at: 0.6), .clear)
        hold.reset()
        XCTAssertEqual(hold.onDelete(at: 0.7), .delete)
    }

    func testAClockGoingBackStartsAgain() {
        var hold = TerminalDeleteHold()
        _ = deletes(&hold, from: 10, to: 10.55, every: 0.05)
        XCTAssertEqual(hold.onDelete(at: 10.61), .clear)
        XCTAssertEqual(hold.onDelete(at: 1), .delete)
    }

    func testRecognisesTheDeleteKeyBytes() {
        for key in ["\u{7f}", "\u{8}", "\u{1b}[127u", "\u{1b}[127;1u", "\u{1b}[127;1:1u"] {
            XCTAssertTrue(TerminalDeleteHold.isDelete(Data(key.utf8)), key.debugDescription)
        }
        // Modified, released, typed, or several: none is one plain press.
        for other in ["a", "\u{7f}\u{7f}", "\u{1b}[127;5u", "\u{1b}[127;1:3u", "\u{1b}[127;13u", "\u{15}", ""] {
            XCTAssertFalse(TerminalDeleteHold.isDelete(Data(other.utf8)), other.debugDescription)
        }
        XCTAssertEqual(TerminalDeleteHold.clearLine, Data("\u{15}\u{0b}".utf8))
    }
}
