import Foundation

/// The roamtty-desktop wire protocol (PROTOCOL.md in the plugin repository): a JSON hello line,
/// then `u8 type | u24 len | payload` frames, big endian. The plugin's golden samples in
/// Tests/RoamttyDesktopCoreTests/Resources/desktop-proto keep both sides in step.
/// Port of Android `desktop-core/DesktopProtocol.kt` (roamtty #218).
public enum DesktopProtocol {
    /// The protocol versions this app speaks.
    public static let supported: ClosedRange<Int> = 1...1
    public static let maxLen = (1 << 24) - 1

    public static let CONFIG = 0x01
    public static let INPUT = 0x02
    public static let ACTION = 0x03
    public static let REQ = 0x04
    public static let ACK = 0x05
    public static let CLIP_SET = 0x06
    public static let PING = 0x07
    public static let PONG = 0x08
    public static let VIDEO = 0x81
    public static let CURSOR_POS = 0x82
    public static let CURSOR_SHAPE = 0x83
    public static let STATE = 0x84
    public static let AUDIO = 0x85

    public static let REQ_KEYFRAME = 1
    public static let REQ_PAUSE = 2
    public static let REQ_RESUME = 3
    public static let REQ_VIEW_ONLY_ON = 4
    public static let REQ_VIEW_ONLY_OFF = 5
    public static let REQ_CLIP_GET = 6

    public static let ACTION_SHOW_DESKTOP = 1
    public static let ACTION_ALL_WINDOWS = 2

    public static let VIDEO_KEY = 1
    public static let VIDEO_REFINE = 2

    public static func frame(_ type: Int, _ payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= maxLen, "frame too long")
        let n = payload.count
        return [UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8),
                UInt8(truncatingIfNeeded: n)] + payload
    }

    /// One frame from the front of `bytes`, or nil when they do not hold a whole one yet.
    public static func read(_ bytes: [UInt8]) -> Frame? {
        var parser = FrameParser(expectHello: false)
        parser.push(bytes)
        if case .frame(let f)? = parser.next() { return f }
        return nil
    }

    public static func parseStart(_ line: String) -> Start {
        guard let json = JSONValue.object(line) else { return .failed(code: "internal", detail: "bad hello: \(String(line.prefix(200)))") }
        if json["error"] != nil {
            let detail = JSONValue.string(json["detail"])
            return .failed(code: JSONValue.string(json["error"]), detail: detail.isEmpty ? nil : detail,
                           min: json["min"] != nil ? (JSONValue.int(json["min"]) ?? 0) : nil,
                           max: json["max"] != nil ? (JSONValue.int(json["max"]) ?? 0) : nil)
        }
        guard let hello = Hello.parse(json) else { return .failed(code: "internal", detail: "bad hello: \(String(line.prefix(200)))") }
        return .ready(hello)
    }

    // MARK: Client messages

    /// CONFIG with a JSON object (keys sorted; the plugin does not care about order).
    public static func config(_ values: [String: Any]) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        return frame(CONFIG, Array(data))
    }

    public static func abs(display: Int, x: Int, y: Int) -> [UInt8] {
        input(1) { $0.u8(display); $0.u16(x); $0.u16(y) }
    }
    public static func rel(dx: Int, dy: Int) -> [UInt8] { input(2) { $0.u16(clamp16(dx)); $0.u16(clamp16(dy)) } }
    public static func button(_ button: Int, down: Bool) -> [UInt8] { input(3) { $0.u8(button); $0.u8(down ? 1 : 0) } }
    public static func wheel(dx: Int, dy: Int) -> [UInt8] { input(4) { $0.u16(clamp16(dx)); $0.u16(clamp16(dy)) } }
    public static func key(_ hid: Int, down: Bool) -> [UInt8] { input(5) { $0.u16(hid); $0.u8(down ? 1 : 0) } }
    public static func text(_ text: String) -> [UInt8] { frame(INPUT, [6] + Array(text.utf8)) }
    public static func action(_ action: Int) -> [UInt8] { frame(ACTION, [UInt8(truncatingIfNeeded: action)]) }
    public static func req(_ req: Int) -> [UInt8] { frame(REQ, [UInt8(truncatingIfNeeded: req)]) }
    public static func ack(frame f: Int64, recvUs: Int64, decodedUs: Int64) -> [UInt8] {
        var w = ByteWriter(capacity: 20); w.u32(f); w.i64(recvUs); w.i64(decodedUs)
        return frame(ACK, w.bytes)
    }
    public static func clipSet(_ text: String) -> [UInt8] { frame(CLIP_SET, Array(text.utf8)) }
    public static func ping(_ t1: Int64) -> [UInt8] { var w = ByteWriter(); w.i64(t1); return frame(PING, w.bytes) }
    public static func pong(_ t1: Int64, _ t2: Int64, _ t3: Int64) -> [UInt8] {
        var w = ByteWriter(); w.i64(t1); w.i64(t2); w.i64(t3); return frame(PONG, w.bytes)
    }

    private static func clamp16(_ v: Int) -> Int { Swift.min(Swift.max(v, -32768), 32767) }

    private static func input(_ kind: Int, _ fill: (inout ByteWriter) -> Void) -> [UInt8] {
        var w = ByteWriter(capacity: 6)
        w.u8(kind)
        fill(&w)
        return frame(INPUT, w.bytes)
    }

    /// Decodes a frame from the plugin; nil for types this app does not know (or a short payload).
    public static func decode(_ frame: Frame) -> ServerMessage? {
        var b = ByteReader(frame.payload)
        switch frame.type {
        case VIDEO:
            guard let n = b.u32(), let flags = b.u8(), let cap = b.i64(), let enc = b.i64(), let w = b.u16(), let h = b.u16() else { return nil }
            return .video(Video(frame: n, flags: flags, captureUs: cap, encodedUs: enc, width: w, height: h, data: frame.payload, offset: 25))
        case CURSOR_POS:
            guard let x = b.u16(), let y = b.u16(), let v = b.u8(), let shape = b.u64() else { return nil }
            return .cursorPos(x: x, y: y, visible: v != 0, shape: shape)
        case CURSOR_SHAPE:
            guard let hash = b.u64(), let w = b.u16(), let h = b.u16(), let hx = b.u16(), let hy = b.u16() else { return nil }
            return .cursorShape(hash: hash, width: w, height: h, hotX: hx, hotY: hy, rgba: b.rest())
        case AUDIO:
            guard let seq = b.u32(), let cap = b.i64() else { return nil }
            return .audio(Audio(seq: seq, captureUs: cap, data: frame.payload, offset: 12))
        case STATE:
            guard let json = JSONValue.object(String(decoding: frame.payload, as: UTF8.self)) else { return nil }
            return .state(StateMessage(json: json))
        case PING:
            guard let t1 = b.i64() else { return nil }
            return .ping(t1: t1)
        case PONG:
            guard let t1 = b.i64(), let t2 = b.i64(), let t3 = b.i64() else { return nil }
            return .pong(t1: t1, t2: t2, t3: t3)
        default:
            return nil
        }
    }
}

