import XCTest
@testable import RoamttyCore

final class TerminalSynchronizedOutputTests: XCTestCase {
    private func change(_ text: String) -> Bool? { TerminalSynchronizedOutput.lastChange(in: Array(text.utf8)[...]) }

    func testFrameThatEndsInTheChunkIsClosed() {
        XCTAssertEqual(change("\u{1b}[?2026h\u{1b}[2Ahello\r\n\u{1b}[?2026l"), false)
        XCTAssertEqual(change("\u{1b}[?2026l\u{1b}[?2026hhello"), true)
    }

    func testChunkWithoutTheModeChangesNothing() {
        XCTAssertNil(change("hello\r\nworld"))
        XCTAssertNil(change("\u{1b}[?25h\u{1b}[?1049l"))
        XCTAssertNil(change("[?2026h without escape"))
        XCTAssertNil(change(""))
    }

    func testModeAtTheStartOfASliceCounts() {
        let bytes = Array("xx\u{1b}[?2026h".utf8)
        XCTAssertEqual(TerminalSynchronizedOutput.lastChange(in: bytes[2...]), true)
        XCTAssertNil(TerminalSynchronizedOutput.lastChange(in: bytes[3...]))
    }
}
