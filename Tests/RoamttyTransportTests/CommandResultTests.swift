import XCTest
import RoamttyTransport

final class CommandResultTests: XCTestCase {
    func testTextDecodesUTF8AndKeepsTextAroundAStrayByte() {
        let result = CommandResult(output: Data("folder ~/项目\n".utf8) + Data([0xFF]) + Data(" end \n".utf8), status: 0)
        XCTAssertEqual(result.text, "folder ~/项目\n\u{FFFD} end \n")
        XCTAssertEqual(result.trimmedText, "folder ~/项目\n\u{FFFD} end")
        XCTAssertEqual(CommandResult(output: Data(), status: 1).trimmedText, "")
    }
}
