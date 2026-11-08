import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RoamttyDesktopCore

/// The UDP layer against the plugin's golden samples, and the client link against a host stand-in;
/// mirrors Android's UdpWireTest.
final class UdpWireTests: XCTestCase {
    private let key: [UInt8] = (0..<16).map { UInt8($0) }

    private func goldenFrags() -> [[UInt8]] {
        var r = ByteReader(Golden.bytes("udp-frags.bin"))
        var out: [[UInt8]] = []
        while r.remaining > 0, let n = r.u16() { out.append(Array(r.bytes[r.position..<(r.position + n)])); r = ByteReader(r.bytes, at: r.position + n) }
        return out
    }

    func testSealedHeartbeatMatchesThePlugin() {
        let c = UdpCrypto(key: key)
        let sealed = Golden.bytes("udp-sealed.bin")
        XCTAssertEqual(sealed, c.seal(dir: UdpWire.DIR_S2C, seq: 7, Packet.heartbeat(t: 1, echo: 2).encode()))
        let opened = c.open(sealed)!
        XCTAssertEqual(UdpWire.DIR_S2C, opened.dir)
        XCTAssertEqual(7, opened.seq)
        XCTAssertEqual(.heartbeat(t: 1, echo: 2), Packet.decode(opened.plain))
        var tampered = sealed; tampered[0] = 0
        XCTAssertNil(c.open(tampered))
        XCTAssertNil(UdpCrypto(key: [UInt8](repeating: 0, count: 16)).open(sealed))
        XCTAssertNil(c.open(Array(sealed.prefix(20))))
    }

    func testFragmentsMatchThePluginAndRebuildWithLoss() {
        let message: [UInt8] = (0..<3000).map { UInt8($0 * 13 % 256) }
        let golden = goldenFrags()
        let ours = UdpWire.fragment(msg: 5, flags: UdpWire.FLAG_VIDEO, bytes: message, ratio: 0.5).map { $0.encode() }
        XCTAssertEqual(golden.count, ours.count)
        XCTAssertEqual(golden, ours)
        // The first two data shards lost: parity rebuilds them.
        let r = Reassembler()
        var out: Reassembler.Delivered?
        for (i, p) in golden.dropFirst(2).enumerated() {
            guard case .frag(let f)? = Packet.decode(p) else { return XCTFail("expected a fragment") }
            if let d = r.push(f, nowUs: Int64(i)) { out = d }
        }
        XCTAssertEqual(message, out?.bytes)
        XCTAssertEqual([2], r.takeReports().map(\.outcome))
    }

    func testPacketsRoundTrip() {
        let packets: [Packet] = [.rack(ids: [1, 3, 0xFFFF_FFFF]), .heartbeat(t: -5, echo: 9),
                                 .feedback(reports: [Report(msg: 4, received: 9, total: 12, firstUs: 1, lastUs: 2, outcome: 2)]),
                                 .nack(msg: 8, block: 1, indices: [2, 3])]
        for p in packets { XCTAssertEqual(p, Packet.decode(p.encode())) }
        XCTAssertNil(Packet.decode([UInt8(UdpWire.HEARTBEAT), 1, 2]), "short packets are dropped, not trapped on")
        XCTAssertNil(Packet.decode([99]))
    }

    func testFecSurvivesAnyLossUpToParity() {
        var rnd = SplitMix64(seed: 4)
        for _ in 0..<20 {
            let k = Int.random(in: 1...60, using: &rnd)
            let m = Int.random(in: 1...20, using: &rnd)
            let data: [[UInt8]] = (0..<k).map { _ in (0..<50).map { _ in UInt8.random(in: 0...255, using: &rnd) } }
            var all: [[UInt8]?] = data + Fec.encode(data, m: m)
            for i in Array(all.indices).shuffled(using: &rnd).prefix(m) { all[i] = nil }
            XCTAssertEqual(data, Fec.decode(all, k: k))
            all[all.firstIndex { $0 != nil }!] = nil
            XCTAssertNil(Fec.decode(all, k: k), "one more lost than parity")
        }
    }

    func testReplayWindow() {
        var w = ReplayWindow()
        XCTAssertTrue(w.accept(5)); XCTAssertFalse(w.accept(5)); XCTAssertTrue(w.accept(3))
        XCTAssertTrue(w.accept(2000)); XCTAssertFalse(w.accept(900)); XCTAssertTrue(w.accept(1999))
    }

