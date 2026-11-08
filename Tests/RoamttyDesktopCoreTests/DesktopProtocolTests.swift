import Foundation
import XCTest
@testable import RoamttyDesktopCore

/// The Swift codec against the plugin's golden samples (roamtty-desktop/testdata); mirrors Android's DesktopProtocolTest.
final class DesktopProtocolTests: XCTestCase {
    private func read(_ name: String) -> Frame { DesktopProtocol.read(Golden.bytes(name))! }

    func testClientMessagesMatchGoldenBytes() throws {
        XCTAssertEqual(Golden.bytes("input-abs.bin"), DesktopProtocol.abs(display: 0, x: 1512, y: 982))
        XCTAssertEqual(Golden.bytes("input-rel.bin"), DesktopProtocol.rel(dx: -5, dy: 12))
        XCTAssertEqual(Golden.bytes("input-button.bin"), DesktopProtocol.button(2, down: true))
        XCTAssertEqual(Golden.bytes("input-wheel.bin"), DesktopProtocol.wheel(dx: 0, dy: -240))
        XCTAssertEqual(Golden.bytes("input-key.bin"), DesktopProtocol.key(0xE3, down: true))
        XCTAssertEqual(Golden.bytes("input-text.bin"), DesktopProtocol.text("你好 ok"))
        XCTAssertEqual(Golden.bytes("action.bin"), DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS))
        XCTAssertEqual(Golden.bytes("req.bin"), DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME))
        XCTAssertEqual(Golden.bytes("ack.bin"), DesktopProtocol.ack(frame: 7, recvUs: 1_000_001, decodedUs: 1_004_002))
        XCTAssertEqual(Golden.bytes("clip-set.bin"), DesktopProtocol.clipSet("copied"))
        XCTAssertEqual(Golden.bytes("ping.bin"), DesktopProtocol.ping(123_456_789))
        XCTAssertEqual(Golden.bytes("pong.bin"), DesktopProtocol.pong(1, 2, 3))
        // JSON key order is free; compare the decoded object.
        let config = read("config.bin")
        XCTAssertEqual(DesktopProtocol.CONFIG, config.type)
        let ours = DesktopProtocol.read(DesktopProtocol.config(["fps": 60, "quality": "clear"]))!
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.payload)) as? NSDictionary)
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ours.payload)) as? NSDictionary)
        XCTAssertEqual(a, b)
    }

    func testClampsPointerDeltas() {
        XCTAssertEqual(DesktopProtocol.rel(dx: 100_000, dy: -100_000), DesktopProtocol.rel(dx: 32767, dy: -32768))
    }

    func testServerMessagesDecode() {
        guard case .video(let video)? = DesktopProtocol.decode(read("video.bin")) else { return XCTFail("video") }
        XCTAssertEqual(42, video.frame)
        XCTAssertTrue(video.keyframe)
        XCTAssertEqual(0, video.flags & DesktopProtocol.VIDEO_REFINE)
        XCTAssertEqual(10, video.captureUs)
        XCTAssertEqual(20, video.encodedUs)
        XCTAssertEqual([1920, 1080], [video.width, video.height])
        XCTAssertEqual([0, 0, 0, 1, 0x67, 0x42], Array(video.data[video.offset...]))

        guard case .cursorPos(let x, let y, let visible, let shape)? = DesktopProtocol.decode(read("cursor-pos.bin")) else { return XCTFail("pos") }
        XCTAssertEqual(300, x); XCTAssertEqual(200, y); XCTAssertTrue(visible); XCTAssertEqual(0xDEADBEEF, shape)

        guard case .cursorShape(let hash, let w, let h, let hx, let hy, let rgba)? = DesktopProtocol.decode(read("cursor-shape.bin")) else {
            return XCTFail("shape")
        }
        XCTAssertEqual(0xDEADBEEF, hash)
        XCTAssertEqual([2, 1, 1, 0], [w, h, hx, hy])
        XCTAssertEqual(8, rgba.count)

        guard case .state(let state)? = DesktopProtocol.decode(read("state.bin")) else { return XCTFail("state") }
        XCTAssertTrue(state.kicked)

        guard case .audio(let audio)? = DesktopProtocol.decode(read("audio.bin")) else { return XCTFail("audio") }
        XCTAssertEqual(9, audio.seq)
        XCTAssertEqual(30, audio.captureUs)
        XCTAssertEqual([0xFC, 0xFF, 0xFE], Array(audio.packet))
    }

    func testHelloParses() {
        let line = String(decoding: Golden.bytes("hello.json"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .ready(let hello) = DesktopProtocol.parseStart(line) else { return XCTFail("not ready") }
        XCTAssertEqual(1, hello.proto)
        XCTAssertEqual("linux", hello.os)
        XCTAssertEqual(1, hello.displays.count)
        XCTAssertEqual(1920, hello.displays.first?.width)
        XCTAssertEqual(true, hello.displays.first?.primary)
        XCTAssertEqual(["h264"], hello.encoders)
        XCTAssertTrue(hello.needs.isEmpty)
        XCTAssertNil(hello.udp)
        XCTAssertEqual(["opus"], hello.audio)
    }

    func testHelloUdpOffer() {
        let key = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        guard case .ready(let hello) = DesktopProtocol.parseStart(#"{"proto":1,"udp":{"port":40123,"key":"\#(key)"}}"#) else { return XCTFail("a start line with a UDP key must be ready") }
        XCTAssertEqual(UdpOffer(port: 40123, key: (0..<16).map { UInt8($0) }), hello.udp)
        // A key of the wrong length is no offer.
        guard case .ready(let short) = DesktopProtocol.parseStart(#"{"proto":1,"udp":{"port":1,"key":"AAAA"}}"#) else { return XCTFail("a short key still parses as ready") }
        XCTAssertNil(short.udp)
    }

    func testStartErrorsParse() {
        XCTAssertEqual(.failed(code: "proto_unsupported", detail: nil, min: 2, max: 3),
                       DesktopProtocol.parseStart(#"{"error":"proto_unsupported","min":2,"max":3}"#))
        XCTAssertEqual(.failed(code: "no_desktop", detail: "no X display"),
                       DesktopProtocol.parseStart(#"{"error":"no_desktop","detail":"no X display"}"#))
        guard case .failed(let code, _, _, _) = DesktopProtocol.parseStart("bash: not json") else { return XCTFail("a shell error must fail the start") }
        XCTAssertEqual("internal", code)
    }

    func testHelloLineLeavesFramesUnread() {
        var p = FrameParser()
        p.push(Array("{\"a\":1}\n".utf8) + DesktopProtocol.ping(5))
        XCTAssertEqual(.hello("{\"a\":1}"), p.next())
        guard case .frame(let f)? = p.next(), case .ping(let t1)? = DesktopProtocol.decode(f) else { return XCTFail("expected a ping frame") }
        XCTAssertEqual(5, t1)
        XCTAssertNil(p.next())
    }

    func testParserTakesAnyChunking() {
        let stream = Array("{\"proto\":1}\n".utf8) + DesktopProtocol.ping(1) + DesktopProtocol.text("你好") + DesktopProtocol.req(1)
        var p = FrameParser()
        var items: [FrameParser.Item] = []
        for b in stream { p.push([b]); while let i = p.next() { items.append(i) } }
        XCTAssertEqual(4, items.count)
        XCTAssertEqual(.frame(DesktopProtocol.read(DesktopProtocol.text("你好"))!), items[2])
        XCTAssertEqual(0, p.pending)
    }

    func testManifestAndTargets() throws {
        let m = try PluginManifest.parse(#"""
        {"version":"0.1.0","baseUrl":"https://x/releases/download/v0.1.0/","proto":{"min":1,"max":1},
         "openh264":"2.6.0","targets":{"linux-x86_64":{"file":"linux-x86_64.gz","sha256":"ab","size":9}}}
        """#)
        XCTAssertEqual("https://x/releases/download/v0.1.0/linux-x86_64.gz", m.url(m.targets["linux-x86_64"]!))
        XCTAssertEqual("linux-x86_64", PluginManifest.targetFor("Linux x86_64\n"))
        XCTAssertEqual("linux-aarch64", PluginManifest.targetFor("Linux aarch64"))
        XCTAssertEqual("macos-universal", PluginManifest.targetFor("Darwin arm64"))
        XCTAssertNil(PluginManifest.targetFor("Linux riscv64"))
        XCTAssertEqual("windows-x64", PluginManifest.targetFor("Windows AMD64"))
        XCTAssertEqual("windows-arm64", PluginManifest.targetFor("Windows ARM64"))
        XCTAssertEqual("openh264-2.6.0-win64.dll.bz2", PluginManifest.openh264File(target: "windows-x64", version: "2.6.0"))
        XCTAssertNil(PluginManifest.openh264File(target: "macos-universal", version: "2.6.0"))
        XCTAssertEqual("libopenh264-2.6.0-linux64.8.so.bz2", PluginManifest.openh264File(target: "linux-x86_64", version: "2.6.0"))
    }

    /// Verified against the decompressed official v0.9.7 release on 2026-10-31.
    func testBundledManifestMatchesVerifiedReleasePin() throws {
        let m = try PluginManifest.bundled()
        XCTAssertEqual("0.9.7", m.version)
        XCTAssertEqual("https://github.com/yahaa/roamtty-desktop/releases/download/v0.9.7/", m.baseUrl)
        XCTAssertEqual("2.6.0", m.openh264)
        XCTAssertEqual(1...1, m.protoMin...m.protoMax)
        XCTAssertEqual(["linux-aarch64", "linux-x86_64", "macos-universal", "windows-arm64", "windows-x64"], m.targets.keys.sorted())
        XCTAssertEqual("c6147b37bc94b4f16b808cfd152838c4bfcbc379044d0fdfd65841153c316310", m.targets["linux-x86_64"]?.sha256)
        XCTAssertEqual(1861424, m.targets["linux-x86_64"]?.size)
        XCTAssertTrue(DesktopProtocol.supported.contains(m.protoMin))
    }

    func testSha256Pin() {
        let t = PluginManifest.Target(file: "x", sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", size: 3)
        let m = PluginManifest(version: "1", baseUrl: "b", protoMin: 1, protoMax: 1, openh264: "", targets: ["x": t])
        XCTAssertTrue(m.verify(Data("abc".utf8), target: t))
        XCTAssertFalse(m.verify(Data("abd".utf8), target: t))
    }
}
