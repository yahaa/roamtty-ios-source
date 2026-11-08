import Foundation

/// Where a frame's time goes, from the host grabbing the pixels to the phone showing them, averaged
/// over each `take` window. The host reports its own share (STATE `timing`); the phone measures the
/// rest against the host's clock, whose offset comes from the ping that took the least time: on a
/// path as slow one way as the other it is exact, otherwise off by at most half that round trip.
/// Port of Android `desktop-core/LatencyMeter.kt` (roamtty #218). All times in microseconds.
public final class LatencyMeter: @unchecked Sendable {
    /// All in milliseconds; nil where the window had nothing to measure it with. `totalMs` runs to the screen,
    /// or to the decoder's output where no render times come (`renderMs` nil).
    public struct Latency: Equatable, Sendable {
        public let captureMs: Double?, convertMs: Double?, encodeMs: Double?, networkMs: Double?
        public let decodeMs: Double?, renderMs: Double?, totalMs: Double?
        public let encoder: String
        public init(captureMs: Double? = nil, convertMs: Double? = nil, encodeMs: Double? = nil, networkMs: Double? = nil, decodeMs: Double? = nil,
                    renderMs: Double? = nil, totalMs: Double? = nil, encoder: String = "") {
            self.captureMs = captureMs; self.convertMs = convertMs; self.encodeMs = encodeMs; self.networkMs = networkMs
            self.decodeMs = decodeMs; self.renderMs = renderMs; self.totalMs = totalMs; self.encoder = encoder
        }
    }

    private final class Times {
        let captureUs: Int64, encodedUs: Int64, recvUs: Int64
        var decodedUs: Int64 = 0
        init(_ c: Int64, _ e: Int64, _ r: Int64) { captureUs = c; encodedUs = e; recvUs = r }
    }

    private struct Sum {
        var us: Int64 = 0, n = 0
        mutating func add(_ v: Int64) { if v >= 0 { us += v; n += 1 } }
        var ms: Double? { n == 0 ? nil : Double(us / Int64(n)) / 1000.0 }
    }

    private let lock = NSLock()
    private var frames: [Int64: Times] = [:]
    /// host clock − phone clock, µs, with the round trip it was measured over.
    private var offsets: [(offset: Int64, rtt: Int64)] = []
    private var host: [String: Any]?
    private var network = Sum(), decode = Sum(), render = Sum(), total = Sum()
    /// Capture to decoded: the total where the decoder never says when a frame reached the screen.
    private var toDecoded = Sum()

    public init() {}

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// A pong: `t1` and `t4` on the phone's clock, `t2` and `t3` on the host's.
    public func onPong(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
        locked {
            let rtt = (t4 - t1) - (t3 - t2)
            if rtt < 0 { return }
            offsets.append((((t2 - t1) + (t3 - t4)) / 2, rtt))
            while offsets.count > 8 { offsets.removeFirst() }
        }
    }

    private func offset() -> Int64? { offsets.min { $0.rtt < $1.rtt }?.offset }

    public func onReceived(frame: Int64, captureUs: Int64, encodedUs: Int64, recvUs: Int64) {
        locked {
            frames[frame] = Times(captureUs, encodedUs, recvUs)
            if frames.count > 240 { for k in frames.keys where k < frame - 120 { frames[k] = nil } }
        }
    }

    public func onDecoded(frame: Int64, decodedUs: Int64) {
        locked {
            guard let t = frames[frame] else { return }
            t.decodedUs = decodedUs
            decode.add(decodedUs - t.recvUs)
            if let o = offset() {
                network.add(t.recvUs - (t.encodedUs - o))
                toDecoded.add(decodedUs - (t.captureUs - o))
            }
        }
    }

    /// Presentation callback; iOS uses actual display-layer enqueue as an approximation, not scan-out.
    public func onRendered(frame: Int64, renderedUs: Int64) {
        locked {
            guard let t = frames.removeValue(forKey: frame) else { return }
            if t.decodedUs != 0 { render.add(renderedUs - t.decodedUs) }
            if let o = offset() { total.add(renderedUs - (t.captureUs - o)) }
        }
    }

    /// STATE `timing`.
    public func onHostTiming(_ json: [String: Any]) { locked { host = json } }

    /// The averages since the last call, then a fresh window; nil when nothing came in.
    public func take() -> Latency? {
        locked {
            let h = host
            func hostMs(_ key: String) -> Double? { h?[key] != nil ? Double(JSONValue.int64(h?[key]) ?? 0) / 1000.0 : nil }
            let l = Latency(captureMs: hostMs("capture_us"), convertMs: hostMs("convert_us"), encodeMs: hostMs("encode_us"),
                            networkMs: network.ms, decodeMs: decode.ms, renderMs: render.ms, totalMs: total.ms ?? toDecoded.ms,
                            encoder: JSONValue.string(h?["encoder"]))
            host = nil
            clearSums()
            return [l.captureMs, l.networkMs, l.decodeMs, l.totalMs].contains { $0 != nil } ? l : nil
        }
    }

    /// A new stream: the host's clock starts over with its process.
    public func reset() {
        locked {
            frames.removeAll()
            offsets.removeAll()
            host = nil
            clearSums()
        }
    }

    private func clearSums() { network = Sum(); decode = Sum(); render = Sum(); total = Sum(); toDecoded = Sum() }
}
