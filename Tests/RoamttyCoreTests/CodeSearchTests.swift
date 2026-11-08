import XCTest
@testable import RoamttyCore

final class CodeSearchTests: XCTestCase {
    func testAndroidEveryCaseInsensitiveHitFixture() {
        let document = SyntaxHighlighter.highlight("Alpha alpha\nbeta ALPHA", Languages.plain)
        XCTAssertEqual(findCodeMatches(document, query: "alpha"), [CodeMatch(row: 0, start: 0, end: 5), CodeMatch(row: 0, start: 6, end: 11), CodeMatch(row: 1, start: 5, end: 10)])
        XCTAssertTrue(findCodeMatches(document, query: "").isEmpty)
    }
    func testUTF16OffsetsNonoverlappingHitsAndNoSyntheticLineNumbers() {
        let document = SyntaxHighlighter.highlight("🙂aaAAA\ntext\n1 real number", Languages.plain)
        XCTAssertEqual(findCodeMatches(document, query: "aa"), [CodeMatch(row: 0, start: 2, end: 4), CodeMatch(row: 0, start: 4, end: 6)])
        XCTAssertEqual(findCodeMatches(document, query: "1"), [CodeMatch(row: 2, start: 0, end: 1)])
        XCTAssertTrue(findCodeMatches(document, query: "2").isEmpty)
        XCTAssertTrue(findCodeMatches(document, query: "text\n1").isEmpty)
    }
    func testSearchLimitAndPreviousNextWrap() {
        let document = SyntaxHighlighter.highlight("x x x\nx x", Languages.plain)
        XCTAssertEqual(findCodeMatches(document, query: "x", limit: 2).count, 2)
        XCTAssertTrue(findCodeMatches(document, query: "x", limit: 0).isEmpty)
        XCTAssertEqual(codeMatchIndex(current: 0, delta: -1, count: 3), 2)
        XCTAssertEqual(codeMatchIndex(current: 2, delta: 1, count: 3), 0)
        XCTAssertEqual(codeMatchIndex(current: 4, delta: -1, count: 0), 0)
    }
}
