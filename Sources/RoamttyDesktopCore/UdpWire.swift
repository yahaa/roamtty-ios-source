import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The UDP datagram format, as the plugin's `udp.rs`: `u8 dir | u64 seq` in the clear, then
/// AES-128-GCM (nonce = dir, 0, 0, 0, seq) of one packet with the header as associated data.
/// Port of Android `desktop-core/UdpWire.kt` (roamtty #218).
public enum UdpWire {
    public static let DIR_C2S = 0
    public static let DIR_S2C = 1
    public static let HEADER = 9
    public static let SHARD = 1150
    public static let MAX_K = 160
    public static let FRAG = 1
    public static let RACK = 2
    public static let HEARTBEAT = 3
    public static let FEEDBACK = 4
    public static let NACK = 5
    public static let FLAG_RELIABLE = 1
    public static let FLAG_VIDEO = 2

    public static func parityFor(k: Int, ratio: Float) -> Int {
        if ratio <= 0 { return 0 }
        let p = Int((Double(k) * Double(ratio)).rounded(.up))
        return Swift.min(Swift.max(p, 1), Fec.maxShards - k)
    }

    /// One message cut into FEC blocks of equal shards.
    public static func fragment(msg: Int64, flags: Int, bytes: [UInt8], ratio: Float) -> [Packet.Frag] {
        let perBlock = SHARD * MAX_K
        let blocks = Swift.max(1, (bytes.count + perBlock - 1) / perBlock)
        precondition(blocks <= 255)
        var out: [Packet.Frag] = []
        for b in 0..<blocks {
            let from = b * perBlock
            let to = Swift.min(bytes.count, from + perBlock)
            let len = to - from
            let k = Swift.max(1, (len + SHARD - 1) / SHARD)
            let size = Swift.max(1, (len + k - 1) / k)
            let data: [[UInt8]] = (0..<k).map { i in
                var s = [UInt8](repeating: 0, count: size)
                let start = from + Swift.min(len, i * size)
                let end = from + Swift.min(len, (i + 1) * size)
                if end > start { s.replaceSubrange(0..<(end - start), with: bytes[start..<end]) }
                return s
            }
            let m = parityFor(k: k, ratio: ratio)
            let parity = m > 0 ? Fec.encode(data, m: m) : []
            for (i, shard) in (data + parity).enumerated() {
                out.append(Packet.Frag(msg: msg, flags: flags, block: b, blocks: blocks, index: i, k: k, m: m, len: len, shard: shard))
            }
        }
        return out
    }
}

/// A key's AES-128-GCM sealing. Stateless apart from the key, so safe from any thread.
public struct UdpCrypto: Sendable {
    private let key: SymmetricKey

    public init(key: [UInt8]) { self.key = SymmetricKey(data: key) }

    private static func nonce(_ dir: Int, _ seq: UInt64) -> [UInt8] {
        var w = ByteWriter(capacity: 12); w.u8(dir); w.u8(0); w.u8(0); w.u8(0); w.u64(seq)
        return w.bytes
    }

    public func seal(dir: Int, seq: UInt64, _ plain: [UInt8]) -> [UInt8] {
        var h = ByteWriter(capacity: UdpWire.HEADER); h.u8(dir); h.u64(seq)
        // A 12-byte nonce and a valid key cannot fail here.
        // swiftlint:disable:next force_try
        let box = try! AES.GCM.seal(plain, using: key, nonce: try! AES.GCM.Nonce(data: Self.nonce(dir, seq)), authenticating: h.bytes)
        return h.bytes + Array(box.ciphertext) + Array(box.tag)
    }

    /// (dir, seq, plaintext), or nil for anything not sealed with this key.
    public func open(_ packet: [UInt8]) -> (dir: Int, seq: UInt64, plain: [UInt8])? {
        guard packet.count >= UdpWire.HEADER + 16 else { return nil }
        var r = ByteReader(packet)
        guard let dir = r.u8(), let seq = r.u64() else { return nil }
        let head = Array(packet[0..<UdpWire.HEADER])
        let body = packet[UdpWire.HEADER..<(packet.count - 16)]
        let tag = packet[(packet.count - 16)...]
        guard let nonce = try? AES.GCM.Nonce(data: Self.nonce(dir, seq)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
              let plain = try? AES.GCM.open(box, using: key, authenticating: head) else { return nil }
        return (dir, seq, Array(plain))
    }
}

/// Drops a datagram whose sequence number was seen in the last 1024.
public struct ReplayWindow: Sendable {
    private var top: UInt64 = 0
    private var bits = [UInt64](repeating: 0, count: 16)

