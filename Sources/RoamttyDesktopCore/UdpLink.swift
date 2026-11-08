import Foundation
import Dispatch

/// Where the link's datagrams go. The real one is `UdpSocketTransport`; tests swap in a lossy in-memory one.
public protocol UdpTransport: AnyObject {
    /// Called with every datagram that arrives, from the transport's own thread.
    var onReceive: (([UInt8]) -> Void)? { get set }
    var localPort: Int { get }
    /// Sends one datagram to the host. Must not block the caller for long; the link calls it from its send queue.
    func send(_ datagram: [UInt8])
    /// A new network: a new socket (new local port).
    func rebind() throws
    func close()
}

/// The phone end of the UDP transport (plan §7.3 P2). Frames go out as FEC'd messages; keys,
/// buttons, text and control are resent until the host acknowledges them, pointer moves are sent
/// once (the next one supersedes them). Received video is reported back for the host's congestion
/// control, and missing shards are NACKed while the round trip is short enough to help.
/// `rebind` moves to a new socket after a network change and tells the host at once.
///
/// Port of Android `desktop-core/UdpLink.kt` (roamtty #218). The socket sits behind `UdpTransport`
/// and time behind `clock` so the logic runs in tests without a network; `start` drives `tick`
/// every 20 ms, as the Android tick thread does. Every datagram leaves from one serial queue, in order,
/// so the main thread (touches become pointer input there) never does network I/O.
public final class UdpLink: @unchecked Sendable {
    public static let ALIVE_US: Int64 = 3_000_000

    private let crypto: UdpCrypto
    private let transport: UdpTransport
    private let clock: () -> Int64
    private let onFrame: (Frame) -> Void
    private let onVideoLost: () -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    private let sender = DispatchQueue(label: "desktop-udp-send")
    private let tickQueue = DispatchQueue(label: "desktop-udp-tick")
    private var timer: DispatchSourceTimer?

    private var seq: UInt64 = 1
    /// Reliable messages are odd (2n + 1, n counting up) so the host can apply them in order; the rest even.
    private var reliableSeq: Int64 = 0
    private var plainSeq: Int64 = 1
    private var replay = ReplayWindow()
    private let reasm = Reassembler()
    private final class Unacked { let frags: [Packet.Frag]; var at: Int64; var tries: Int
        init(_ f: [Packet.Frag], _ at: Int64) { frags = f; self.at = at; tries = 0 } }
    private var unacked: [Int64: Unacked] = [:]
    private struct NackKey: Hashable { let msg: Int64; let block: Int }
    /// NACKs sent per (msg, block) and when: repeated every max(2×RTT, 30 ms), three times at most.
    private var nacked: [NackKey: (count: Int, at: Int64)] = [:]
    private var closed = false
    private var lastRxUs: Int64 = 0
    private var lastServerT: Int64 = 0
    private var lastHeartbeatUs: Int64 = 0
    private var window: [(at: Int64, received: Int, total: Int)] = []

    public private(set) var rttMs: Int?
    /// Share of shards lost on the way over the last second, before FEC.
    public private(set) var loss = 0.0
    public private(set) var fecRecovered: Int64 = 0
    public private(set) var lostMessages: Int64 = 0
    public private(set) var nacks: Int64 = 0
    /// Test hook: drop this share of datagrams in both directions.
    public var dropRate = 0.0

    /// `clock`: a monotonic clock in microseconds.
    public init(key: [UInt8], transport: UdpTransport, clock: @escaping () -> Int64 = UdpLink.monotonicUs,
                onFrame: @escaping (Frame) -> Void, onVideoLost: @escaping () -> Void, log: @escaping (String) -> Void = { _ in }) {
        crypto = UdpCrypto(key: key)
        self.transport = transport
        self.clock = clock
        self.onFrame = onFrame
        self.onVideoLost = onVideoLost
        self.log = log
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    public static func monotonicUs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }

    public var localPort: Int { transport.localPort }
    public var alive: Bool { locked { !closed && lastRxUs != 0 && clock() - lastRxUs < Self.ALIVE_US } }
    public var silentUs: Int64 { locked { lastRxUs == 0 ? Int64.max : clock() - lastRxUs } }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// Starts the 20 ms tick (heartbeats, resends, NACKs, feedback) and sends the first heartbeat.
    public func start() {
        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        heartbeat()
    }

    /// One datagram from the transport.
    public func receive(_ datagram: [UInt8]) {
        if dropRate > 0 && Double.random(in: 0..<1) < dropRate { return }
        guard let (dir, sq, plain) = crypto.open(datagram), dir == UdpWire.DIR_S2C else { return }
        guard locked({ replay.accept(sq) }) else { return }
        let now = clock()
        locked { lastRxUs = now }
        guard let p = Packet.decode(plain) else { return }
        switch p {
        case .heartbeat(let t, let echo):
            locked { lastServerT = t; if echo != 0 { rttMs = Int((now - echo) / 1000) } }
            // The host's RTT probe: answered at once, or the host times its resends by our next heartbeat.
            if echo == 0 { raw(Packet.heartbeat(t: clock(), echo: t).encode()) }
        case .frag(let f):
            let reliable = f.flags & UdpWire.FLAG_RELIABLE != 0
            let (delivered, done) = locked { () -> (Reassembler.Delivered?, Bool) in
                let d = reasm.push(f, nowUs: now)
                return (d, d == nil && reasm.isDone(f.msg))
            }
            if let delivered {
                if reliable { raw(Packet.rack(ids: [f.msg]).encode()) }
                if let frame = DesktopProtocol.read(delivered.bytes) { onFrame(frame) }
            } else if reliable && done {
                raw(Packet.rack(ids: [f.msg]).encode())
            }
        case .rack(let ids):
            locked { ids.forEach { unacked[$0] = nil } }
        default:
            break
        }
    }

