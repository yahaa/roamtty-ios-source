import Foundation
import XCTest
@testable import RoamttyCore

final class PluginInstallLogTests: XCTestCase {
    func testFragmentedUTF8AndMarkersAreDecodedOnlyAsCompleteLines() {
        var log = PluginInstallLog()
        let bytes = Array("准备安装\r\n__ITERMUX_SUDO_FAILED__\nretry ready".utf8)
        for byte in bytes { log.append(Data([byte])) }
        log.finish()
        XCTAssertEqual(log.lines, ["准备安装", "retry ready"])
        XCTAssertFalse(log.text.contains("__ITERMUX_"))
    }

    func testLongRunningOutputRetainsRecentLinesAndBoundsAnUnterminatedLine() {
        var log = PluginInstallLog()
        for index in 0..<1_000 { log.append(Data("line \(index)\n".utf8)) }
        XCTAssertEqual(log.lines.count, 300)
        XCTAssertEqual(log.lines.first, "line 700")
        XCTAssertEqual(log.lines.last, "line 999")
        XCTAssertEqual(log.text.components(separatedBy: "\n").first, "line 986")
        log.append(Data(repeating: 97, count: 1_000_000))
        log.finish()
        XCTAssertLessThan(log.lines.last!.utf8.count, 4_200)
        XCTAssertTrue(log.lines.last!.hasSuffix("…"))
        log.append(Data("\nnext line\n".utf8))
        XCTAssertEqual(log.lines.last, "next line")
    }
}
