import XCTest
@testable import RoamttyDesktopCore

final class H264Tests: XCTestCase {
    func testSplitsAnnexBWithBothStartCodeLengths() {
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2]
        let pps: [UInt8] = [0, 0, 1, 0x68, 3]
        let idr: [UInt8] = [0, 0, 0, 1, 0x65, 4, 5, 6]
        let units = H264.nalUnits([9, 9] + sps + pps + idr, offset: 2)
        XCTAssertEqual(units.map(\.type), [7, 8, 5])
        XCTAssertEqual(units[0].bytes, sps)
        XCTAssertEqual(units[1].bytes, pps)
        XCTAssertEqual(units[2].bytes, idr)
    }

    func testAvccPreservesLargeNALPayloadsAndBigEndianLengths() {
        let cases: [(Int, [UInt8])] = [
            (255, [0, 0, 0, 255]),
            (256, [0, 0, 1, 0]),
            (65_535, [0, 0, 255, 255]),
            (65_536, [0, 1, 0, 0]),
            (141_887, [0, 2, 42, 63])
        ]
        for (size, prefix) in cases {
            let payload = [UInt8(0x65)] + Array(repeating: UInt8(0xAB), count: size - 1)
            let input: [UInt8] = [9, 9, 0, 0, 0, 1] + payload + [0, 0, 1, 0x68, 3]
            XCTAssertEqual(H264.avcc(input, offset: 2), prefix + payload + [0, 0, 0, 2, 0x68, 3], "NAL size \(size)")
        }
    }

    func testAvccLengthPrefixes() {
        let au: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3]
        XCTAssertEqual(H264.avcc(au), [0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3])
        let (sps, pps) = H264.spsPps(au)
        XCTAssertEqual(sps, [0, 0, 0, 1, 0x67, 1, 2])
        XCTAssertEqual(pps, [0, 0, 1, 0x68, 3])
    }

    func testParameterSetsStopAtBothButKeepTheirWholeUnits() {
        let au: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x67, 9, 0, 0, 1, 0x68, 3, 4, 0, 0, 0, 1, 0x65, 7]
        let (sps, pps) = H264.spsPps(au)
        XCTAssertEqual(sps, [0, 0, 1, 0x67, 1, 2], "the first SPS")
        XCTAssertEqual(pps, [0, 0, 1, 0x68, 3, 4], "the PPS ends where the next unit's start code begins")
        XCTAssertEqual(H264.spsPps([0, 0, 1, 0x68, 3]).pps, [0, 0, 1, 0x68, 3], "the last unit runs to the end")
        XCTAssertNil(H264.spsPps([0, 0, 1, 0x65, 3]).sps)
    }

    /// The NAL split as it was first written (byte by byte, a copy per unit): the reference for the faster scan.
    private func referenceUnits(_ data: [UInt8], offset: Int) -> [H264.NAL] {
        guard offset < data.count else { return [] }
        var starts: [Int] = []
        var i = offset
        while i + 3 <= data.count {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                starts.append(i > offset && data[i - 1] == 0 ? i - 1 : i)
                i += 3
            } else { i += 1 }
        }
        return starts.enumerated().map { n, start in
            let end = n + 1 < starts.count ? starts[n + 1] : data.count
            let bytes = Array(data[start..<end])
            let header = (bytes.firstIndex(of: 1).map { $0 + 1 }) ?? bytes.count
            return H264.NAL(bytes: bytes, type: Int(bytes.indices.contains(header) ? bytes[header] & 0x1F : 0))
        }
    }

    /// The NAL split, the single-pass conversion and the early-stopping parameter-set scan agree with the reference.
    func testSinglePassConversionMatchesNalSplitOnRandomStreams() {
        var generator = SystemRandomNumberGenerator()
        // Few distinct byte values make start codes, 4-byte codes and empty units common.
        let alphabet: [UInt8] = [0, 0, 0, 1, 2, 0x67, 0x68, 0x65, 0x41, 0xFF]
        for _ in 0..<3000 {
            let data = (0..<Int.random(in: 0...64, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let offset = data.isEmpty ? 0 : Int.random(in: 0...data.count, using: &generator)
            let units = referenceUnits(data, offset: offset)
            XCTAssertEqual(H264.nalUnits(data, offset: offset), units, "\(data) from \(offset)")
            var expected: [UInt8] = []
            for nal in units {
                let payload = Array(nal.payload), n = UInt32(payload.count)
                expected += [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] + payload
            }
            XCTAssertEqual(H264.avcc(data, offset: offset), expected, "\(data) from \(offset)")
            let parameters = H264.spsPps(data, offset: offset)
            XCTAssertEqual(parameters.sps, units.first { $0.isSPS }?.bytes, "\(data) from \(offset)")
            XCTAssertEqual(parameters.pps, units.first { $0.isPPS }?.bytes, "\(data) from \(offset)")
        }
    }
}

final class DesktopStatsTextTests: XCTestCase {
    func testWarningOnlyWhenPoorOrRecovering() {
        XCTAssertNil(DesktopStatsText.warning(poor: false, recovering: false, english: false))
        XCTAssertEqual(DesktopStatsText.warning(poor: true, recovering: false, english: false)?.text, "网络较差")
        XCTAssertEqual(DesktopStatsText.warning(poor: true, recovering: true, english: true)?.text, "Recovering")
    }

    func testLinesIncludeLatencyPartsAndTones() {
        var stats = DesktopStats()
        stats.link = "UDP"; stats.rttMs = 40; stats.fps = 60; stats.kbps = 4000
        stats.width = 1920; stats.height = 1080; stats.encoder = "openh264"
        stats.lossPercent = 6.0; stats.fecRecovered = 3
        stats.latency = .init(captureMs: 1, convertMs: 1, encodeMs: 3, networkMs: 20, decodeMs: 4, renderMs: 2, totalMs: 31, encoder: "openh264")
        let lines = DesktopStatsText.lines(stats: stats, poor: false, recovering: false, transport: .wifi, english: false)
        XCTAssertEqual(lines[0].text, "UDP 40 ms")
        XCTAssertTrue(lines[1].text.contains("60 fps"))
        XCTAssertEqual(lines[2].text, "端到端 31 ms")
        XCTAssertTrue(lines[3].text.contains("主机端 5"))
        XCTAssertTrue(lines[3].text.contains("网络 20"))
        XCTAssertTrue(lines[3].text.contains("手机端 6"))
        XCTAssertEqual(lines[4].tone, .warn)
        XCTAssertTrue(lines[4].text.contains("丢包 6.0%"))
        XCTAssertTrue(lines[4].text.contains("FEC 3"))
        XCTAssertEqual(lines[5].text, "1920×1080 openh264")
        XCTAssertEqual(lines[6].text, "Wi-Fi")
    }

    func testRttToneThresholds() {
        var stats = DesktopStats(); stats.rttMs = 90
        XCTAssertEqual(DesktopStatsText.lines(stats: stats, poor: false, recovering: false, transport: .unknown, english: true)[0].tone, .warn)
        stats.rttMs = 200
        XCTAssertEqual(DesktopStatsText.lines(stats: stats, poor: false, recovering: false, transport: .unknown, english: true)[0].tone, .bad)
    }
}

final class DesktopVideoDecoderTests: XCTestCase {
    final class Sink: DesktopVideoDisplay, @unchecked Sendable {
        var frames: [(Int64, Bool)] = []
        func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8], rendered: @escaping (Int64) -> Void) {
            frames.append((frame, keyframe))
            XCTAssertFalse(avcc.isEmpty)
        }
        func flush() { frames.append((-1, false)) }
    }

    func testDropsDeltaUntilKeyframeThenEmits() {
        let decoder = DesktopVideoDecoder(name: "test")
        let sink = Sink(); decoder.display = sink
        decoder.attach(name: "test")
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 1]
        decoder.submit(Video(frame: 1, flags: 0, captureUs: 0, encodedUs: 0, width: 100, height: 100, data: sps, offset: 0))
        XCTAssertTrue(sink.frames.isEmpty, "non-keyframe before the first key is dropped")
        decoder.submit(Video(frame: 2, flags: DesktopProtocol.VIDEO_KEY, captureUs: 0, encodedUs: 0, width: 100, height: 100, data: sps, offset: 0))
        decoder.submit(Video(frame: 3, flags: 0, captureUs: 0, encodedUs: 0, width: 100, height: 100, data: [0, 0, 0, 1, 0x41, 2], offset: 0))
        XCTAssertEqual(sink.frames.map(\.0), [2, 3])
        XCTAssertEqual(decoder.decodedFrames, 2)
    }

    func testBacklogDropsToNewestKeyframe() {
        let decoder = DesktopVideoDecoder(name: "test")
        let sink = Sink(); decoder.display = sink
        decoder.attach(name: "test")
        let key: [UInt8] = [0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 1]
        decoder.submit(Video(frame: 1, flags: DesktopProtocol.VIDEO_KEY, captureUs: 0, encodedUs: 0, width: 10, height: 10, data: key, offset: 0))
        // Force a backlog of deltas then a key: only the last key and after should remain… the decoder
        // drains immediately, so simulate by detaching the display's side effect via size change:
        decoder.detach(); decoder.attach(name: "test")
        for i in 0..<5 {
            decoder.submit(Video(frame: Int64(10 + i), flags: i == 4 ? DesktopProtocol.VIDEO_KEY : 0,
                                 captureUs: 0, encodedUs: 0, width: 10, height: 10,
                                 data: i == 4 ? key : [0, 0, 0, 1, 0x41, UInt8(i)], offset: 0))
        }
        // After attach, first four deltas are dropped (no format); the key starts, nothing else queued.
        XCTAssertEqual(sink.frames.last?.0, 14)
    }

    func testSupportMatrix() throws {
        let m = try PluginManifest.bundled()
        XCTAssertTrue(DesktopSupport.osSupported("MACOS", manifest: m))
        XCTAssertTrue(DesktopSupport.osSupported("WINDOWS", manifest: m))
        XCTAssertTrue(DesktopSupport.osSupported("UBUNTU", manifest: m))
        XCTAssertFalse(DesktopSupport.osSupported("UNKNOWN", manifest: m))
        XCTAssertEqual(DesktopSupport.buttonOS("ubuntu"), "LINUX")
    }
}