    func testReliableClassification() {
        XCTAssertFalse(UdpLink.reliable(DesktopProtocol.abs(display: 0, x: 1, y: 2)))
        XCTAssertFalse(UdpLink.reliable(DesktopProtocol.wheel(dx: 0, dy: 120)))
        XCTAssertFalse(UdpLink.reliable(DesktopProtocol.ack(frame: 1, recvUs: 2, decodedUs: 3)))
        XCTAssertTrue(UdpLink.reliable(DesktopProtocol.key(4, down: true)))
        XCTAssertTrue(UdpLink.reliable(DesktopProtocol.button(1, down: true)))
        XCTAssertTrue(UdpLink.reliable(DesktopProtocol.text("x")))
        XCTAssertTrue(UdpLink.reliable(DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME)))
    }

    /// Wi-Fi holds a burst back for tens of ms at a time: a frame quiet for a while is late, not lost.
    /// Its gaps are NACKed once the next frame overtakes it (the host paces video in order), or after
    /// the fallback when nothing follows.
    func testNacksWaitForTheNextFrameNotForAQuietSpell() {
        let r = Reassembler()
        func frag(_ msg: Int64, _ index: Int) -> Packet.Frag {
            UdpWire.fragment(msg: msg, flags: UdpWire.FLAG_VIDEO, bytes: [UInt8](repeating: UInt8(msg), count: UdpWire.SHARD * 4), ratio: 0)[index]
        }
        let ms: Int64 = 1000
        _ = r.push(frag(2, 0), nowUs: 0); _ = r.push(frag(2, 1), nowUs: 1 * ms)
        XCTAssertTrue(r.missing(nowUs: 41 * ms, fallbackUs: 100 * ms).isEmpty, "a 40 ms stall alone is not loss")
        _ = r.push(frag(4, 0), nowUs: 42 * ms)
        XCTAssertTrue(r.missing(nowUs: 43 * ms, fallbackUs: 100 * ms).isEmpty, "overtaken a moment ago: reordering grace")
        let m = r.missing(nowUs: 48 * ms, fallbackUs: 100 * ms)
        XCTAssertEqual(1, m.count)
        XCTAssertEqual(2, m.first?.msg); XCTAssertEqual(0, m.first?.block); XCTAssertEqual([2, 3], m.first?.indices)
        // The newest frame, with nothing after it, waits for the fallback.
        XCTAssertTrue(r.missing(nowUs: 100 * ms, fallbackUs: 100 * ms).allSatisfy { $0.msg != 4 })
        XCTAssertEqual([1, 2, 3], r.missing(nowUs: 143 * ms, fallbackUs: 100 * ms).first { $0.msg == 4 }?.indices)
    }

    func testExpiredVideoIsReportedLost() {
        let r = Reassembler()
        let frags = UdpWire.fragment(msg: 2, flags: UdpWire.FLAG_VIDEO, bytes: [UInt8](repeating: 1, count: UdpWire.SHARD * 2), ratio: 0)
        _ = r.push(frags[0], nowUs: 0)
        XCTAssertEqual([], r.expire(nowUs: 300_000, timeoutUs: 300_000))
        XCTAssertEqual([2], r.expire(nowUs: 300_001, timeoutUs: 300_000))
        XCTAssertEqual([0], r.takeReports().map(\.outcome))
        XCTAssertNil(r.push(frags[1], nowUs: 300_002), "a message given up on stays given up")
    }

    /// A reliable message that went quiet is forgotten, not done: its resend is delivered, not acknowledged unseen.
    func testAnExpiredReliableMessageCanStillArrive() {
        let r = Reassembler()
        let frags = UdpWire.fragment(msg: 9, flags: UdpWire.FLAG_RELIABLE, bytes: [UInt8](repeating: 7, count: UdpWire.SHARD * 3), ratio: 0)
        XCTAssertNil(r.push(frags[0], nowUs: 0))
        XCTAssertEqual([], r.expire(nowUs: 1_000_000, timeoutUs: 300_000))
        XCTAssertFalse(r.isDone(9))
        let out = frags.compactMap { r.push($0, nowUs: 1_000_001) }
        XCTAssertEqual([UdpWire.SHARD * 3], out.map(\.bytes.count))
        XCTAssertTrue(r.isDone(9))
    }

    /// Shards of a block already rebuilt still count as received, so a lossless message reports no loss.
    func testLateShardsOfARebuiltBlockCount() {
        let r = Reassembler()
        let frags = UdpWire.fragment(msg: 3, flags: UdpWire.FLAG_VIDEO, bytes: [UInt8](repeating: 5, count: UdpWire.SHARD * 2 * UdpWire.MAX_K), ratio: 0.25)
        XCTAssertGreaterThan(frags.map(\.blocks).max() ?? 0, 1)
        frags.forEach { _ = r.push($0, nowUs: 0) }
        let report = r.takeReports()
        XCTAssertEqual(1, report.count)
        XCTAssertEqual(frags.count, report.first?.total)
        XCTAssertEqual(frags.count, report.first?.received)
    }

    // MARK: The link

    /// A tiny host stand-in: answers heartbeats, rebuilds messages, acknowledges reliable ones.
    private final class HostStandIn {
        let crypto: UdpCrypto
        let r = Reassembler()
        var seq: UInt64 = 1
        var got: [Frame] = []
        let lock = NSLock()
        init(key: [UInt8]) { crypto = UdpCrypto(key: key) }

        /// The datagrams to answer `datagram` with.
        func handle(_ datagram: [UInt8]) -> [[UInt8]] {
            lock.lock(); defer { lock.unlock() }
            guard let (_, _, plain) = crypto.open(datagram), let p = Packet.decode(plain) else { return [] }
            func reply(_ p: Packet) -> [UInt8] { defer { seq += 1 }; return crypto.seal(dir: UdpWire.DIR_S2C, seq: seq, p.encode()) }
            switch p {
            case .heartbeat(let t, _): return [reply(.heartbeat(t: UdpLink.monotonicUs(), echo: t))]
            case .frag(let f):
                if let d = r.push(f, nowUs: 0) { got.append(DesktopProtocol.read(d.bytes)!); return [reply(.rack(ids: [f.msg]))] }
                return r.isDone(f.msg) ? [reply(.rack(ids: [f.msg]))] : []
            default: return []
            }
        }

        var keys: Set<Int> { lock.lock(); defer { lock.unlock() }; return Set(got.map { Int($0.payload[1]) << 8 | Int($0.payload[2]) }) }
    }

    /// An in-memory transport losing 30% of what the phone sends.
    private final class LossyTransport: UdpTransport {
        var onReceive: (([UInt8]) -> Void)?
        let host: HostStandIn
        var rng = SplitMix64(seed: 7)
        let queue = DispatchQueue(label: "lossy-host")
        init(host: HostStandIn) { self.host = host }
        var localPort: Int { 1 }
        func send(_ datagram: [UInt8]) {
            if Double.random(in: 0..<1, using: &rng) < 0.3 { return }
            queue.async { [self] in host.handle(datagram).forEach { onReceive?($0) } }
        }
        func rebind() throws {}
        func close() {}
    }

    private func waitFor(_ seconds: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    }

    func testLinkResendsReliableFramesThroughLoss() {
        let host = HostStandIn(key: key)
        let link = UdpLink(key: key, transport: LossyTransport(host: host), onFrame: { _ in }, onVideoLost: {})
        link.start()
        for i in 0..<20 { link.send(DesktopProtocol.key(4 + i, down: true), reliable: true) }
        waitFor(10) { host.keys.count == 20 }
        XCTAssertEqual(Set(4..<24), host.keys, "every key arrives once despite loss")
        XCTAssertEqual(20, host.got.count)
        waitFor(3) { link.alive }
        XCTAssertTrue(link.alive)
        XCTAssertNotNil(link.rttMs)
        link.close()
    }

    /// Same as Android's loopback test: the real socket transport against a host stand-in on a UDP port,
    /// dropping 30% of what arrives.
    func testLinkOverLoopbackSocket() throws {
        let host = HostStandIn(key: key)
        let server = socket(AF_INET, Int32(SOCK_DGRAM_VALUE), 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
            #if canImport(Darwin)
            XCTAssertEqual(0, Darwin.bind(server, p, len))
            #else
            XCTAssertEqual(0, Glibc.bind(server, p, len))
            #endif
            XCTAssertEqual(0, getsockname(server, p, &len))
        }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        final class Flag: @unchecked Sendable { let lock = NSLock(); var on = false
            func set() { lock.lock(); on = true; lock.unlock() }
            var value: Bool { lock.lock(); defer { lock.unlock() }; return on } }
        let stop = Flag()
        let t = Thread {
            var rng = SplitMix64(seed: 9)
            var buf = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_storage()
            while true {
                if stop.value { return }
                var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = buf.withUnsafeMutableBytes { b in withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(server, b.baseAddress, b.count, 0, $0, &fl)
                }
                }
                }
                if n <= 0 || Double.random(in: 0..<1, using: &rng) < 0.3 { continue }
                for out in host.handle(Array(buf[0..<n])) {
                    _ = out.withUnsafeBytes { o in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(server, o.baseAddress, o.count, 0, $0, fl)
                    }
                    }
                    }
                }
            }
        }
        t.start()
        let transport = try UdpSocketTransport(host: "127.0.0.1", port: port)
        let link = UdpLink(key: key, transport: transport, onFrame: { _ in }, onVideoLost: {})
        XCTAssertNotEqual(0, link.localPort)
        link.start()
        for i in 0..<20 { link.send(DesktopProtocol.key(4 + i, down: true), reliable: true) }
        waitFor(10) { host.keys.count == 20 }
        XCTAssertEqual(Set(4..<24), host.keys, "every key arrives once despite loss")
        waitFor(3) { link.alive }
        XCTAssertTrue(link.alive)
        // A new network: a new local port, and the host still hears us.
        let before = link.localPort
        link.rebind()
        XCTAssertNotEqual(before, link.localPort)
        link.send(DesktopProtocol.key(100, down: true), reliable: true)
        waitFor(5) { host.keys.contains(100) }
        XCTAssertTrue(host.keys.contains(100))
        link.close()
        stop.set()
        Thread.sleep(forTimeInterval: 0.3)
        _ = close(server)
    }

    /// A video message from the host comes out as a frame and goes back as feedback.
    func testVideoArrivesAndIsReported() {
        let c = UdpCrypto(key: key)
        final class Sink: UdpTransport {
            var onReceive: (([UInt8]) -> Void)?
            var sent: [[UInt8]] = []
            let lock = NSLock()
            var localPort: Int { 1 }
            func send(_ d: [UInt8]) { lock.lock(); sent.append(d); lock.unlock() }
            func rebind() throws {}
            func close() {}
        }
        let sink = Sink()
        var now: Int64 = 1_000_000
        var frames: [Frame] = []
        let link = UdpLink(key: key, transport: sink, clock: { now }, onFrame: { frames.append($0) }, onVideoLost: {})
        let video = DesktopProtocol.frame(DesktopProtocol.VIDEO, [UInt8](repeating: 7, count: 5000))
        var seq: UInt64 = 1
        for f in UdpWire.fragment(msg: 2, flags: UdpWire.FLAG_VIDEO, bytes: video, ratio: 0.25) {
            link.receive(c.seal(dir: UdpWire.DIR_S2C, seq: seq, f.encode())); seq += 1
        }
        XCTAssertEqual(1, frames.count)
        XCTAssertEqual(5000, frames.first?.payload.count)
        // A replayed datagram is ignored.
        link.receive(c.seal(dir: UdpWire.DIR_S2C, seq: 1, Packet.heartbeat(t: 1, echo: 0).encode()))
        now += 60_000
        link.tick()
        let exp = expectation(description: "sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let feedback = sink.sent.compactMap { c.open($0) }.compactMap { Packet.decode($0.plain) }.compactMap { p -> [Report]? in
            if case .feedback(let r) = p { return r }; return nil
        }
        XCTAssertEqual([2], feedback.flatMap { $0 }.map(\.msg))
        XCTAssertEqual(1, feedback.flatMap { $0 }.first?.outcome)
        link.close()
    }
}

#if canImport(Glibc)
private let SOCK_DGRAM_VALUE = SOCK_DGRAM.rawValue
#else
private let SOCK_DGRAM_VALUE = SOCK_DGRAM
#endif
