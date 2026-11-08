import XCTest
import RoamttyCore
import RoamttyDesktopCore
@testable import RoamttyTransport

/// The remote desktop's host operations over the real SSH and SFTP code, against the live OpenSSH fixture
/// (ROAMTTY_TEST_PASSWORD_FILE, as SSHExecTests). The desktop end to end over SSH additionally needs the
/// pinned plugin's release reachable and an X display owned by the fixture user: ROAMTTY_TEST_DESKTOP_SSH=1.
final class SSHDesktopHostTests: XCTestCase {
    private func connection() throws -> SSHConnection {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Live SSH fixture not configured") }
        let password = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = AuthMethod(rawValue: environment["ROAMTTY_TEST_AUTH"] ?? "password") ?? .password
        let host = RoamttyCore.Host(name: "Desktop fixture", address: environment["ROAMTTY_TEST_HOST"] ?? "127.0.0.1",
                                    port: Int(environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test", auth: auth)
        let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
            switch prompt {
            case .verifyHost: return ["fixture"]
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        try connection.connect()
        return connection
    }

    func testScriptsCommandsAndUploads() throws {
        let host = SSHDesktopHost(connection: try connection())
        defer { host.disconnect() }
        var lines: [String] = []
        XCTAssertEqual(host.run("echo one; echo two >&2; printf 'three\\n'; exit 5", timeout: 10) { lines.append($0) }, 5)
        XCTAssertEqual(Set(lines), ["one", "two", "three"])
        lines = []
        XCTAssertEqual(host.runCommand("echo cmd", timeout: 10) { lines.append($0) }, 0)
        XCTAssertEqual(lines, ["cmd"])
        let dir = ".roamtty-test-\(UUID().uuidString)"
        XCTAssertEqual(host.run("mkdir -p \"$HOME/\(dir)\"", timeout: 10) { _ in }, 0)
        defer { _ = host.run("rm -rf \"$HOME/\(dir)\"", timeout: 10) { _ in } }
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try host.upload(payload, to: "\(dir)/blob.part")
        lines = []
        XCTAssertEqual(host.run("sha256sum \"$HOME/\(dir)/blob.part\" | cut -d' ' -f1", timeout: 10) { lines.append($0) }, 0)
        XCTAssertEqual(lines, [PluginManifest.sha256Hex(payload)])
        XCTAssertThrowsError(try host.upload(payload, to: "\(dir)/blob.part"), "never overwrites")
        // The installer's place script over SSH: a tampered upload is refused and removed.
        try host.upload(payload + Data([1]), to: "\(dir)/bad.part")
        lines = []
        XCTAssertEqual(host.run(DesktopPluginInstaller.placeScript("$HOME/\(dir)/bad.part", sha: PluginManifest.sha256Hex(payload)), timeout: 10) { lines.append($0) }, 4)
        XCTAssertTrue(lines.contains { $0.hasPrefix(DesktopPluginInstaller.SHA_MISMATCH) })
    }

    func testStreamCarriesBinaryBothWaysAndReportsTheExit() throws {
        let host = SSHDesktopHost(connection: try connection())
        defer { host.disconnect() }
        // An echo server: whatever goes in comes back, binary safe.
        let echo = try XCTUnwrap(host.openStream("echo ready; cat"))
        var got: [UInt8] = []
        while !String(decoding: got, as: UTF8.self).contains("ready\n") { let b = echo.read(maxBytes: 1024); XCTAssertFalse(b.isEmpty); if b.isEmpty { break }; got += b }
        let blob = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        try echo.write(blob)
        var back: [UInt8] = []
        while back.count < blob.count { let b = echo.read(maxBytes: 65536); if b.isEmpty { break }; back += b }
        XCTAssertEqual(back, blob)
        echo.close()
        XCTAssertTrue(echo.read(maxBytes: 10).isEmpty, "read ends after close")
        XCTAssertThrowsError(try echo.write([1]))

        // A command that is not there: no output, its stderr and exit status 127 (the plugin is missing).
        let missing = try XCTUnwrap(host.openStream("\"$HOME/.roamtty-missing/bin/roamtty-desktop\" serve --proto 1"))
        XCTAssertTrue(missing.read(maxBytes: 1024).isEmpty)
        XCTAssertTrue(waitUntil(5) { missing.isClosed })
        XCTAssertEqual(missing.exitStatus, 127)
        XCTAssertTrue(missing.errorOutput.contains("No such file"), missing.errorOutput)

        // The connection is still usable for more channels.
        var lines: [String] = []
        XCTAssertEqual(host.run("echo still", timeout: 10) { lines.append($0) }, 0)
        XCTAssertEqual(lines, ["still"])
    }

    func testDisconnectEndsABlockedRead() throws {
        let host = SSHDesktopHost(connection: try connection())
        let stream = try XCTUnwrap(host.openStream("sleep 30"))
        let done = expectation(description: "read returns")
        DispatchQueue.global().async { _ = stream.read(maxBytes: 10); done.fulfill() }
        Thread.sleep(forTimeInterval: 0.3)
        host.disconnect()
        wait(for: [done], timeout: 5)
    }

    /// The phone fallback over real SFTP: the host cannot reach the release, the phone "downloads" the real
    /// pinned archive (from disk here), unpacks and checks it, uploads it and the host places it.
    func testPhoneDownloadAndSftpUploadOfThePinnedPlugin() throws {
        let path = ProcessInfo.processInfo.environment["ROAMTTY_DESKTOP_GZ"] ?? "/workspace/desktop-plugin/linux-x86_64.gz"
        guard let packed = FileManager.default.contents(atPath: path) else { throw XCTSkip("no plugin archive at \(path)") }
        let host = SSHDesktopHost(connection: try connection())
        defer { host.disconnect() }
        let manifest = try PluginManifest.bundled()
        let target = try XCTUnwrap(manifest.targets["linux-x86_64"])
        // A clean HOME for the plugin: the previous install moved aside.
        XCTAssertEqual(host.run(#"rm -rf "$HOME/.roamtty-saved"; [ -d "$HOME/.roamtty" ] && mv "$HOME/.roamtty" "$HOME/.roamtty-saved"; exit 0"#, timeout: 10) { _ in }, 0)
        defer { _ = host.run(#"rm -rf "$HOME/.roamtty"; [ -d "$HOME/.roamtty-saved" ] && mv "$HOME/.roamtty-saved" "$HOME/.roamtty"; exit 0"#, timeout: 10) { _ in } }
        var steps: [DesktopPluginInstaller.Step] = []
        var fetched: [String] = []
        let installer = DesktopPluginInstaller(remote: host, fetch: { fetched.append($0); return packed }, onStep: { steps.append($0) })
        let build = DesktopPluginInstaller.Build(version: manifest.version, url: "http://127.0.0.1:9/linux-x86_64.gz", sha256: target.sha256, openh264Url: nil)
        XCTAssertEqual(installer.install(build), .installed)
        XCTAssertEqual(steps, [.hostDownload, .phoneDownload, .upload, .verify, .register, .done])
        XCTAssertEqual(DesktopProbeScript.probe(host)?.version, manifest.version)
        var left: [String] = []
        _ = host.run(#"ls -A "$HOME/.roamtty/bin""#, timeout: 10) { left.append($0) }
        XCTAssertEqual(left, ["roamtty-desktop"], "no part files left")
    }

    /// The real thing over SSH: probe, install of the pinned release (the host downloads it, OpenH264
    /// from Cisco), serve, UDP, the first frame. Needs network access and an X display of the fixture user.
    func testDesktopEndToEndOverSSH() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_DESKTOP_SSH"] == "1" else { throw XCTSkip("Set ROAMTTY_TEST_DESKTOP_SSH=1") }
        _ = try connection().disconnect()
        final class Decoder: DesktopVideoSink, @unchecked Sendable {
            weak var session: DesktopSession?
            let lock = NSLock(); var count: Int64 = 0
            var decoderName: String { "test" }
            var decodedFrames: Int64 { lock.lock(); defer { lock.unlock() }; return count }
            func submit(_ video: Video) { lock.lock(); count += 1; lock.unlock(); session?.decoded(frame: video.frame, decodedUs: UdpLink.monotonicUs()) }
        }
        let decoder = Decoder()
        let config = DesktopSession.Config(hostName: "fixture", address: "127.0.0.1", clientWidth: 720, clientHeight: 1280, clientDpi: 160)
        let session = DesktopSession(config: config, manifest: try PluginManifest.bundled(), login: { [self] in
            do { return .host(SSHDesktopHost(connection: try connection())) } catch { return .failed(message: "\(error)", connecting: false) }
        })
        decoder.session = session
        session.video = decoder
        defer { session.close() }
        session.start()
        XCTAssertTrue(waitUntil(180) { if case .connected = session.phase { return true }; if case .failed = session.phase { return true }; return false })
        guard case .connected = session.phase else { return XCTFail("\(session.phase) \(session.log)") }
        print("desktop over SSH: log \(session.log)")
        XCTAssertTrue(waitUntil(5) { session.onUdp }, "UDP upgrade over SSH")
        XCTAssertGreaterThan(decoder.decodedFrames, 0)
    }

    private func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() { if Date() > end { return false }; Thread.sleep(forTimeInterval: 0.02) }
        return true
    }
}