public struct Frame: Equatable, Sendable {
    public let type: Int
    public let payload: [UInt8]
    public init(type: Int, payload: [UInt8]) { self.type = type; self.payload = payload }
}

/// Push-based reader of the serve stream: the hello line (read byte by byte so nothing after it is
/// taken), then frames. Feed it what the SSH channel delivers in whatever chunks it comes.
public struct FrameParser {
    public enum Item: Equatable { case hello(String), frame(Frame), tooLong }

    private var buffer: [UInt8] = []
    private var start = 0
    private var expectHello: Bool
    private let maxLine: Int

    public init(expectHello: Bool = true, maxLine: Int = 64 * 1024) {
        self.expectHello = expectHello
        self.maxLine = maxLine
    }

    public mutating func push<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        if start > 0 && start > buffer.count / 2 { buffer.removeFirst(start); start = 0 }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole item, or nil until more bytes come.
    public mutating func next() -> Item? {
        if expectHello {
            if let nl = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[start..<nl], as: UTF8.self)
                start = nl + 1
                expectHello = false
                return .hello(line)
            }
            if buffer.count - start >= maxLine { return .tooLong }
            return nil
        }
        guard buffer.count - start >= 4 else { return nil }
        let n = Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard buffer.count - start >= 4 + n else { return nil }
        let f = Frame(type: Int(buffer[start]), payload: Array(buffer[(start + 4)..<(start + 4 + n)]))
        start += 4 + n
        return .frame(f)
    }

    /// Bytes received but not yet returned.
    public var pending: Int { buffer.count - start }
}

public struct DisplayInfo: Equatable, Sendable {
    public let id: Int, width: Int, height: Int
    public let scale: Double
    public let x: Int, y: Int
    public let primary: Bool
    public let name: String
}