    public init() {}

    public mutating func accept(_ seq: UInt64) -> Bool {
        let w: UInt64 = 1024
        if seq + w <= top { return false }
        if seq > top {
            if seq - top >= w {
                for i in bits.indices { bits[i] = 0 }
            } else {
                var s = top + 1
                while s <= seq { bits[Int((s % w) / 64)] &= ~(UInt64(1) << (s % 64)); s += 1 }
            }
            top = seq
        }
        let i = Int((seq % w) / 64)
        let bit = UInt64(1) << (seq % 64)
        if bits[i] & bit != 0 { return false }
        bits[i] |= bit
        return true
    }
}

/// What became of one video message, for the host's congestion control. `outcome`: 0 lost, 1 whole, 2 rebuilt by FEC.
public struct Report: Equatable, Sendable {
    public var msg: Int64
    public var received: Int
    public var total: Int
    public var firstUs: Int64
    public var lastUs: Int64
    public var outcome: Int
}

public enum Packet: Equatable, Sendable {
    case frag(Frag)
    case rack(ids: [Int64])
    case heartbeat(t: Int64, echo: Int64)
    case feedback(reports: [Report])
    case nack(msg: Int64, block: Int, indices: [Int])

    public struct Frag: Equatable, Sendable {
        public let msg: Int64
        public let flags: Int, block: Int, blocks: Int, index: Int, k: Int, m: Int, len: Int
        public let shard: [UInt8]

        public func encode() -> [UInt8] { Packet.frag(self).encode() }
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .frag(let f):
            w.u8(UdpWire.FRAG); w.u32(f.msg); w.u8(f.flags); w.u8(f.block); w.u8(f.blocks)
            w.u16(f.index); w.u16(f.k); w.u16(f.m); w.u32(Int64(f.len)); w.append(f.shard)
        case .rack(let ids):
            w.u8(UdpWire.RACK); w.u16(ids.count); ids.forEach { w.u32($0) }
        case .heartbeat(let t, let echo):
            w.u8(UdpWire.HEARTBEAT); w.i64(t); w.i64(echo)
        case .feedback(let reports):
            w.u8(UdpWire.FEEDBACK); w.u16(reports.count)
            for r in reports { w.u32(r.msg); w.u16(r.received); w.u16(r.total); w.i64(r.firstUs); w.i64(r.lastUs); w.u8(r.outcome) }
        case .nack(let msg, let block, let indices):
            w.u8(UdpWire.NACK); w.u32(msg); w.u8(block); w.u16(indices.count); indices.forEach { w.u16($0) }
        }
        return w.bytes
    }

    public static func decode(_ p: [UInt8]) -> Packet? {
        var b = ByteReader(p)
        guard let type = b.u8() else { return nil }
        switch type {
        case UdpWire.FRAG:
            guard let msg = b.u32(), let flags = b.u8(), let block = b.u8(), let blocks = b.u8(), let index = b.u16(),
                  let k = b.u16(), let m = b.u16(), let len = b.i32() else { return nil }
            return .frag(Frag(msg: msg, flags: flags, block: block, blocks: blocks, index: index, k: k, m: m, len: len, shard: b.rest()))
        case UdpWire.RACK:
            guard let n = b.u16() else { return nil }
            var ids: [Int64] = []
            for _ in 0..<n { guard let id = b.u32() else { return nil }; ids.append(id) }
            return .rack(ids: ids)
        case UdpWire.HEARTBEAT:
            guard let t = b.i64(), let echo = b.i64() else { return nil }
            return .heartbeat(t: t, echo: echo)
        case UdpWire.FEEDBACK:
            guard let n = b.u16() else { return nil }
            var out: [Report] = []
            for _ in 0..<n {
                guard let msg = b.u32(), let rx = b.u16(), let tot = b.u16(), let f = b.i64(), let l = b.i64(), let o = b.u8() else { return nil }
                out.append(Report(msg: msg, received: rx, total: tot, firstUs: f, lastUs: l, outcome: o))
            }
            return .feedback(reports: out)
        case UdpWire.NACK:
            guard let msg = b.u32(), let block = b.u8(), let n = b.u16() else { return nil }
            var idx: [Int] = []
            for _ in 0..<n { guard let i = b.u16() else { return nil }; idx.append(i) }
            return .nack(msg: msg, block: block, indices: idx)
        default:
            return nil
        }
    }
}

