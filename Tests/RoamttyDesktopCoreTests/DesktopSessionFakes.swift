import Foundation
@testable import RoamttyDesktopCore

/// The plugin's end of a `serve` channel, driven by the test.
final class FakeStream: DesktopStream, @unchecked Sendable {
    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var eof = false, closed = false
    private var status: Int?
    private var errors = ""
    private var parser = FrameParser(expectHello: false)
    private(set) var frames: [Frame] = []
    let command: String

    init(command: String) { self.command = command }

    // Plugin side.
    func feed(_ bytes: [UInt8]) { cond.lock(); buffer += bytes; cond.broadcast(); cond.unlock() }
    func hello(_ json: [String: Any]) {
        // swiftlint:disable:next force_try - fixture JSON built from literals
        let data = try! JSONSerialization.data(withJSONObject: json)
        feed(Array(data) + [0x0A])
    }
    func exit(_ code: Int?, stderr: String = "") {
        cond.lock(); eof = true; status = code; errors = stderr; cond.broadcast(); cond.unlock()
    }
    var received: [Frame] { cond.lock(); defer { cond.unlock() }; return frames }
    var wasClosed: Bool { cond.lock(); defer { cond.unlock() }; return closed }

    // Phone side.
    func read(maxBytes: Int) -> [UInt8] {
        cond.lock(); defer { cond.unlock() }
        while buffer.isEmpty && !eof && !closed { cond.wait() }
        if buffer.isEmpty { return [] }
        let n = min(maxBytes, buffer.count)
        let out = Array(buffer[0..<n]); buffer.removeFirst(n)
        return out
    }
    func write(_ bytes: [UInt8]) throws {
        cond.lock(); defer { cond.unlock() }
        if closed || eof { throw CocoaError(.fileWriteUnknown) }
        parser.push(bytes)
        while case .frame(let f)? = parser.next() { frames.append(f) }
    }
    var errorOutput: String { cond.lock(); defer { cond.unlock() }; return errors }
    var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return eof && status != nil }
    var exitStatus: Int? { cond.lock(); defer { cond.unlock() }; return status }
    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
}

/// A host whose shell and `serve` the test scripts.
final class FakeHost: DesktopHost, @unchecked Sendable {
    private let lock = NSLock()
    /// What the probe prints; the last answer repeats.
    var probes: [String]
    var scripts: [String] = []
    var commands: [String] = []
    var uploads: [String] = []
    var streams: [FakeStream] = []
    var disconnects = 0
    /// Each `openStream` hands the new stream to this, which plays the plugin.
    var plugin: (FakeStream, Int) -> Void
    var scriptStatus: (String) -> Int? = { _ in 0 }

    init(probe: String, plugin: @escaping (FakeStream, Int) -> Void) { probes = [probe]; self.plugin = plugin }

    static func probe(_ desktop: String = "yes", uname: String = "Linux x86_64", version: String? = "0.9.7") -> String {
        "__ITERMUX_DESKTOP__=\(desktop)\n__ITERMUX_UNAME__=\(uname)\n__ITERMUX_DESKTOP_PLUGIN__=\(version.map { "roamtty-desktop \($0) proto 1" } ?? "")\n"
    }

    func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        lock.lock()
        scripts.append(script)
        let probe = script == DesktopProbeScript.script ? (probes.count > 1 ? probes.removeFirst() : probes[0]) : nil
        lock.unlock()
        if let probe {
            probe.split(separator: "\n").forEach { onLine(String($0)) }
            return 0
        }
        return scriptStatus(script)
    }
    func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        lock.lock(); commands.append(command); lock.unlock()
        return 0
    }
    func upload(_ data: Data, to path: String) throws { lock.lock(); uploads.append(path); lock.unlock() }
    func openStream(_ command: String) -> DesktopStream? {
        let s = FakeStream(command: command)
        lock.lock(); streams.append(s); let n = streams.count; lock.unlock()
        DispatchQueue.global().async { self.plugin(s, n) }
        return s
    }
    func disconnect() { lock.lock(); disconnects += 1; lock.unlock() }

    var allStreams: [FakeStream] { lock.lock(); defer { lock.unlock() }; return streams }
    var allScripts: [String] { lock.lock(); defer { lock.unlock() }; return scripts }
    var allCommands: [String] { lock.lock(); defer { lock.unlock() }; return commands }
}

/// Stands in for VideoToolbox: every frame submitted is "decoded" right away.
final class InstantDecoder: DesktopVideoSink, @unchecked Sendable {
    weak var session: DesktopSession?
    private let lock = NSLock()
    private(set) var frames: [Int64] = []
    var decoderName: String { "test" }
    var decodedFrames: Int64 { lock.lock(); defer { lock.unlock() }; return Int64(frames.count) }
    func submit(_ video: Video) {
        lock.lock(); frames.append(video.frame); lock.unlock()
        session?.decoded(frame: video.frame, decodedUs: UdpLink.monotonicUs())
    }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return frames }
}