/// The UDP transport's port on the host and its session key (16 bytes, never stored).
public struct UdpOffer: Equatable, Sendable {
    public let port: Int
    public let key: [UInt8]
}

public struct Hello: Equatable, Sendable {
    public let proto: Int
    public let version: String, os: String, session: String, resumeToken: String
    public let displays: [DisplayInfo]
    public let encoders: [String]
    public let hardware: String
    public let needs: [String]
    public let udp: UdpOffer?
    /// The sound codecs the host can send (`opus`); empty before plugin 0.9.0.
    public let audio: [String]

    static func parse(_ json: [String: Any]) -> Hello? {
        guard let proto = JSONValue.int(json["proto"]) else { return nil }
        let displays = ((json["displays"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { d -> DisplayInfo? in
            guard let id = JSONValue.int(d["id"]), let w = JSONValue.int(d["w"]), let h = JSONValue.int(d["h"]) else { return nil }
            return DisplayInfo(id: id, width: w, height: h, scale: JSONValue.double(d["scale"]) ?? 1.0, x: JSONValue.int(d["x"]) ?? 0,
                               y: JSONValue.int(d["y"]) ?? 0, primary: JSONValue.bool(d["primary"]) ?? false, name: JSONValue.string(d["name"]))
        }
        var udp: UdpOffer?
        if let u = json["udp"] as? [String: Any], let port = JSONValue.int(u["port"]), let key = u["key"] as? String,
           let data = Data(base64Encoded: key), data.count == 16 {
            udp = UdpOffer(port: port, key: Array(data))
        }
        return Hello(proto: proto, version: JSONValue.string(json["ver"]), os: JSONValue.string(json["os"]),
                     session: JSONValue.string(json["session"]), resumeToken: JSONValue.string(json["resume_token"]),
                     displays: displays, encoders: JSONValue.strings(json["enc"]), hardware: JSONValue.string(json["hw"]),
                     needs: JSONValue.strings(json["needs"]), udp: udp, audio: JSONValue.strings(json["audio"]))
    }
}

public enum Start: Equatable, Sendable {
    case ready(Hello)
    /// `code` as in the protocol: proto_unsupported, no_desktop, not_logged_in, permission, …
    case failed(code: String, detail: String?, min: Int? = nil, max: Int? = nil)
}

/// `data` from `offset` on is the H.264 Annex-B access unit.
public struct Video: Equatable, Sendable {
    public let frame: Int64
    public let flags: Int
    public let captureUs: Int64, encodedUs: Int64
    public let width: Int, height: Int
    public let data: [UInt8]
    public let offset: Int
    public var keyframe: Bool { flags & DesktopProtocol.VIDEO_KEY != 0 }
}

/// One 20 ms Opus packet of 48 kHz stereo, from `offset` on; `seq` goes up by one per packet the host made.
public struct Audio: Equatable, Sendable {
    public let seq: Int64
    public let captureUs: Int64
    public let data: [UInt8]
    public let offset: Int
    public var packet: ArraySlice<UInt8> { data[min(offset, data.count)...] }
}

/// STATE: a JSON object whose fields come and go with the plugin version.
public struct StateMessage: @unchecked Sendable {
    public let json: [String: Any]
    public var kicked: Bool { JSONValue.bool(json["kicked"]) ?? false }
    public var clip: String? { json["clip"] != nil ? JSONValue.string(json["clip"]) : nil }
    public var needs: [String]? { json["needs"] is [Any] ? JSONValue.strings(json["needs"]) : nil }
    public var locked: Bool? { json["locked"] != nil ? (JSONValue.bool(json["locked"]) ?? false) : nil }
    public var error: String? { let e = JSONValue.string(json["error"]); return e.isEmpty ? nil : e }
    /// The host's share of a frame's latency (plugin ≥ 0.6.0).
    public var timing: [String: Any]? { json["timing"] as? [String: Any] }
    /// `unavailable` when the host cannot capture its sound (plugin ≥ 0.9.0).
    public var audio: String? { let a = JSONValue.string(json["audio"]); return a.isEmpty ? nil : a }
}

public enum ServerMessage: Sendable {
    case video(Video)
    case cursorPos(x: Int, y: Int, visible: Bool, shape: UInt64)
    case cursorShape(hash: UInt64, width: Int, height: Int, hotX: Int, hotY: Int, rgba: [UInt8])
    case state(StateMessage)
    case audio(Audio)
    case ping(t1: Int64)
    case pong(t1: Int64, t2: Int64, t3: Int64)
}
