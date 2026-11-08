import XCTest
@testable import RoamttyDesktopCore

/// The phone's split of a frame's latency, against a host clock 5 s ahead of the phone's; mirrors Android's LatencyMeterTest.
final class LatencyMeterTests: XCTestCase {
    private let skew: Int64 = 5_000_000

    /// A ping at `t1` (phone) taking `up` there and `down` back, answered at once.
    private func ping(_ m: LatencyMeter, _ t1: Int64, _ up: Int64, _ down: Int64) {
        m.onPong(t1: t1, t2: t1 + up + skew, t3: t1 + up + skew, t4: t1 + up + down)
    }

    func testSplitsAFrameAcrossTheHostTheNetworkAndThePhone() {
        let m = LatencyMeter()
        ping(m, 0, 3_000, 3_000)
        m.onHostTiming(["frames": 30, "capture_us": 4000, "convert_us": 0, "encode_us": 6000, "encoder": "nvenc"])
        // Captured at phone time 100 ms, encoded 10 ms later, 7 ms on the way, 5 ms decoding, 9 ms to the screen.
        m.onReceived(frame: 1, captureUs: 100_000 + skew, encodedUs: 110_000 + skew, recvUs: 117_000)
        m.onDecoded(frame: 1, decodedUs: 122_000)
        m.onRendered(frame: 1, renderedUs: 131_000)
        let l = m.take()!
        XCTAssertEqual(4.0, l.captureMs!, accuracy: 0)
        XCTAssertEqual(6.0, l.encodeMs!, accuracy: 0)
        XCTAssertEqual(7.0, l.networkMs!, accuracy: 0.01)
        XCTAssertEqual(5.0, l.decodeMs!, accuracy: 0)
        XCTAssertEqual(9.0, l.renderMs!, accuracy: 0)
        XCTAssertEqual(31.0, l.totalMs!, accuracy: 0.01)
        XCTAssertEqual("nvenc", l.encoder)
        XCTAssertNil(m.take(), "a fresh window")
    }

    func testTheQuickestPingSetsTheClock() {
        let m = LatencyMeter()
        // A slow answer whose delay was all on the way back reads the clock 20 ms wrong ...
        ping(m, 0, 1_000, 41_000)
        // ... the quick symmetric one later does not.
        ping(m, 1_000_000, 2_000, 2_000)
        m.onReceived(frame: 1, captureUs: 0, encodedUs: 2_000_000 + skew, recvUs: 2_010_000)
        m.onDecoded(frame: 1, decodedUs: 2_011_000)
        XCTAssertEqual(10.0, m.take()!.networkMs!, accuracy: 0.01)
    }

    func testWithoutAPingOnlyThePhonesOwnShare() {
        let m = LatencyMeter()
        m.onReceived(frame: 1, captureUs: 1, encodedUs: 2, recvUs: 10_000)
        m.onDecoded(frame: 1, decodedUs: 14_000)
        m.onRendered(frame: 1, renderedUs: 20_000)
        let l = m.take()!
        XCTAssertNil(l.networkMs)
        XCTAssertNil(l.totalMs)
        XCTAssertEqual(4.0, l.decodeMs!, accuracy: 0)
        XCTAssertEqual(6.0, l.renderMs!, accuracy: 0)
    }

    func testWithoutRenderCallbacksTheTotalEndsAtTheDecoder() {
        let m = LatencyMeter()
        ping(m, 0, 3_000, 3_000)
        m.onReceived(frame: 1, captureUs: 100_000 + skew, encodedUs: 110_000 + skew, recvUs: 117_000)
        m.onDecoded(frame: 1, decodedUs: 122_000)
        let l = m.take()!
        XCTAssertNil(l.renderMs)
        XCTAssertEqual(22.0, l.totalMs!, accuracy: 0.01)
    }

    func testHostTimingFromAStateFrame() {
        let state = StateMessage(json: JSONValue.object(#"{"timing":{"capture_us":3000,"encoder":"openh264"}}"#)!)
        let m = LatencyMeter()
        m.onHostTiming(state.timing!)
        let l = m.take()!
        XCTAssertEqual(3.0, l.captureMs!, accuracy: 0)
        XCTAssertEqual("openh264", l.encoder)
    }
}
