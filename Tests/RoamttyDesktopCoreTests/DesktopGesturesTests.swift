import XCTest
@testable import RoamttyDesktopCore

/// The gesture table in docs/DESKTOP-GESTURES.md, row by row.
final class DesktopGesturesTests: XCTestCase {
    /// A 2000×1000 view showing a 3024×1964 Retina screen: letterboxed left and right.
    private let view = Viewport(viewWidth: 2000, viewHeight: 1000, remoteWidth: 3024, remoteHeight: 1964)

    private func gestures(_ mode: PointerMode = .touch) -> DesktopGestures {
        let g = DesktopGestures(mode: mode); g.viewport = view; return g
    }

    private func tap(_ g: DesktopGestures, _ x: Float, _ y: Float, at t: Int64, id: Int = 0) -> [GestureAction] {
        g.began(id, x, y, time: t) + g.ended(id, x, y, time: t + 60)
    }

    private func buttons(_ actions: [GestureAction]) -> [GestureAction] {
        actions.filter { if case .button = $0 { return true }; return false }
    }

    private func moves(_ actions: [GestureAction]) -> [(Int, Int)] {
        actions.compactMap { if case .moveTo(let x, let y) = $0 { return (x, y) }; return nil }
    }

    private func wheels(_ actions: [GestureAction]) -> [(Int, Int)] {
        actions.compactMap { if case .wheel(let dx, let dy) = $0 { return (dx, dy) }; return nil }
    }

    private func views(_ actions: [GestureAction]) -> [Viewport] {
        actions.compactMap { if case .view(let v) = $0 { return v }; return nil }
    }

    func testViewportMapsToNativePixels() {
        let scale: Float = 1000 / 1964
        XCTAssertEqual(scale, view.scale, accuracy: 1e-6)
        let c = view.toRemote(1000, 500)
        XCTAssertEqual(1512, c.x)
        XCTAssertEqual(982, c.y)
        // The black bars clamp to the edge.
        XCTAssertEqual(0, view.toRemote(10, 500).x)
        XCTAssertFalse(view.contains(10, 500))
        let zoomed = view.zoomed(2, 1000, 500)
        XCTAssertEqual(1512, zoomed.toRemote(1000, 500).x)
        XCTAssertEqual(982, zoomed.toRemote(1000, 500).y)
        XCTAssertEqual(1, view.zoomed(0.5, 0, 0).zoom)
    }

    // MARK: Clicks

