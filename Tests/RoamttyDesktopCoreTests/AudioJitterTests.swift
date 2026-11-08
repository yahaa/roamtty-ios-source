import XCTest
@testable import RoamttyDesktopCore

/// The sound player's rules (Android `AudioJitterTest`): a buffer as deep as the network's jitter,
/// drops only for bursts, and the playback rate taking up clock drift.
final class AudioJitterTests: XCTestCase {
    struct Run { var drops = 0, dries = 0, packets = 0, cushions = 0; var backlogs: [Double] = []; var targets: [Int] = [] }

    /// Plays `seconds` of packets that leave the host every 20 ms (its clock `hostFast` fast) and arrive
    /// `delay(seq)` ms later; the phone plays at `rate` between arrivals and runs dry at zero.
    private func simulate(seconds: Int, hostFast: Double = 0, delay: (Int64) -> Double) -> Run {
        var j = AudioJitter()
        var run = Run()
        // First in, first out, as a queue on the way delivers them.
        var previous = 0.0
        let arrivals = (1...Int64(seconds * 50)).map { seq -> (Int64, Double) in
            previous = max(previous, Double(seq) * 20 / (1 + hostFast) + delay(seq))
            return (seq, previous)
        }
        var backlog = 0.0, last = arrivals[0].1, dry = false
        for (seq, at) in arrivals {
            backlog -= (at - last) * j.rate
            if backlog < 0 { if run.packets > 0 { dry = true; run.dries += 1 }; backlog = 0 }
            last = at
            switch j.arrive(nowMs: Int64(at), seq: seq, backlogMs: Int(backlog), ranDry: dry) {
            case .drop: run.drops += 1
            case .play(let cushion):
                backlog += Double(cushion + AudioJitter.packetMs); run.packets += 1
                if cushion > 0 { run.cushions += 1 }
            }
            dry = false
            run.backlogs.append(backlog)
            run.targets.append(j.targetMs)
        }
        return run
    }

    /// Deterministic noise in 0..<1.
    private func noise(_ seq: Int64, _ salt: UInt64 = 0) -> Double {
        var x = UInt64(bitPattern: seq) &* 0x9E3779B97F4A7C15 ^ salt
        x ^= x >> 31; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 29
        return Double(x % 10_000) / 10_000
    }

    func testAWiredLinkKeepsTheBufferShallow() {
        let run = simulate(seconds: 30) { self.noise($0) * 4 + 2 }
        XCTAssertEqual(run.drops, 0)
        XCTAssertEqual(run.targets.last, AudioJitter.minTargetMs)
        XCTAssertLessThan(run.backlogs.suffix(500).max()!, 120)
        XCTAssertLessThanOrEqual(run.dries, 1)
    }

    /// Like the Mac's Wi-Fi to the test VM: 8–160 ms, packets held back and released together, and the
    /// VM's clock 1.6% fast.
    func testWifiJitterDeepensTheBufferInsteadOfDroppingAndRunningDry() {
        let run = simulate(seconds: 60, hostFast: 0.016) { seq in
            let stall = self.noise(seq / 8, 7) < 0.25 ? self.noise(seq / 8, 9) * 120 : 0 // a stall holds 8 packets back
            return 8 + self.noise(seq) * 30 + stall
        }
        let steady = run.packets / 2
        XCTAssertLessThan(Double(run.drops) / Double(run.packets), 0.01, "\(run.drops) drops")
        XCTAssertLessThan(Double(run.dries) / Double(run.packets), 0.01, "\(run.dries) dries")
        XCTAssertGreaterThan(run.targets.last!, 120)
        XCTAssertLessThanOrEqual(run.backlogs.suffix(steady).max()!, Double(AudioJitter.maxTargetMs + AudioJitter.dropAboveMs))
        // Near the target on average: no cushion piled under each stall's burst.
        let late = run.backlogs.suffix(steady), target = run.targets.suffix(steady)
        XCTAssertLessThan(late.reduce(0, +) / Double(late.count), Double(target.reduce(0, +)) / Double(target.count) + 40)
        XCTAssertLessThanOrEqual(run.cushions, 2)
    }

