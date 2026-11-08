import XCTest
@testable import RoamttyDesktopCore

/// Android `DesktopPluginInstallerTest.probeParsesDesktop` / `probeScriptRunsInAPosixShell`, for the iOS standalone probe.
final class DesktopProbeTests: XCTestCase {
    func testParsesDesktop() {
        let out = "__ITERMUX_TMUX__=/usr/bin/tmux\n__ITERMUX_MOSH__=\n__ITERMUX_DESKTOP__=yes\n__ITERMUX_UNAME__=Linux x86_64\n__ITERMUX_DESKTOP_PLUGIN__=roamtty-desktop 0.1.0 proto 1\n"
        XCTAssertEqual(DesktopProbeScript.parse(out), HostDesktop(desktop: "yes", uname: "Linux x86_64", pluginVersion: "roamtty-desktop 0.1.0 proto 1"))
        XCTAssertEqual(DesktopProbeScript.parse(out)?.version, "0.1.0")
        XCTAssertEqual(DesktopProbeScript.parse(out)?.probe, .yes)
        let none = "__ITERMUX_DESKTOP__=no\n__ITERMUX_UNAME__=Linux x86_64\n__ITERMUX_DESKTOP_PLUGIN__=\n"
        XCTAssertNil(DesktopProbeScript.parse(none)?.pluginVersion)
        XCTAssertNil(DesktopProbeScript.parse(none)?.version)
        XCTAssertEqual(DesktopProbeScript.parse(none)?.desktop, "no")
        XCTAssertNil(DesktopProbeScript.parse("__ITERMUX_TMUX__=\n"))
        XCTAssertNil(DesktopProbeScript.parse(nil))
        XCTAssertNil(DesktopProbeScript.parse("__ITERMUX_DESKTOP__=maybe\n"))
        // Output of a shell that is not the plugin is not a version.
        XCTAssertNil(DesktopProbeScript.parse("__ITERMUX_DESKTOP__=yes\n__ITERMUX_DESKTOP_PLUGIN__=sh: not found\n")?.pluginVersion)
    }

    func testScriptRunsInAPosixShell() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var lines: [String] = []
        let host = LocalShellHost(home: home)
        XCTAssertEqual(host.run(DesktopProbeScript.script, timeout: 10) { lines.append($0) }, 0)
        let desktop = try XCTUnwrap(DesktopProbeScript.parse(lines.joined(separator: "\n")), lines.joined(separator: "\n"))
        #if os(macOS)
        XCTAssertTrue(desktop.uname.hasPrefix("Darwin"), desktop.uname)
        #else
        XCTAssertTrue(desktop.uname.hasPrefix("Linux"), desktop.uname)
        #endif
        XCTAssertNil(desktop.pluginVersion, "nothing installed under this HOME")
        // Installed: the probe reads its version line.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".roamtty/bin"), withIntermediateDirectories: true)
        let bin = home.appendingPathComponent(".roamtty/bin/roamtty-desktop")
        try Data("#!/bin/sh\necho 'roamtty-desktop 0.8.2 proto 1'\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        XCTAssertEqual(DesktopProbeScript.probe(host)?.version, "0.8.2")
    }

    /// No POSIX shell answered: the PowerShell probe goes next.
    func testFallsBackToPowerShell() throws {
        let host = LocalShellHost(home: FileManager.default.temporaryDirectory)
        host.environment["PATH"] = "/nonexistent"
        let probeFails = LocalShellHostThatFails(host)
        probeFails.runCommandHandler = { command in
            XCTAssertEqual(command, WindowsDesktop.probeCommand)
            return (0, ["__ITERMUX_DESKTOP__=nologin", "__ITERMUX_UNAME__=Windows ARM64", "__ITERMUX_DESKTOP_PLUGIN__="])
        }
        let found = try XCTUnwrap(DesktopProbeScript.probe(probeFails))
        XCTAssertEqual(found.desktop, "nologin")
        XCTAssertEqual(PluginManifest.targetFor(found.uname), "windows-arm64")
    }
}

/// `sh -s` is not there (cmd.exe): every script fails.
private final class LocalShellHostThatFails: DesktopHost {
    let base: LocalShellHost
    var runCommandHandler: ((String) -> (Int?, [String]))?
    init(_ base: LocalShellHost) { self.base = base }
    func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        onLine("'/bin/sh' is not recognized as an internal or external command,"); return 1
    }
    func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        let (s, lines) = runCommandHandler!(command); lines.forEach(onLine); return s
    }
    func upload(_ data: Data, to path: String) throws {}
    func openStream(_ command: String) -> DesktopStream? { nil }
    func disconnect() {}
}
