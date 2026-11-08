import XCTest
@testable import RoamttyCore

final class TerminalScrollInertiaTests: XCTestCase {
    private func run(_ inertia: inout TerminalScrollInertia) -> [Int] {
        var steps = [Int]()
        for frame in 1...600 where !inertia.finished { steps.append(inertia.rowsDown(after: Double(frame) / 60)) }
        return steps
    }

    func testSlowSwipeHasNoInertia() {
        XCTAssertNil(TerminalScrollInertia(rowsPerSecond: 1.5, screenRows: 40))
        XCTAssertNil(TerminalScrollInertia(rowsPerSecond: .nan, screenRows: 40))
    }

    func testFlingSlowsDownAndStopsAtItsDistance() throws {
        var inertia = try XCTUnwrap(TerminalScrollInertia(rowsPerSecond: 30, screenRows: 40))
        XCTAssertEqual(inertia.totalRows, 14) // 30 rows/s × 0.4995 s
        let steps = run(&inertia)
        XCTAssertTrue(inertia.finished)
        XCTAssertEqual(steps.reduce(0, +), 14)
        XCTAssertTrue(steps.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThan(steps.prefix(30).reduce(0, +), steps.dropFirst(30).reduce(0, +), "Most rows go in the first half second")
        XCTAssertEqual(inertia.rowsDown(after: 60), 0)
    }

    func testFastFlingTravelsHalfAScreenUpward() throws {
        var inertia = try XCTUnwrap(TerminalScrollInertia(rowsPerSecond: -400, screenRows: 41))
        XCTAssertEqual(inertia.totalRows, -20)
        let steps = run(&inertia)
        XCTAssertEqual(steps.reduce(0, +), -20)
        XCTAssertTrue(steps.allSatisfy { $0 <= 0 })
        XCTAssertLessThan(steps.count, 200, "A fling ends within a few seconds")
    }

    func testSkippedFramesCatchUp() throws {
        var inertia = try XCTUnwrap(TerminalScrollInertia(rowsPerSecond: 100, screenRows: 40))
        XCTAssertEqual(inertia.rowsDown(after: 10), 20)
        XCTAssertTrue(inertia.finished)
    }
}