    private func raw(_ plain: [UInt8]) {
        if locked({ closed }) { return }
        sender.async { [self] in
            let (isClosed, s) = locked { () -> (Bool, UInt64) in defer { seq += 1 }; return (closed, seq) }
            if isClosed { return }
            let packet = crypto.seal(dir: UdpWire.DIR_C2S, seq: s, plain)
            if dropRate > 0 && Double.random(in: 0..<1) < dropRate { return }
            transport.send(packet)
        }
    }

    private func heartbeat() {
        let (now, server) = locked { () -> (Int64, Int64) in lastHeartbeatUs = clock(); return (lastHeartbeatUs, lastServerT) }
        raw(Packet.heartbeat(t: now, echo: server).encode())
    }

    /// Sends a whole protocol frame; `reliable` ones are resent until the host acknowledges them.
    public func send(_ frame: [UInt8], reliable: Bool) {
        // Ids are u32 on the wire (RACKs come back as u32): wrap the same way here, so they still match.
        let id: Int64 = locked {
            if reliable { defer { reliableSeq += 1 }; return (reliableSeq * 2 + 1) & 0xFFFF_FFFF }
            defer { plainSeq += 1 }; return (plainSeq * 2) & 0xFFFF_FFFF
        }
        let frags = UdpWire.fragment(msg: id, flags: reliable ? UdpWire.FLAG_RELIABLE : 0, bytes: frame,
                                     ratio: reliable && frame.count > UdpWire.SHARD ? 0.25 : 0)
        if reliable { let now = clock(); locked { unacked[id] = Unacked(frags, now) } }
        frags.forEach { raw($0.encode()) }
    }

    /// The periodic work; `start` calls it every 20 ms. Public for tests with a manual clock.
    public func tick() {
        let t = clock()
        if locked({ closed }) { return }
        // Keepalive four times a second: the host counts the link down after 3 s of silence, and the
        // answers let a stall show within 700 ms even when one or two are lost.
        if t - locked({ lastHeartbeatUs }) > 250_000 { heartbeat() }
        let rtt = Int64(locked { rttMs } ?? 50) * 1000
        let resendAfter = max(2 * rtt, 80_000)
        var resend: [[Packet.Frag]] = []
        var nackOut: [Packet] = []
        let (reports, lost): ([Report], [Int64]) = locked {
            for (id, u) in unacked {
                if t - u.at < resendAfter { continue }
                if u.tries >= 10 { unacked[id] = nil; continue }
                u.tries += 1; u.at = t
                resend.append(u.frags)
            }
            // A retransmit only beats the next frame when the round trip is under about two frames.
            let missing = rtt < 40_000 ? reasm.missing(nowUs: t, fallbackUs: max(100_000, 3 * rtt)) : []
            let reports = reasm.takeReports(nowUs: t)
            let lost = reasm.expire(nowUs: t, timeoutUs: max(300_000, 3 * rtt))
            for (m, block, idx) in missing {
                let key = NackKey(msg: m, block: block)
                let (count, at) = nacked[key] ?? (0, 0)
                if count >= 3 || t - at < max(2 * rtt, 30_000) { continue }
                nacked[key] = (count + 1, t)
                nacks += 1
                nackOut.append(.nack(msg: m, block: block, indices: idx))
            }
            if nacked.count > 2000 { nacked.removeAll() }
            if !reports.isEmpty {
                for r in reports {
                    if r.outcome == 2 { fecRecovered += 1 }
                    window.append((t, r.received, r.total))
                }
                window.removeAll { t - $0.at > 1_000_000 }
                let rx = window.reduce(0) { $0 + $1.received }, tot = window.reduce(0) { $0 + $1.total }
                // Too few shards make a noisy estimate: it needs 50 in the last second to count.
                loss = tot < 50 ? 0 : max(0, 1 - Double(rx) / Double(tot))
            }
            lostMessages += Int64(lost.count)
            return (reports, lost)
        }
        resend.forEach { $0.forEach { raw($0.encode()) } }
        nackOut.forEach { raw($0.encode()) }
        stride(from: 0, to: reports.count, by: 40).forEach { raw(Packet.feedback(reports: Array(reports[$0..<min($0 + 40, reports.count)])).encode()) }
        if !lost.isEmpty { onVideoLost() }
    }

    /// A new network: a new socket (new local port), three heartbeats straight away.
    public func rebind() {
        do { try transport.rebind() } catch { log("udp rebind failed: \(error)"); return }
        for _ in 0..<3 { heartbeat() }
        log("udp rebound to port \(transport.localPort)")
    }

    public func close() {
        locked { closed = true }
        timer?.cancel()
        timer = nil
        sender.async { [transport] in transport.close() }
    }

    /// Which client frames must arrive: everything except pointer moves, wheel, ACK and pings.
    public static func reliable(_ frame: [UInt8]) -> Bool {
        guard let type = frame.first else { return true }
        switch Int(type) {
        case DesktopProtocol.ACK, DesktopProtocol.PING, DesktopProtocol.PONG: return false
        case DesktopProtocol.INPUT: return ![1, 2, 4].contains(frame.count > 4 ? Int(frame[4]) : 0)
        default: return true
        }
    }
}