    /// A host clock 1.3% fast: the rate takes it up, no drops.
    func testDriftIsTakenUpByTheRate() {
        let run = simulate(seconds: 60, hostFast: 0.013) { self.noise($0) * 4 + 2 }
        XCTAssertEqual(run.drops, 0)
        XCTAssertLessThan(run.backlogs.suffix(1000).max()!, 160)
        // The drift is not mistaken for jitter, and the backlog (recorded with each new packet in)
        // settles on the target, not the proportional part's 26 ms above it.
        XCTAssertEqual(run.targets.last, AudioJitter.minTargetMs)
        let late = run.backlogs.suffix(500)
        XCTAssertEqual(late.reduce(0, +) / Double(late.count), Double(AudioJitter.minTargetMs + AudioJitter.packetMs), accuracy: 8)
    }

    func testABurstPastTheLimitIsDroppedDownToTheTarget() {
        var j = AudioJitter()
        XCTAssertEqual(j.arrive(nowMs: 20, seq: 1, backlogMs: 0, ranDry: false), .play(cushionMs: AudioJitter.minTargetMs - 20))
        var seq: Int64 = 1
        func next(_ backlog: Int) -> AudioJitter.Decision { seq += 1; return j.arrive(nowMs: seq * 20, seq: seq, backlogMs: backlog, ranDry: false) }
        XCTAssertEqual(next(150), .play(cushionMs: 0))
        XCTAssertEqual(next(200), .drop, "past target + 120")
        XCTAssertEqual(next(100), .drop, "until the backlog is back at the target")
        XCTAssertEqual(next(60), .play(cushionMs: 0))
        XCTAssertEqual(next(150), .play(cushionMs: 0), "under the limit again")
    }

    func testSilenceRefillsTheCushionAStallDoesNot() {
        var j = AudioJitter()
        _ = j.arrive(nowMs: 20, seq: 1, backlogMs: 0, ranDry: false)
        // A stall: packet 2 late, the player ran dry; what comes next refills it.
        XCTAssertEqual(j.arrive(nowMs: 200, seq: 2, backlogMs: 0, ranDry: true), .play(cushionMs: 0))
        XCTAssertEqual(j.arrive(nowMs: 201, seq: 3, backlogMs: 20, ranDry: false), .play(cushionMs: 0))
        XCTAssertEqual(j.arrive(nowMs: 202, seq: 2, backlogMs: 40, ranDry: false), .drop, "older than the last")
        j = AudioJitter()
        _ = j.arrive(nowMs: 20, seq: 1, backlogMs: 0, ranDry: false)
        _ = j.arrive(nowMs: 40, seq: 2, backlogMs: 40, ranDry: false)
        // The host was silent for a second: it skipped packets 3–51, numbers carry on.
        XCTAssertEqual(j.arrive(nowMs: 1040, seq: 52, backlogMs: 0, ranDry: false), .play(cushionMs: 40))
        XCTAssertEqual(j.targetMs, AudioJitter.minTargetMs, "a silence is not jitter")
        // A restarted serve numbers from 1 again.
        XCTAssertEqual(j.arrive(nowMs: 90_000, seq: 1, backlogMs: 0, ranDry: false), .play(cushionMs: 40))
        XCTAssertEqual(j.targetMs, AudioJitter.minTargetMs)
    }

    func testTheRateIsCappedAtThreePercent() {
        var j = AudioJitter()
        var seq: Int64 = 0
        for _ in 0..<500 { seq += 1; _ = j.arrive(nowMs: seq * 20, seq: seq, backlogMs: 170, ranDry: false) }
        XCTAssertEqual(j.rate, 1.03, accuracy: 0.001)
        for _ in 0..<500 { seq += 1; _ = j.arrive(nowMs: seq * 20, seq: seq, backlogMs: 0, ranDry: false) }
        XCTAssertEqual(j.rate, 0.97, accuracy: 0.001)
    }
}