/// Puts messages back together; each comes out once, and video messages leave a `Report`.
/// Not thread safe: the link calls it under its lock.
public final class Reassembler {
    private final class Block {
        let k: Int, len: Int
        var shards: [[UInt8]?]
        var data: [UInt8]?
        var parity = false
        init(k: Int, len: Int, n: Int) { self.k = k; self.len = len; shards = Array(repeating: nil, count: n) }
    }
    private final class Pending {
        let flags: Int
        var blocks: [Block?]
        let firstUs: Int64
        var lastUs: Int64
        var received = 0, total = 0
        /// When a shard of a later video message first arrived: everything of this one has been sent by then.
        var overtakenUs: Int64 = 0
        init(flags: Int, blocks: Int, firstUs: Int64) {
            self.flags = flags; self.blocks = Array(repeating: nil, count: blocks); self.firstUs = firstUs; lastUs = firstUs
        }
    }

    public struct Delivered: Equatable, Sendable {
        public let msg: Int64
        public let flags: Int
        public let bytes: [UInt8]
    }

    public static let SETTLE_US: Int64 = 50_000
    /// A later message's shards can pass an earlier one's last few on the way: 5 ms of grace.
    public static let REORDER_US: Int64 = 5_000
    private static let DONE_KEEP = 4096

    private var pending: [Int64: Pending] = [:]
    private var done = Set<Int64>()
    /// Finished video messages, kept a moment so parity arriving after the rebuild still counts (insertion order).
    private var settlingOrder: [Int64] = []
    private var settling: [Int64: (report: Report, at: Int64)] = [:]

    public init() {}

    public func isDone(_ msg: Int64) -> Bool { done.contains(msg) }

    public func push(_ f: Packet.Frag, nowUs: Int64) -> Delivered? {
        if done.contains(f.msg) {
            if var s = settling[f.msg] { s.report.received += 1; settling[f.msg] = s }
            return nil
        }
        let n = f.k + f.m
        if f.k == 0 || n > Fec.maxShards || f.index >= n || f.block >= f.blocks { return nil }
        let p: Pending
        if let existing = pending[f.msg] { p = existing } else { p = Pending(flags: f.flags, blocks: f.blocks, firstUs: nowUs); pending[f.msg] = p }
        if f.flags & UdpWire.FLAG_VIDEO != 0 {
            for (m, o) in pending where m < f.msg && o.overtakenUs == 0 && o.flags & UdpWire.FLAG_VIDEO != 0 { o.overtakenUs = nowUs }
        }
        if p.blocks.count != f.blocks { return nil }
        p.lastUs = nowUs
        let b: Block
        if let existing = p.blocks[f.block] { b = existing } else { b = Block(k: f.k, len: f.len, n: n); p.blocks[f.block] = b; p.total += n }
        if b.shards.count != n { return nil }
        // A shard of a block already rebuilt still arrived: count it, or the host's rate control sees loss.
        if b.data != nil { p.received += 1; return nil }
        if b.shards[f.index] != nil { return nil }
        b.shards[f.index] = f.shard
        p.received += 1
        if b.shards.lazy.filter({ $0 != nil }).count >= b.k {
            b.parity = (0..<b.k).contains { b.shards[$0] == nil }
            guard let data = Fec.decode(b.shards, k: b.k) else { return nil }
            var joined = [UInt8](); joined.reserveCapacity(b.len)
            for d in data {
                let c = Swift.min(d.count, b.len - joined.count)
                if c <= 0 { break }
                joined.append(contentsOf: d[0..<c])
            }
            if joined.count < b.len { joined.append(contentsOf: repeatElement(0, count: b.len - joined.count)) }
            b.data = joined
            b.shards = Array(repeating: nil, count: n)
        }
        if p.blocks.allSatisfy({ $0?.data != nil }) {
            pending[f.msg] = nil
            var out: [UInt8] = []
            p.blocks.forEach { out.append(contentsOf: $0!.data!) }
            finish(f.msg, p, outcome: p.blocks.contains { $0!.parity } ? 2 : 1, nowUs: nowUs)
            return Delivered(msg: f.msg, flags: p.flags, bytes: out)
        }
        return nil
    }