/// Stands in for the AVAudioEngine player: records what it was handed and how often it was stopped.
final class RecordingAudio: DesktopAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var seqs: [Int64] = []
    private var stops = 0
    func submit(_ audio: Audio) { lock.lock(); seqs.append(audio.seq); lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    var queuedMs: Int { 40 }
    var packets: Int64 { lock.lock(); defer { lock.unlock() }; return Int64(seqs.count) }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return seqs }
    var stopped: Int { lock.lock(); defer { lock.unlock() }; return stops }
}

enum PluginFrames {
    static func video(_ n: Int64, key: Bool = true, w: Int = 1280, h: Int = 720) -> [UInt8] {
        var b = ByteWriter()
        b.u32(n); b.u8(key ? DesktopProtocol.VIDEO_KEY : 0); b.i64(1); b.i64(2); b.u16(w); b.u16(h)
        b.append([0, 0, 0, 1, 0x65, 0x88])
        return DesktopProtocol.frame(DesktopProtocol.VIDEO, b.bytes)
    }
    static func state(_ json: [String: Any]) -> [UInt8] {
        // swiftlint:disable:next force_try - fixture JSON built from literals
        DesktopProtocol.frame(DesktopProtocol.STATE, Array(try! JSONSerialization.data(withJSONObject: json)))
    }
    static func audio(_ seq: Int64) -> [UInt8] {
        var b = ByteWriter()
        b.u32(seq); b.i64(3)
        b.append([0xFC, 0xFF, 0xFE])
        return DesktopProtocol.frame(DesktopProtocol.AUDIO, b.bytes)
    }
    static func hello(session: String = "s1", token: String = "tok+/=", needs: [String] = [], udp: (Int, [UInt8])? = nil,
                      audio: [String] = []) -> [String: Any] {
        var h: [String: Any] = ["proto": 1, "ver": "0.9.7", "os": "linux", "session": session, "resume_token": token,
                                "displays": [["id": 0, "w": 1920, "h": 1080, "primary": true, "name": "screen"]], "enc": ["h264"], "hw": "openh264", "needs": needs]
        if let (port, key) = udp { h["udp"] = ["port": port, "key": Data(key).base64EncodedString()] }
        if !audio.isEmpty { h["audio"] = audio }
        return h
    }
}

/// The plugin's UDP end in memory: answers heartbeats, rebuilds and acknowledges the phone's messages,
/// sends video; `blocked` drops everything both ways.
final class UdpHostStandIn: UdpTransport, @unchecked Sendable {
    var onReceive: (([UInt8]) -> Void)?
    private let crypto: UdpCrypto
    private let r = Reassembler()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "udp-host")
    private var seq: UInt64 = 1
    private var msg: Int64 = 0
    private var got: [Frame] = []
    private var _blocked = false
    private(set) var rebinds = 0
    var localPort: Int { 40000 + rebinds }

    init(key: [UInt8]) { crypto = UdpCrypto(key: key) }

    var blocked: Bool { get { lock.lock(); defer { lock.unlock() }; return _blocked } set { lock.lock(); _blocked = newValue; lock.unlock() } }
    var frames: [Frame] { lock.lock(); defer { lock.unlock() }; return got }

    private func seal(_ p: Packet) -> [UInt8] { defer { seq += 1 }; return crypto.seal(dir: UdpWire.DIR_S2C, seq: seq, p.encode()) }

    func send(_ datagram: [UInt8]) {
        lock.lock()
        guard !_blocked, let (_, _, plain) = crypto.open(datagram), let p = Packet.decode(plain) else { lock.unlock(); return }
        var replies: [[UInt8]] = []
        switch p {
        case .heartbeat(let t, _): replies.append(seal(.heartbeat(t: UdpLink.monotonicUs(), echo: t)))
        case .frag(let f):
            if let d = r.push(f, nowUs: 0), let frame = DesktopProtocol.read(d.bytes) { got.append(frame) }
            if f.msg % 2 == 1 && r.isDone(f.msg) { replies.append(seal(.rack(ids: [f.msg]))) }
        default: break
        }
        lock.unlock()
        let out = replies
        queue.async { out.forEach { self.onReceive?($0) } }
    }

    /// A video frame from the host over UDP.
    func video(_ bytes: [UInt8]) {
        lock.lock()
        if _blocked { lock.unlock(); return }
        msg += 2
        let out = UdpWire.fragment(msg: msg, flags: UdpWire.FLAG_VIDEO, bytes: bytes, ratio: 0.2).map { seal(.frag($0)) }
        lock.unlock()
        queue.async { out.forEach { self.onReceive?($0) } }
    }

    func rebind() throws { lock.lock(); rebinds += 1; lock.unlock() }
    func close() {}
}

func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !cond() { if Date() > end { return false }; Thread.sleep(forTimeInterval: 0.01) }
    return true
}
