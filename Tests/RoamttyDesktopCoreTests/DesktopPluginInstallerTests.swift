import XCTest
@testable import RoamttyDesktopCore

/// Android `DesktopPluginInstallerTest`: the installer's scripts in a local shell whose HOME is a temporary directory.
final class DesktopPluginInstallerTests: XCTestCase {
    private var home: URL!
    private var local: LocalShellHost!
    private let binary = Data("#!/bin/sh\necho 'roamtty-desktop 0.1.0 proto 1'\n".utf8)
    private var packed = Data()
    private var sha: String { PluginManifest.sha256Hex(binary) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        local = LocalShellHost(home: home)
        // gzip of the fake binary, made by the host's own gzip.
        let src = home.appendingPathComponent("src")
        try binary.write(to: src)
        XCTAssertEqual(local.run("gzip -c src > release.gz", timeout: 5) { _ in }, 0)
        packed = try Data(contentsOf: home.appendingPathComponent("release.gz"))
        try FileManager.default.removeItem(at: src)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private var installed: URL { home.appendingPathComponent(".roamtty/bin/roamtty-desktop") }

    private func installer(_ fetched: Box<[String]>, _ steps: Box<[DesktopPluginInstaller.Step]>, body: Data? = nil) -> DesktopPluginInstaller {
        let body = body ?? packed
        return DesktopPluginInstaller(remote: local, fetch: { fetched.value.append($0); return body }, onStep: { steps.value.append($0) })
    }

    func testHostDownloadsItself() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/curl") else { throw XCTSkip("no curl") }
        let fetched = Box<[String]>([]), steps = Box<[DesktopPluginInstaller.Step]>([])
        let url = "file://" + home.appendingPathComponent("release.gz").path
        let result = installer(fetched, steps).install(.init(version: "0.1.0", url: url, sha256: sha, openh264Url: nil))
        XCTAssertEqual(result, .installed)
        XCTAssertTrue(fetched.value.isEmpty, "phone never downloads")
        XCTAssertEqual(try Data(contentsOf: installed), binary)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(steps.value, [.hostDownload, .register, .done])
    }