    func testTouchTapClicksAtOnceWhereTheFingerLanded() {
        let g = gestures()
        XCTAssertTrue(g.began(0, 1000, 500, time: 0).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], g.ended(0, 1003, 500, time: 80))
        XCTAssertNil(g.tickAt, "nothing waits after a tap")
    }

    func testTrackpadTapClicksAtOnceWhereTheCursorIs() {
        let g = gestures(.mouse)
        g.hostCursor(x: 100, y: 200, time: 0)
        XCTAssertEqual([.button(1, down: true), .button(1, down: false)], tap(g, 900, 500, at: 1000))
        XCTAssertNil(g.tickAt, "the button is not held for a possible drag")
        // Moving straight after the tap only moves: no accidental drag.
        _ = g.began(0, 900, 500, time: 1100)
        let out = g.moved(0, 960, 500, time: 1130)
        XCTAssertTrue(buttons(out).isEmpty, "\(out)")
        XCTAssertEqual(1, moves(out).count)
    }

    func testTouchDoubleTapLandsOnOnePixelDespiteJitter() {
        let g = gestures()
        _ = tap(g, 1000, 500, at: 0)
        let second = tap(g, 1007, 504, at: 160)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], second)
        // Too late, or too far: a tap of its own.
        XCTAssertNotEqual(1512, moves(tap(g, 1007, 504, at: 900)).first?.0)
        _ = tap(g, 1000, 500, at: 2000)
        XCTAssertNotEqual(1512, moves(tap(g, 1030, 500, at: 2150)).first?.0)
    }

    func testTrackpadDoubleTapIsTwoClicksInPlace() {
        let g = gestures(.mouse)
        g.hostCursor(x: 300, y: 300, time: 0)
        let out = tap(g, 900, 500, at: 1000) + tap(g, 906, 503, at: 1150)
        XCTAssertEqual([.button(1, down: true), .button(1, down: false), .button(1, down: true), .button(1, down: false)], out)
    }

    func testTwoFingerTapRightClicks() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0)
        _ = g.began(1, 1100, 500, time: 20)
        _ = g.ended(0, 900, 500, time: 90)
        XCTAssertTrue(g.ended(1, 1100, 500, time: 100).isEmpty, "a second two-finger tap would zoom instead")
        XCTAssertEqual(400, g.tickAt)
        XCTAssertEqual([.button(2, down: true), .button(2, down: false), .feedback(.click)], g.tick(400))
        XCTAssertNil(g.tickAt)

        // Touch mode: at the middle of the two fingers.
        let t = gestures()
        _ = t.began(0, 900, 500, time: 0); _ = t.began(1, 1100, 500, time: 10)
        _ = t.ended(0, 900, 500, time: 80); _ = t.ended(1, 1100, 500, time: 80)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .button(2, down: false), .feedback(.click)], t.tick(380))
    }

    func testAnotherTouchSendsAWaitingRightClickFirst() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        _ = g.ended(0, 900, 500, time: 80); _ = g.ended(1, 1100, 500, time: 80)
        let out = tap(g, 900, 500, at: 200)
        XCTAssertEqual([.button(2, down: true), .button(2, down: false), .button(1, down: true), .button(1, down: false)], buttons(out))
    }

    func testThreeFingerTapMiddleClicks() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1000, 500, time: 10); _ = g.began(2, 1100, 500, time: 20)
        _ = g.ended(0, 900, 500, time: 90); _ = g.ended(1, 1000, 500, time: 95)
        XCTAssertEqual([.button(3, down: true), .button(3, down: false), .feedback(.click)], g.ended(2, 1100, 500, time: 100))
        XCTAssertNil(g.tickAt)
    }

    // MARK: Holds

    func testHoldThenLiftRightClicks() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        XCTAssertEqual(DesktopGestures.HOLD_MS, g.tickAt)
        XCTAssertEqual(false, g.indicator?.armed, "the ring fills while waiting")
        XCTAssertTrue(g.tick(349).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .feedback(.hold)], g.tick(350))
        XCTAssertEqual(true, g.indicator?.armed)
        XCTAssertTrue(g.moved(0, 1004, 500, time: 400).isEmpty, "within the slop it is still a click")
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .button(2, down: false), .feedback(.click)], g.ended(0, 1004, 500, time: 600))
        XCTAssertNil(g.indicator)
    }

    func testTouchHoldThenMoveDragsFromWhereTheFingerLanded() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .feedback(.pickup), .moveTo(x: 1512 + 39, y: 982)],
                       g.moved(0, 1020, 500, time: 400))
        XCTAssertEqual([.moveTo(x: 1512 + 196, y: 982)], g.moved(0, 1100, 500, time: 450))
        XCTAssertEqual([.button(1, down: false)], g.ended(0, 1100, 500, time: 500))
    }

    func testTrackpadHoldThenMoveDragsTheCursor() {
        let g = gestures(.mouse)
        g.hostCursor(x: 500, y: 500, time: 0)
        _ = g.began(0, 900, 500, time: 1000)
        XCTAssertEqual([.feedback(.hold)], g.tick(1350), "the cursor stays where it is")
        let out = g.moved(0, 930, 500, time: 1400)
        XCTAssertEqual([.button(1, down: true), .feedback(.pickup)], Array(out.prefix(2)))
        XCTAssertGreaterThan(moves(out).first?.0 ?? 0, 500)
        XCTAssertEqual([.button(1, down: false)], g.ended(0, 930, 500, time: 1500))
    }

    func testTwoFingerHoldThenMoveRightDrags() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        XCTAssertEqual(DesktopGestures.HOLD2_MS, g.tickAt)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .feedback(.hold)], g.tick(500))
        XCTAssertEqual(2, g.indicator?.fingers)
        let out = g.moved([(0, 900, 530), (1, 1100, 530)], time: 600)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .feedback(.pickup), .moveTo(x: 1512, y: 982 + 58)], out)
        XCTAssertEqual([.button(2, down: false)], g.ended(0, 900, 530, time: 700))
        XCTAssertTrue(g.ended(1, 1100, 530, time: 710).isEmpty)
    }

    // MARK: Moving and scrolling

    func testTouchSlideScrollsWhatIsUnderTheFinger() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        XCTAssertTrue(g.moved(0, 1000, 505, time: 16).isEmpty, "within the slop nothing happens yet")
        let first = g.moved(0, 1000, 530, time: 32)
        XCTAssertEqual(.moveTo(x: 1512, y: 982), first.first, "the host scrolls what is under its cursor: put it under the finger")
        XCTAssertNil(g.tickAt, "a slide is never a hold")
        var out = first
        var y: Float = 530, t: Int64 = 32
        while y < 800 { y += 25; t += 16; out += g.moved(0, 1000, y, time: t) }
        XCTAssertTrue(buttons(out).isEmpty, "a slide presses nothing: \(out)")
        XCTAssertEqual(1, moves(out).count, "the cursor stays put while scrolling")
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertTrue(wheels(out).allSatisfy { $0.1 > 0 && $0.0 == 0 }, "finger down pulls the page down: \(wheels(out))")
        XCTAssertTrue(views(out).isEmpty, "at full size the picture stays put")
        // A flick carries on after lifting, slowing down.
        XCTAssertTrue(buttons(g.ended(0, 1000, y, time: t + 5)).isEmpty, "no click after a slide")
        XCTAssertEqual(t + 5 + DesktopGestures.FRAME_MS, g.tickAt)
        var coast: [(Int, Int)] = []
        while let at = g.tickAt, coast.count < 1000 { coast += wheels(g.tick(at)) }
        XCTAssertGreaterThan(coast.count, 5)
        XCTAssertTrue(coast.allSatisfy { $0.1 > 0 })
        XCTAssertNil(g.tickAt)
    }

    func testTouchSlideStoppedBeforeLiftingDoesNotCoast() {
        let g = gestures()
        _ = g.began(0, 1000, 300, time: 0)
        for i in 1...10 { _ = g.moved(0, 1000, 300 + Float(i) * 20, time: Int64(i) * 16) }
        _ = g.ended(0, 1000, 500, time: 400)
        XCTAssertNil(g.tickAt)
    }

    func testZoomedInTouchSlideMovesThePictureThenScrolls() {
        let g = gestures()
        g.viewport = view.zoomed(2, 1000, 500)
        let before = g.viewport
        _ = g.began(0, 1000, 500, time: 0)
        let pan = g.moved(0, 980, 480, time: 30) + g.moved(0, 960, 460, time: 60)
        XCTAssertFalse(views(pan).isEmpty, "the picture follows the finger, as a zoomed photo")
        XCTAssertTrue(wheels(pan).isEmpty, "inside the picture's slack nothing scrolls: \(pan)")
        XCTAssertLessThan(g.viewport.panY, before.panY)
        // Far past the top edge: the picture stops there and the rest scrolls the host.
        let past = g.moved(0, 960, -3000, time: 90)
        guard case .view(let edge)? = past.first else { return XCTFail("\(past)") }
        XCTAssertEqual(edge, edge.clamped())
        XCTAssertLessThan(wheels(past).last?.1 ?? 0, 0, "past the edge the host scrolls: \(past)")
        XCTAssertTrue(buttons(past).isEmpty)
    }

    func testTouchTwoFingerScrollPutsTheCursorBetweenTheFingers() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        let out = g.moved([(0, 900, 340), (1, 1100, 340)], time: 30)
        XCTAssertEqual(.moveTo(x: 1512, y: 589), out.first)
        XCTAssertFalse(wheels(out).isEmpty)
    }

    func testTrackpadMovesTheCursorFasterTheFasterTheFinger() {
        func travel(_ step: Float, every ms: Int64) -> Int {
            let g = gestures(.mouse)
            g.hostCursor(x: 1000, y: 1000, time: 0)
            _ = g.began(0, 500, 500, time: 1000)
            var x: Float = 500, t: Int64 = 1000, last = 1000
            while x < 800 { x += step; t += ms; if let m = moves(g.moved(0, x, 500, time: t)).last { last = m.0 } }
            return last - 1000
        }
        let slow = travel(2, every: 16), fast = travel(30, every: 16)
        XCTAssertGreaterThan(fast, slow * 3, "slow \(slow), fast \(fast)")
        XCTAssertEqual(0.5, DesktopGestures.pointerGain(10))
        XCTAssertEqual(4, DesktopGestures.pointerGain(100_000))
    }

    func testTwoFingersScrollWithInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        XCTAssertTrue(g.moved([(0, 900, 305), (1, 1100, 305)], time: 16).isEmpty)
        var out: [GestureAction] = []
        var y: Float = 305, t: Int64 = 16
        while y < 500 { y += 20; t += 16; out += g.moved([(0, 900, y), (1, 1100, y)], time: t) }
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertTrue(wheels(out).allSatisfy { $0.1 > 0 && $0.0 == 0 }, "fingers moving down scroll up: \(wheels(out))")
        XCTAssertTrue(buttons(out).isEmpty)
        _ = g.ended(0, 900, y, time: t + 5)
        _ = g.ended(1, 1100, y, time: t + 5)
        XCTAssertEqual(t + 5 + DesktopGestures.FRAME_MS, g.tickAt, "a flick carries on")
        var coast: [(Int, Int)] = []
        var now = t + 5
        while let at = g.tickAt, now < t + 20_000 { now = at; coast += wheels(g.tick(at)) }
        XCTAssertGreaterThan(coast.count, 5)
        XCTAssertTrue(coast.allSatisfy { $0.1 > 0 })
        XCTAssertLessThan(abs(coast.last!.1), abs(coast.first!.1), "it slows down")
        XCTAssertNil(g.tickAt, "and stops")
    }

    func testPauseBeforeLiftingLeavesNoInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        for i in 1...10 { _ = g.moved([(0, 900, 300 + Float(i) * 20), (1, 1100, 300 + Float(i) * 20)], time: Int64(i) * 16) }
        _ = g.ended(0, 900, 500, time: 400); _ = g.ended(1, 1100, 500, time: 400)
        XCTAssertNil(g.tickAt)
    }

    func testANewTouchStopsInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        for i in 1...10 { _ = g.moved([(0, 900, 300 + Float(i) * 20), (1, 1100, 300 + Float(i) * 20)], time: Int64(i) * 16) }
        _ = g.ended(0, 900, 500, time: 165); _ = g.ended(1, 1100, 500, time: 165)
        XCTAssertNotNil(g.tickAt)
        _ = g.began(0, 900, 500, time: 200)
        XCTAssertEqual(200 + DesktopGestures.HOLD_MS, g.tickAt, "only the new touch's hold is pending")
    }

    func testZoomedInTwoFingersStillScrollTheHost() {
        let g = gestures()
        g.viewport = view.zoomed(2, 1000, 500)
        let before = g.viewport
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        let out = g.moved([(0, 860, 460), (1, 1060, 460)], time: 30) + g.moved([(0, 820, 420), (1, 1020, 420)], time: 60)
        XCTAssertTrue(views(out).isEmpty, "the picture stays put: \(out)")
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertEqual(before, g.viewport)
    }

    // MARK: The picture

    func testPinchZoomsAndMovesThePicture() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        let pinch = g.moved([(0, 850, 500), (1, 1150, 500)], time: 30)
        XCTAssertEqual(1, pinch.count)
        XCTAssertEqual(1.5, views(pinch).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertTrue(wheels(pinch).isEmpty && buttons(pinch).isEmpty, "zoom never reaches the host")
        let zoomed = g.viewport
        let pan = g.moved([(0, 800, 500), (1, 1100, 500)], time: 60)
        XCTAssertEqual(zoomed.zoom, views(pan).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertLessThan(views(pan).first?.panX ?? 0, zoomed.panX, "the picture follows the fingers while pinching")
    }

    func testTwoFingerDoubleTapZoomsInAndOut() {
        let g = gestures(.mouse)
        func twoTap(_ t: Int64) -> [GestureAction] {
            g.began(0, 1400, 300, time: t) + g.began(1, 1600, 300, time: t) + g.ended(0, 1400, 300, time: t + 60) + g.ended(1, 1600, 300, time: t + 60)
        }
        XCTAssertTrue(twoTap(0).isEmpty)
        let zoomIn = twoTap(200)
        XCTAssertEqual(2.5, views(zoomIn).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertTrue(buttons(zoomIn).isEmpty, "no right click")
        XCTAssertNil(g.tickAt)
        // The spot under the fingers stays put.
        XCTAssertEqual(Float(view.toRemote(1500, 300).x), Float(g.viewport.toRemote(1500, 300).x), accuracy: 2)
        _ = twoTap(2000)
        let zoomOut = twoTap(2200)
        XCTAssertEqual(1, views(zoomOut).first?.zoom)
        XCTAssertEqual(0, views(zoomOut).first?.panX)
    }

    func testTrackpadZoomedInThePictureFollowsTheCursor() {
        let g = gestures(.mouse)
        g.viewport = view.zoomed(2.5, 1000, 500)
        g.hostCursor(x: 1512, y: 982, time: 0)
        _ = g.began(0, 500, 500, time: 1000)
        var out: [GestureAction] = []
        var x: Float = 500, t: Int64 = 1000
        while x < 900 { x += 20; t += 16; out += g.moved(0, x, 500, time: t) }
        XCTAssertFalse(views(out).isEmpty, "the picture moved to keep the cursor in view")
        let p = g.viewport.toView(g.cursorX, g.cursorY)
        XCTAssertLessThanOrEqual(p.x, 2000 * 0.85 + 1)
    }

    func testTouchDragNearTheEdgeOfAZoomedPictureMovesIt() {
        let g = gestures()
        g.viewport = view.zoomed(2.5, 1000, 500)
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1500, 500, time: 400)
        _ = g.moved(0, 1990, 500, time: 450)
        XCTAssertEqual(450 + DesktopGestures.FRAME_MS, g.tickAt)
        let out = g.tick(466)
        XCTAssertLessThan(views(out).first?.panX ?? 0, view.zoomed(2.5, 1000, 500).panX, "the picture slides left")
        XCTAssertEqual(1, moves(out).count, "the drag follows to what is now under the finger")
        _ = g.ended(0, 1990, 500, time: 500)
        XCTAssertNil(g.tickAt)
    }

    // MARK: Shortcuts

    func testEdgeSwipesPutTheCursorOnTheHostsEdge() {
        // The picture spans x 230…1770 of the 2000-wide view (black bars left and right) and all its height.
        let g = gestures()
        _ = g.began(0, 235, 500, time: 0)
        XCTAssertEqual([.moveTo(x: 0, y: 982), .feedback(.shortcut)], g.moved(0, 270, 502, time: 30))
        XCTAssertTrue(g.moved(0, 500, 502, time: 60).isEmpty, "the rest of the swipe does nothing")
        XCTAssertTrue(g.ended(0, 500, 502, time: 90).isEmpty)

        _ = g.began(0, 1000, 995, time: 1000)
        XCTAssertEqual([.moveTo(x: 1512, y: 1963), .feedback(.shortcut)], g.moved(0, 1000, 960, time: 1030))
        _ = g.ended(0, 1000, 960, time: 1060)

        _ = g.began(0, 1765, 5, time: 2000)
        XCTAssertEqual([.moveTo(x: 3023, y: 0), .feedback(.shortcut)], g.moved(0, 1740, 20, time: 2030), "a corner: the hot corner")
        _ = g.ended(0, 1740, 20, time: 2060)

        // Along the edge is not a swipe in: it scrolls.
        _ = g.began(0, 235, 500, time: 3000)
        XCTAssertEqual(1, moves(g.moved(0, 236, 540, time: 3030)).count)
        XCTAssertFalse(g.moved(0, 236, 560, time: 3060).contains(.feedback(.shortcut)))
        _ = g.ended(0, 236, 560, time: 3090)
    }

    func testTheScreenEdgeOutsideThePictureIsNoEdgeSwipe() {
        // The screen's edge, on the black bar: swiping back starts there, not an edge swipe.
        let g = gestures()
        _ = g.began(0, 5, 500, time: 0)
        let out = g.moved(0, 60, 502, time: 30)
        XCTAssertFalse(out.contains(.feedback(.shortcut)), "\(out)")
    }

    func testThreeFingerSwipes() {
        for (dx, dy, dir) in [(Float(-80), Float(0), SwipeDirection.left), (80, 0, .right), (0, -80, .up), (0, 80, .down)] {
            let g = gestures(.mouse)
            _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1000, 500, time: 0); _ = g.began(2, 1100, 500, time: 0)
            let out = g.moved([(0, 900 + dx, 500 + dy), (1, 1000 + dx, 500 + dy), (2, 1100 + dx, 500 + dy)], time: 50)
            XCTAssertEqual([.swipe(dir), .feedback(.shortcut)], out)
            XCTAssertTrue(g.moved([(0, 900 + 2 * dx, 500 + 2 * dy)], time: 80).isEmpty, "once per swipe")
            _ = g.ended(0, 0, 0, time: 100); _ = g.ended(1, 0, 0, time: 100)
            XCTAssertTrue(g.ended(2, 0, 0, time: 100).isEmpty, "a swipe is no tap")
        }
    }

    func testFourFingersAreLeftToTheSystem() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        _ = g.began(1, 900, 600, time: 450)
        _ = g.began(2, 1000, 600, time: 450)
        _ = g.began(3, 1100, 600, time: 450)
        var out: [GestureAction] = []
        for id in 0...3 { out += g.moved(id, 500, 500, time: 500) + g.ended(id, 500, 500, time: 600) }
        XCTAssertTrue(out.isEmpty, "\(out)")
    }

    // MARK: Odds and ends

    func testASecondFingerEndsADrag() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        XCTAssertEqual([.button(1, down: false)], g.began(1, 900, 500, time: 450))
        XCTAssertTrue(g.moved(0, 1200, 500, time: 500).isEmpty)
        XCTAssertTrue((g.ended(1, 900, 500, time: 550) + g.ended(0, 1200, 500, time: 600)).isEmpty)
    }

    func testTheFingerLeftAfterTwoDoesNothing() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        _ = g.moved([(0, 900, 540), (1, 1100, 540)], time: 30)
        _ = g.ended(1, 1100, 540, time: 60)
        XCTAssertTrue(g.moved(0, 1300, 500, time: 100).isEmpty)
        XCTAssertTrue(g.ended(0, 1300, 500, time: 150).isEmpty)
    }

    func testCancelLetsEverythingGo() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        XCTAssertEqual([.button(1, down: false)], g.cancel())
        XCTAssertNil(g.tickAt)
        XCTAssertNil(g.indicator)
    }

    func testThePhonesCursorStandsWhileItMovesIt() {
        let g = gestures(.mouse)
        g.hostCursor(x: 100, y: 100, time: 0)
        XCTAssertEqual(100, g.cursorX)
        _ = g.began(0, 500, 500, time: 1000)
        _ = g.moved(0, 600, 500, time: 1050)
        let local = g.cursorX
        XCTAssertGreaterThan(local, 100)
        g.hostCursor(x: 100, y: 100, time: 1200)
        XCTAssertEqual(local, g.cursorX, "a late echo does not pull the cursor back")
        g.hostCursor(x: 700, y: 800, time: 2000)
        XCTAssertEqual(700, g.cursorX, "the host moved it itself")
        XCTAssertEqual(800, g.cursorY)
    }
}

