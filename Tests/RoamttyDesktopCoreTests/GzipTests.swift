import XCTest
@testable import RoamttyDesktopCore

/// The phone unpacks a `linux-*.gz` itself before checking its SHA-256 (Android: GZIPInputStream).
final class GzipTests: XCTestCase {
    private func systemGzip(_ data: Data, level: String = "-6") throws -> [UInt8] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "gzip -c \(level)"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try p.run()
        DispatchQueue.global().async { try? input.fileHandleForWriting.write(contentsOf: data); try? input.fileHandleForWriting.close() }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Array(out)
    }

    func testMatchesSystemGzipAcrossBlockKinds() throws {
        var rng = SystemRandomNumberGenerator()
        let random = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let text = Data(String(repeating: "roamtty-desktop serve --proto 1 ", count: 20_000).utf8)
        let mixed = text + random.prefix(50_000) + text
        for (data, level) in [(Data(), "-6"), (Data("a".utf8), "-6"), (text, "-1"), (text, "-9"), (random, "-6"), (mixed, "-6"), (text, "-0")] {
            let packed = try systemGzip(data, level: level == "-0" ? "-1" : level)
            XCTAssertEqual(try Gzip.decompress(packed), Array(data), "level \(level), \(data.count) bytes")
        }
    }

    func testRejectsCorruption() throws {
        var packed = try systemGzip(Data(String(repeating: "x", count: 1000).utf8))
        packed[packed.count - 6] ^= 0xFF // CRC-32
        XCTAssertThrowsError(try Gzip.decompress(packed))
        XCTAssertThrowsError(try Gzip.decompress([0x1f, 0x8b]))
        XCTAssertThrowsError(try Gzip.decompress(Array("not gzip".utf8)))
    }

    func testCrc32() {
        XCTAssertEqual(Gzip.crc32(Array("123456789".utf8)), 0xCBF43926)
    }

    /// The real pinned plugin, when the box has it: unpacked, it is the pinned SHA-256.
    func testRealPluginArchive() throws {
        let path = ProcessInfo.processInfo.environment["ROAMTTY_DESKTOP_GZ"] ?? "/workspace/desktop-plugin/linux-x86_64.gz"
        guard let packed = FileManager.default.contents(atPath: path) else { throw XCTSkip("no plugin archive at \(path)") }
        let manifest = try PluginManifest.bundled()
        let binary = try Gzip.decompress(Array(packed))
        XCTAssertEqual(PluginManifest.sha256Hex(Data(binary)), manifest.targets["linux-x86_64"]?.sha256)
    }
}
