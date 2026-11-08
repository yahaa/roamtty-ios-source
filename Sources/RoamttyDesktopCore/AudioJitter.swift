import Foundation

/// Where AUDIO frames go: the AVAudioEngine player on iOS, a recorder in tests.
public protocol DesktopAudioSink: AnyObject {
    func submit(_ audio: Audio)
    /// Stops playing and lets go of the audio session; the next packet starts it again.
    func stop()
    /// Sound waiting to be heard, in ms.
    var queuedMs: Int { get }
    var packets: Int64 { get }
}

/// The player's rules without the audio stack (Android `AudioJitter`). The host numbers its packets
/// every 20 ms, silent ones included, so `arrival − seq × 20 ms` is each packet's transit time plus an
/// offset; how far a packet came behind the earliest of the last 3 s is the network's jitter. The
/// buffer holds the 95th percentile of it plus `marginMs` (60–300 ms): a phone on Wi-Fi swings by
/// 100 ms and more, a wired link by a few. Each packet is played at once. Only a start (the first
/// packet, or sound again after the host fell silent: numbers skipped, and the player ran dry or nothing
/// came for `gapMs`) gets a cushion of silence up to that target; after a network stall the packets it
/// held back arrive together and refill the buffer by themselves, and a cushion under them kept the
/// sound 80 ms too late for seconds. Past target + `dropAboveMs` waiting, packets are dropped down to the
/// target; one older than the last is dropped too; and the playback rate follows the backlog, at most 3%
/// either way, so two clocks that never quite agree (a virtual machine's sink ran 1.3% fast) need no drops.
public struct AudioJitter: Sendable {
    public static let packetMs = 20
    public static let minTargetMs = 60
    public static let maxTargetMs = 300
    public static let marginMs = 40
    public static let dropAboveMs = 120
    /// Nothing for this long after skipped numbers: the host was silent (it sends nothing then).
    public static let gapMs: Int64 = 100
    static let window = 150 // 3 s of packets

    public enum Decision: Equatable, Sendable {
        /// `cushionMs` of silence first (0 for none).
        case play(cushionMs: Int)
        case drop
    }

    private var lastArrivalMs: Int64?
    private var lastSeq: Int64?
    /// (arrival, arrival − seq × 20 ms) of the last 3 s.
    private var offsets: [(at: Int64, offset: Int64)] = []
    private var dropping = false
    private var smoothed = Double(minTargetMs)
    /// The rate's slow part: what the clocks' difference needs, learnt over seconds, so the backlog
    /// settles on the target instead of the proportional part's distance above it.
    private var drift = 0.0
    /// 1 plays at the host's rate; above it faster.
    public private(set) var rate = 1.0
    /// The backlog the buffer aims for, from the jitter of the last 3 s.
    public private(set) var targetMs = minTargetMs

    public init() {}

    /// How far the 95th percentile of packets came behind the earliest, the clocks' drift taken out:
    /// a host 1.3% fast moves the offsets by 39 ms in 3 s, which is no jitter.
    static func p95Jitter(_ points: [(at: Int64, offset: Int64)]) -> Double {
        let n = Double(points.count)
        let meanT = points.reduce(0.0) { $0 + Double($1.at) } / n
        let meanO = points.reduce(0.0) { $0 + Double($1.offset) } / n
        var num = 0.0, den = 0.0
        for p in points {
            num += (Double(p.at) - meanT) * (Double(p.offset) - meanO)
            den += (Double(p.at) - meanT) * (Double(p.at) - meanT)
        }
        let slope = den > 0 ? num / den : 0
        let residuals = points.map { Double($0.offset) - slope * (Double($0.at) - meanT) }
        let base = residuals.min() ?? 0
        let late = residuals.map { $0 - base }.sorted()
        return late[min(late.count - 1, late.count * 95 / 100)]
    }

    /// A packet numbered `seq` arrived at `nowMs`; `backlogMs` is what is scheduled and not yet heard,
    /// `ranDry` whether the player emptied since the last packet.
    public mutating func arrive(nowMs: Int64, seq: Int64, backlogMs: Int, ranDry: Bool) -> Decision {
        let offset = nowMs - seq * Int64(Self.packetMs)
        // A new `serve` numbers from 1 again: the old offsets say nothing about this one.
        if let last = offsets.last, Swift.abs(offset - last.offset) > 1000 { offsets.removeAll(); lastSeq = nil }
        offsets.append((nowMs, offset))
        if offsets.count > Self.window { offsets.removeFirst(offsets.count - Self.window) }
        targetMs = min(max(Int(Self.p95Jitter(offsets)) + Self.marginMs, Self.minTargetMs), Self.maxTargetMs)

        if let last = lastSeq, seq <= last { return .drop }
        defer { lastArrivalMs = nowMs; lastSeq = seq }
        let quiet = lastArrivalMs.map { nowMs - $0 > Self.gapMs } ?? true
        let resumed = lastSeq.map { seq - $0 > 1 && (ranDry || quiet) } ?? true
        if resumed {
            dropping = false
            smoothed = Double(targetMs)
            return .play(cushionMs: max(0, targetMs - Self.packetMs - backlogMs))
        }
        if ranDry { dropping = false }
        if backlogMs > targetMs + Self.dropAboveMs { dropping = true }
        if dropping {
            if backlogMs > targetMs { return .drop }
            dropping = false
        }
        smoothed += (Double(backlogMs) - smoothed) * 0.05
        let error = smoothed - Double(targetMs)
        drift = min(max(drift + error * 0.000002, -0.03), 0.03)
        let want = 1 + min(max(drift + error * 0.0005, -0.03), 0.03)
        if Swift.abs(want - rate) >= 0.001 { rate = want }
        return .play(cushionMs: 0)
    }
}
