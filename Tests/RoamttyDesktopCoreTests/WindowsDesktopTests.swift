import XCTest
@testable import RoamttyDesktopCore

/// Android `WindowsDesktopTest`, plus the PowerShell encoding itself.
final class WindowsDesktopTests: XCTestCase {
    private func decode(_ command: String) -> String {
        let b64 = command.components(separatedBy: "-EncodedCommand ").last!
        let bytes = [UInt8](Data(base64Encoded: b64)!)
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    func testScriptsFitCmdExe() {
        // cmd.exe caps a command line at 8191 characters.
        let scripts = [WindowsDesktop.probeCommand,
                       PowerShell.command(WindowsDesktop.hostDownloadScript(url: "https://github.com/yahaa/roamtty-desktop/releases/download/v1.2.3/windows-x64.exe", sha: String(repeating: "a", count: 64))),
                       PowerShell.command(WindowsDesktop.installScript(uploaded: ".roamtty\\desktop\\openh264-x.bz2"))]
        for s in scripts { XCTAssertLessThan(s.count, 8000) }
    }

    func testProbeReportsTheSameMarkers() {
        let probe = decode(WindowsDesktop.probeCommand)
        XCTAssertTrue(probe.contains(DesktopProbeScript.DESKTOP) && probe.contains(DesktopProbeScript.UNAME) && probe.contains(DesktopProbeScript.DESKTOP_PLUGIN))
        XCTAssertTrue(probe.contains("Win32_ComputerSystem"))
        XCTAssertTrue(probe.contains(#"($u -split '\\')[-1]"#), probe)
        XCTAssertTrue(probe.contains(#"$p = "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe""#), probe)
        XCTAssertTrue(probe.contains("Get-Service RoamttyDesktop"))
        let out = "\(DesktopProbeScript.DESKTOP)yes\r\n\(DesktopProbeScript.UNAME)Windows AMD64\r\n\(DesktopProbeScript.DESKTOP_PLUGIN)roamtty-desktop 0.5.0 proto 1\r\n"
        XCTAssertEqual(DesktopProbeScript.parse(out), HostDesktop(desktop: "yes", uname: "Windows AMD64", pluginVersion: "roamtty-desktop 0.5.0 proto 1"))
    }

    func testDownloadChecksAndPlaces() {
        let sha = String(repeating: "ab", count: 32)
        let s = WindowsDesktop.hostDownloadScript(url: "https://x/it's.exe", sha: sha)
        XCTAssertTrue(s.contains("curl.exe -fsSL") && s.contains("'https://x/it''s.exe'"))
        XCTAssertTrue(s.contains("Get-FileHash") && s.contains("'\(sha)'") && s.contains(DesktopPluginInstaller.SHA_MISMATCH))
        XCTAssertTrue(s.contains("schtasks /End") && s.contains("Move-Item -Force"))
        XCTAssertTrue(s.contains(#"Move-Item -Force $f "$b\roamtty-desktop.exe""#), s)
        XCTAssertTrue(s.contains(#"$f = "$b\roamtty-desktop.part""#), s)
        XCTAssertTrue(DesktopPluginInstaller.Build(version: "1", url: "https://x/windows-x64.exe", sha256: "a", openh264Url: nil).windows)
    }

    func testServeGoesThroughCmd() {
        XCTAssertEqual(WindowsDesktop.serveCommand("--proto 1 --client 2400x1080@420"),
                       #"cmd /c ""%USERPROFILE%\.roamtty\bin\roamtty-desktop.exe" serve --proto 1 --client 2400x1080@420""#)
    }

    func testServiceInstallCommandIsWhatTheHintCopies() {
        XCTAssertEqual(WindowsDesktop.SERVICE_INSTALL, #"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install"#)
        XCTAssertEqual(WindowsDesktop.installScript(), #"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install; exit $LASTEXITCODE"#)
        XCTAssertEqual(WindowsDesktop.installScript(uploaded: #".roamtty\desktop\o.bz2"#),
                       #"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install --openh264 "$env:USERPROFILE\.roamtty\desktop\o.bz2"; exit $LASTEXITCODE"#)
    }

    func testPowerShellEncodesUtf16() {
        let c = PowerShell.command("'é'")
        XCTAssertTrue(c.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand "))
        XCTAssertEqual(decode(c), "'é'")
        XCTAssertTrue(PowerShell.command("x", interactive: true).contains("-NoExit"))
    }

    /// The Windows install path, against a host that answers like PowerShell would.
    func testWindowsInstallRunsThePowerShellSteps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".roamtty/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".roamtty/desktop"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let host = LocalShellHost(home: home)
        var scripts: [String] = []
        // Host download fails; the place script passes; the plugin's install needs the phone's encoder once.
        host.runCommandHandler = { command in
            let script = self.decode(command)
            scripts.append(script)
            if script.contains("curl.exe") { return (3, [DesktopPluginInstaller.FETCH_FAILED]) }
            if script.contains("--openh264") { return (0, ["openh264 ok"]) }
            if script.hasPrefix("& ") { return (3, ["fetch failed"]) }
            return (0, [])
        }
        let exe = Data("MZ fake".utf8)
        var steps: [DesktopPluginInstaller.Step] = []
        let installer = DesktopPluginInstaller(remote: host, fetch: { $0.hasSuffix(".exe") ? exe : Data("bz".utf8) }, onStep: { steps.append($0) })
        let result = installer.install(.init(version: "0.8.2", url: "https://x/windows-x64.exe", sha256: PluginManifest.sha256Hex(exe), openh264Url: "https://c/openh264-2.6.0-win64.dll.bz2"))
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(steps, [.hostDownload, .phoneDownload, .upload, .verify, .encoderHost, .encoderPhone, .register, .done])
        XCTAssertTrue(scripts.contains { $0.contains(#"$f = "$env:USERPROFILE\.roamtty\bin\roamtty-desktop-"#) && $0.contains("Get-FileHash") })
        XCTAssertTrue(scripts.contains { $0.contains(#"--openh264 "$env:USERPROFILE\.roamtty\desktop\openh264-"#) })
    }
}
