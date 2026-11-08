import XCTest
@testable import RoamttyCore

/// Android PetShortcutArcTest.kt's viewport and gesture fixtures, in portable coordinates.
final class TerminalShortcutArcTests: XCTestCase {
    private func arc(centerY: Double = 800, top: Double = 0, bottom: Double = 2_000) -> TerminalShortcutArc {
        TerminalShortcutArc.layout(count: 8, centerY: centerY, top: top, bottom: bottom,
                                   maxRadius: 330, minRadius: 210, spacing: 125)
    }

    func testRoomyViewportUsesTheFullHalfTurnAtTheLargestRadius() {
        let layout = arc()
        XCTAssertEqual(layout.radius, 330)
        XCTAssertEqual(layout.angles.first!, 260, accuracy: 0.01)
        XCTAssertEqual(layout.angles.last!, 100, accuracy: 0.01)
        XCTAssertEqual((layout.angles[3] + layout.angles[4]) / 2, 180, accuracy: 0.01)
    }

    func testEveryItemStaysInsideTheViewport() {
        let layout = arc(centerY: 340, top: 120, bottom: 820)
        for index in 0..<8 {
            let offset = layout.itemOffset(at: index)
            let y = 340 + offset.y
            XCTAssertGreaterThanOrEqual(y, 119.9)
            XCTAssertLessThanOrEqual(y, 820.1)
            XCTAssertLessThanOrEqual(offset.x, 0.01)
        }
    }

    func testShortViewportShrinksTheCircle() {
        let layout = arc(centerY: 300, top: 100, bottom: 500)
        XCTAssertLessThan(layout.radius, 330)
        XCTAssertGreaterThan(layout.angles.first! - layout.angles.last!, 100)
    }

    func testItemsRunTopToBottomOnTheLeft() {
        let layout = arc()
        let ys = layout.angles.indices.map { layout.itemOffset(at: $0).y }
        XCTAssertEqual(ys.sorted(), ys)
    }

    func testHoverFollowsAShortFlickAndExtendsBeyondTheRing() {
        let layout = arc()
        for index in layout.angles.indices {
            let offset = layout.itemOffset(at: index)
            XCTAssertEqual(layout.hoveredItem(x: offset.x * 0.6, y: offset.y * 0.6), index)
        }
        let first = layout.itemOffset(at: 0)
        XCTAssertEqual(layout.hoveredItem(x: first.x * 1.5, y: first.y * 1.5), 0)
    }

    func testNoHoverOverThePetOrAwayFromTheArc() {
        let layout = arc()
        XCTAssertNil(layout.hoveredItem(x: -40, y: 10))
        XCTAssertNil(layout.hoveredItem(x: 300, y: 0))
        XCTAssertNil(layout.hoveredItem(x: -layout.radius * 0.419, y: 0))
    }

    func testFunctionSubmenuFitsLandscapeAndSingleItemStaysToTheLeft() {
        let layout = TerminalShortcutArc.layout(count: 12, centerY: 230, top: 24, bottom: 336,
                                               maxRadius: 170, minRadius: 72, spacing: 43)
        XCTAssertEqual(layout.angles.count, 12)
        for index in layout.angles.indices {
            let offset = layout.itemOffset(at: index)
            XCTAssertGreaterThanOrEqual(230 + offset.y, 23.99)
            XCTAssertLessThanOrEqual(230 + offset.y, 336.01)
            XCTAssertEqual(layout.hoveredItem(x: offset.x * 0.6, y: offset.y * 0.6), index)
        }
        let single = TerminalShortcutArc.layout(count: 1, centerY: 150, top: 0, bottom: 300,
                                               maxRadius: 100, minRadius: 72, spacing: 43)
        XCTAssertEqual(single.angles, [180])
        XCTAssertEqual(single.itemOffset(at: 0).x, -100, accuracy: 0.001)
        XCTAssertEqual(single.hoveredItem(x: -60, y: 0), 0)
        XCTAssertNil(single.hoveredItem(x: 60, y: 0))
    }

    func testEmptyAndInvalidLayoutDoesNotCreateHitTargets() {
        for count in [0, -1] {
            let empty = TerminalShortcutArc.layout(count: count, centerY: 150, top: 0, bottom: 300,
                                                  maxRadius: 100, minRadius: 72, spacing: 43)
            XCTAssertEqual(empty.angles, [])
            XCTAssertNil(empty.hoveredItem(x: -60, y: 0))
        }
        let invalid = TerminalShortcutArc.layout(count: 8, centerY: 150, top: 0, bottom: 300,
                                                maxRadius: 0, minRadius: 0, spacing: 43)
        XCTAssertEqual(invalid.angles, [])
    }
}