    private func finish(_ msg: Int64, _ p: Pending, outcome: Int, nowUs: Int64) {
        done.insert(msg)
        if done.count > Self.DONE_KEEP + 256 {
            // TreeSet.pollFirst in batches: forget the oldest ids down to DONE_KEEP.
            for id in done.sorted().prefix(done.count - Self.DONE_KEEP) { done.remove(id) }
        }
        if p.flags & UdpWire.FLAG_VIDEO != 0 {
            if settling[msg] == nil { settlingOrder.append(msg) }
            settling[msg] = (Report(msg: msg, received: p.received, total: p.total, firstUs: p.firstUs, lastUs: p.lastUs, outcome: outcome), nowUs)
        }
    }

    /// Missing shards (msg, block, indices): what a NACK asks for. The host paces video out in order, so
    /// a video message's gaps are lost once a later one has been arriving for `REORDER_US`. A quiet spell
    /// alone is not loss: Wi-Fi holds bursts back for tens of ms, and NACKing after 10 ms of quiet
    /// resent 5-30% of a phone's shards at 0% loss. Messages nothing has overtaken wait `fallbackUs`.
    public func missing(nowUs: Int64, fallbackUs: Int64) -> [(msg: Int64, block: Int, indices: [Int])] {
        var out: [(msg: Int64, block: Int, indices: [Int])] = []
        for msg in pending.keys.sorted() {
            let p = pending[msg]!
            let overtaken = p.overtakenUs != 0 && nowUs - p.overtakenUs >= Self.REORDER_US
            if !overtaken && nowUs - p.lastUs < fallbackUs { continue }
            for (bi, b) in p.blocks.enumerated() {
                guard let b, b.data == nil else { continue }
                let need = b.k - b.shards.lazy.filter { $0 != nil }.count
                let idx = Array(b.shards.indices.filter { b.shards[$0] == nil }.prefix(need))
                if !idx.isEmpty { out.append((msg, bi, idx)) }
            }
        }
        return out
    }

    /// Gives up on messages quiet for `timeoutUs`; returns the video ones lost. A reliable message is only
    /// forgotten, not marked done: the sender keeps resending it until it is acknowledged, so a resend must
    /// start it over rather than be acknowledged unseen.
    public func expire(nowUs: Int64, timeoutUs: Int64) -> [Int64] {
        let stale = pending.filter { nowUs - $0.value.lastUs > timeoutUs }.keys.sorted()
        return stale.compactMap { m in
            let p = pending.removeValue(forKey: m)!
            if p.flags & UdpWire.FLAG_RELIABLE == 0 { finish(m, p, outcome: 0, nowUs: nowUs) }
            return p.flags & UdpWire.FLAG_VIDEO != 0 ? m : nil
        }
    }

    /// Reports of video messages finished at least `settleUs` ago (all of them when `nowUs` is nil).
    public func takeReports(nowUs: Int64? = nil, settleUs: Int64 = Reassembler.SETTLE_US) -> [Report] {
        var out: [Report] = []
        var taken = 0
        for msg in settlingOrder {
            guard let s = settling[msg] else { taken += 1; continue }
            if let now = nowUs, now - s.at < settleUs { break }
            out.append(s.report)
            settling[msg] = nil
            taken += 1
        }
        settlingOrder.removeFirst(taken)
        return out
    }
}
