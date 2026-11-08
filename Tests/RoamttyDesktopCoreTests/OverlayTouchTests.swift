import XCTest
@testable import RoamttyDesktopCore

/// The same cases as Android's OverlayTouchTest.
final class OverlayTouchTests: XCTestCase {
    private func touch() -> OverlayTouch { OverlayTouch(slop: 10) }

    func testOffTheBoxIsThePicturesAtOnce() {
        let t = touch()
        XCTAssertEqual(t.down(onBox: false, 0, 0, time: 0), .picture)
        XCTAssertNil(t.holdAt)
        XCTAssertEqual(t.tick(1000), .picture)
        XCTAssertEqual(t.up(time: 1000), .picture)
        XCTAssertEqual(t.owner, OverlayTouch.Owner.none)
    }

    func testATapOnTheBoxGoesToThePicture() {
        let t = touch()
        XCTAssertEqual(t.down(onBox: true, 5, 5, time: 100), .pending)
        XCTAssertEqual(t.holdAt, 100 + OverlayTouch.holdMs)
        XCTAssertEqual(t.moved(8, 7, time: 150), .pending)
        XCTAssertEqual(t.up(time: 180), .picture)
    }

    func testASwipeOnTheBoxGoesToThePicture() {
        let t = touch()
        t.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(t.moved(30, 5, time: 50), .picture)
        // Once the picture's, a later stillness does not take it back.
        XCTAssertEqual(t.tick(1000), .picture)
        XCTAssertEqual(t.moved(30, 5, time: 1000), .picture)
    }

    func testASecondFingerGoesToThePicture() {
        let t = touch()
        t.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(t.otherFinger(), .picture)
    }

    func testAStillHoldTakesTheBox() {
        let t = touch()
        t.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(t.tick(OverlayTouch.holdMs - 1), .pending)
        XCTAssertEqual(t.tick(OverlayTouch.holdMs), .box)
        XCTAssertEqual(t.moved(300, 200, time: 600), .box)
        XCTAssertEqual(t.otherFinger(), .box)
        XCTAssertEqual(t.up(time: 700), .box)
        XCTAssertEqual(t.owner, OverlayTouch.Owner.none)
    }

    func testALateTimerStillGivesTheHoldToTheBox() {
        let t = touch()
        t.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(t.moved(6, 6, time: OverlayTouch.holdMs + 5), .box)
        // The first move after a still hold may go far at once.
        let far = touch()
        far.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(far.moved(100, 80, time: OverlayTouch.holdMs), .box)
        let u = touch()
        u.down(onBox: true, 5, 5, time: 0)
        XCTAssertEqual(u.up(time: OverlayTouch.holdMs + 5), .box)
    }

    func testResetForgetsTheTouch() {
        let t = touch()
        t.down(onBox: true, 5, 5, time: 0)
        t.reset()
        XCTAssertEqual(t.owner, OverlayTouch.Owner.none)
        XCTAssertNil(t.holdAt)
    }
}