    func testPhoneDownloadsWhenTheHostCannot() throws {
        let fetched = Box<[String]>([]), steps = Box<[DesktopPluginInstaller.Step]>([])
        let url = "http://127.0.0.1:9/unreachable.gz"
        let result = installer(fetched, steps).install(.init(version: "0.1.0", url: url, sha256: sha, openh264Url: nil))
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(fetched.value, [url])
        XCTAssertEqual(steps.value, [.hostDownload, .phoneDownload, .upload, .verify, .register, .done])
        XCTAssertEqual(try Data(contentsOf: installed), binary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".roamtty/bin").path), ["roamtty-desktop"], "no part files left")
    }

    func testWrongChecksumIsRejected() {
        let result = installer(Box([]), Box([])).install(.init(version: "0.1.0", url: "http://127.0.0.1:9/x.gz", sha256: String(repeating: "00", count: 32), openh264Url: nil))
        guard case .failed(.checksum, _) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    func testPhoneDownloadThatIsNotGzipFailsTheChecksum() {
        let result = installer(Box([]), Box([]), body: Data("<html>".utf8)).install(.init(version: "0.1.0", url: "http://127.0.0.1:9/x.gz", sha256: sha, openh264Url: nil))
        guard case .failed(.checksum, _) = result else { return XCTFail("\(result)") }
    }

    func testPhoneDownloadFailureIsADownloadFailure() {
        struct Offline: Error {}
        let installer = DesktopPluginInstaller(remote: local, fetch: { _ in throw Offline() })
        guard case .failed(.download, _) = installer.install(.init(version: "0.1.0", url: "http://127.0.0.1:9/x.gz", sha256: sha, openh264Url: nil)) else { return XCTFail("an unreachable download must fail as a download") }
    }

    func testPlaceScriptRejectsATamperedUpload() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".roamtty/bin"), withIntermediateDirectories: true)
        let part = home.appendingPathComponent(".roamtty/bin/x.part")
        try (binary + Data([1])).write(to: part)
        var lines: [String] = []
        XCTAssertEqual(local.run(DesktopPluginInstaller.placeScript(part.path, sha: sha), timeout: 5) { lines.append($0) }, 4)
        XCTAssertTrue(lines.contains { $0.contains(DesktopPluginInstaller.SHA_MISMATCH) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    /// OpenH264: the plugin fetches it itself; when it cannot, the phone downloads Cisco's .bz2 and uploads it.
    func testEncoderFallsBackToThePhone() throws {
        // A fake plugin whose `install` fails without --openh264 and records the file it got.
        let plugin = Data("""
        #!/bin/sh
        case "$1" in
          --version) echo 'roamtty-desktop 0.1.0 proto 1' ;;
          install) if [ "$2" = --openh264 ]; then cp "$3" "$HOME/got.bz2"; echo "openh264 ok"; else echo "fetch failed"; exit 3; fi ;;
        esac
        """.utf8)
        let src = home.appendingPathComponent("p")
        try plugin.write(to: src)
        XCTAssertEqual(local.run("gzip -c p > plugin.gz", timeout: 5) { _ in }, 0)
        let pluginGz = try Data(contentsOf: home.appendingPathComponent("plugin.gz"))
        let cisco = Data("BZh9-fake-openh264".utf8)
        let fetched = Box<[String]>([]), steps = Box<[DesktopPluginInstaller.Step]>([])
        let installer = DesktopPluginInstaller(remote: local, fetch: { url in
            fetched.value.append(url); return url.hasSuffix(".bz2") ? cisco : pluginGz
        }, onStep: { steps.value.append($0) })
        let result = installer.install(.init(version: "0.1.0", url: "http://127.0.0.1:9/linux-x86_64.gz", sha256: PluginManifest.sha256Hex(plugin),
                                              openh264Url: "http://127.0.0.1:9/libopenh264-2.6.0-linux64.8.so.bz2"))
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(steps.value, [.hostDownload, .phoneDownload, .upload, .verify, .encoderHost, .encoderPhone, .register, .done])
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("got.bz2")), cisco)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".roamtty/desktop").path), [], "the upload is removed")
    }

    func testPinnedBuildsCarryTheirEncoder() throws {
        let manifest = try PluginManifest.bundled()
        let linux = try XCTUnwrap(DesktopPluginInstaller.Build.pinned(manifest, target: "linux-x86_64"))
        XCTAssertEqual(linux.version, "0.9.7")
        XCTAssertTrue(linux.url.hasSuffix("linux-x86_64.gz"))
        XCTAssertTrue(linux.openh264Url?.hasPrefix(PluginManifest.OPENH264_BASE + "/") == true)
        let mac = try XCTUnwrap(DesktopPluginInstaller.Build.pinned(manifest, target: "macos-universal"))
        XCTAssertTrue(mac.app)
        XCTAssertNil(mac.openh264Url, "macOS encodes with VideoToolbox")
    }

    func testMirrorKeepsThePinnedBuildAndItsChecksums() throws {
        let pinned = try PluginManifest.bundled()
        let mirror = pinned.withBaseUrl("https://mirror.example/desktop/")
        XCTAssertEqual(mirror.baseUrl, "https://mirror.example/desktop/")
        XCTAssertEqual(mirror.targets, pinned.targets)
        XCTAssertEqual([mirror.version, mirror.openh264], [pinned.version, pinned.openh264])
        XCTAssertEqual([mirror.protoMin, mirror.protoMax], [pinned.protoMin, pinned.protoMax])
        let target = try XCTUnwrap(mirror.targets["linux-x86_64"])
        XCTAssertEqual(mirror.url(target), "https://mirror.example/desktop/" + target.file)
        XCTAssertEqual(pinned.withBaseUrl(pinned.baseUrl), pinned)
    }

    func testZipBuildsAreApps() {
        XCTAssertTrue(DesktopPluginInstaller.Build(version: "1", url: "https://x/macos-universal.zip", sha256: "a", openh264Url: nil).app)
        XCTAssertFalse(DesktopPluginInstaller.Build(version: "1", url: "https://x/linux-x86_64.gz", sha256: "a", openh264Url: nil).app)
        let script = DesktopPluginInstaller.placeAppScript("/tmp/x.zip", sha: "ab")
        XCTAssertTrue(script.contains("ditto -x -k") && script.contains("ln -sf") && script.contains("Roamtty Desktop.app"))
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