final class DesktopSwipeShortcutTests: XCTestCase {
    func testSwipesBecomeEachSystemsShortcut() {
        XCTAssertEqual([DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS)], DesktopSwipeShortcut.frames(.up, os: "windows"))
        XCTAssertEqual([DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP)], DesktopSwipeShortcut.frames(.down, os: "macos"))
        XCTAssertEqual([DesktopProtocol.key(HidUsage.LEFT_CTRL, down: true), DesktopProtocol.key(HidUsage.RIGHT, down: true),
                        DesktopProtocol.key(HidUsage.RIGHT, down: false), DesktopProtocol.key(HidUsage.LEFT_CTRL, down: false)],
                       DesktopSwipeShortcut.frames(.left, os: "macOS"))
        XCTAssertEqual([DesktopProtocol.key(HidUsage.LEFT_CTRL, down: true), DesktopProtocol.key(HidUsage.LEFT_GUI, down: true),
                        DesktopProtocol.key(HidUsage.LEFT, down: true), DesktopProtocol.key(HidUsage.LEFT, down: false),
                        DesktopProtocol.key(HidUsage.LEFT_GUI, down: false), DesktopProtocol.key(HidUsage.LEFT_CTRL, down: false)],
                       DesktopSwipeShortcut.frames(.right, os: "windows"))
        XCTAssertEqual(DesktopProtocol.key(HidUsage.LEFT_ALT, down: true), DesktopSwipeShortcut.frames(.left, os: "linux")[1])
    }
}
