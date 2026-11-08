#if DEBUG
import Foundation
import UIKit
import AVFoundation
import RoamttyCore
import RoamttyTransport
import RoamttyDesktopCore

/// Opt-in, real SSH/plugin/VideoToolbox regression on a disposable graphical fixture.
@MainActor enum DesktopMemoryValidation {
    private static var started = false

    private final class Logins: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [SSHConnection] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
        func add(_ connection: SSHConnection) { lock.lock(); connections.append(connection); lock.unlock() }
        func interruptLatest() {
            lock.lock(); let connection = connections.last; lock.unlock()
            connection?.disconnect()
        }
        func close() {
            lock.lock(); let all = connections; connections.removeAll(); lock.unlock()
            all.forEach { $0.disconnect() }
        }
    }

    static func runIfRequested() async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--desktop-memory-validation") else { return }
        started = true
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopMemoryValidation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [String: Any] = ["kind": "real fixture SSH and VideoToolbox",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "status": "running", "startedAt": ISO8601DateFormatter().string(from: Date())]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        save() // A new run must not leave an old successful report visible while it is running.
        do { result.merge(try await run(folder: folder)) { _, new in new } } catch { result["passed"] = false; result["error"] = String(describing: error) }
        result["status"] = "finished"
        result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        save()
    }

    private static func run(folder: URL) async throws -> [String: Any] {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
            let address = ProcessInfo.processInfo.environment["ROAMTTY_TEST_HOST"] else {
            throw RoamError.invalid("Validation requires a window and explicit disposable fixture")
        }
        let logins = Logins()
        var config = DesktopSession.Config(hostName: "Disposable desktop fixture", address: address,
            clientWidth: 1280, clientHeight: 800, clientDpi: 160)
        config.audio = false
        let session = DesktopSession(config: config, manifest: try PluginManifest.bundled(), login: {
            do {
                let connection = try connectFixture()
                logins.add(connection)
                return .host(SSHDesktopHost(connection: connection))
            } catch { return .failed(message: "Disposable fixture login failed", connecting: false) }
        })
        let decoder = DesktopVideoDecoder(name: "VideoToolbox validation")
        let display = VideoToolboxDisplay()
        decoder.session = session; decoder.display = display; display.decoder = decoder; session.video = decoder
        let surface = UIView(frame: window.bounds)
        surface.backgroundColor = .black; surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        display.layer.frame = surface.bounds
        surface.layer.addSublayer(display.layer); window.addSubview(surface)
        defer {
            session.close(); decoder.close(); logins.close()
            display.layer.removeFromSuperlayer(); surface.removeFromSuperview()
        }
        decoder.attach(name: "VideoToolbox validation")
        session.start()
        let deadline = Date().addingTimeInterval(60)
        while decoder.decodedFrames < 10 && Date() < deadline {
            if case .failed = session.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard decoder.decodedFrames >= 10 else {
            return ["passed": false, "phase": String(describing: session.phase), "log": session.log,
                "decodedFrames": decoder.decodedFrames]
        }
        let baseline = Diagnostics.footprintMiB() ?? 0
        var footprints: [UInt64] = []
        let framesBefore = decoder.decodedFrames
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(500))
            footprints.append(Diagnostics.footprintMiB() ?? 0)
        }
        let streamingFrames = decoder.decodedFrames - framesBefore
        let image: UIImage? = await withCheckedContinuation { continuation in
            display.snapshot { continuation.resume(returning: $0) }
        }
        if let png = image?.pngData() { try png.write(to: folder.appendingPathComponent("decoded-frame.png"), options: .atomic) }
        let actuallyDisplayed: Bool
        if #available(iOS 17.4, *) {
            actuallyDisplayed = display.layer.sampleBufferRenderer.displayedPixelBuffer() != nil
        } else { actuallyDisplayed = image != nil }

        session.pause()
        try await Task.sleep(for: .milliseconds(300))
        let pausedAt = decoder.decodedFrames
        let loginsBeforeRecovery = logins.count
        logins.interruptLatest()
        let recoveryDeadline = Date().addingTimeInterval(15)
        while logins.count <= loginsBeforeRecovery && Date() < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        let pausedAfterRecovery = decoder.decodedFrames
        session.resume()
        let resumeDeadline = Date().addingTimeInterval(15)
        while decoder.decodedFrames < pausedAfterRecovery + 10 && Date() < resumeDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let resumed = decoder.decodedFrames >= pausedAfterRecovery + 10
        return ["passed": actuallyDisplayed && image != nil && streamingFrames > 10
                && pausedAt == pausedAfterRecovery && logins.count > loginsBeforeRecovery && resumed,
            "actuallyDisplayedPixelBuffer": actuallyDisplayed, "snapshotPixels": [image?.cgImage?.width ?? 0, image?.cgImage?.height ?? 0],
            "streamingSeconds": 15, "streamingFrames": streamingFrames,
            "baselineFootprintMiB": baseline, "footprintSamplesMiB": footprints,
            "peakFootprintMiB": footprints.max() ?? baseline,
            "pausedFramesBeforeRecovery": pausedAt, "pausedFramesAfterRecovery": pausedAfterRecovery,
            "loginCount": logins.count, "resumedFrames": decoder.decodedFrames - pausedAfterRecovery,
            "udpActive": session.onUdp, "phase": String(describing: session.phase)]
    }

    nonisolated private static func connectFixture() throws -> SSHConnection {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["ROAMTTY_TEST_HOST"], let user = env["ROAMTTY_TEST_USERNAME"],
              let password = env["ROAMTTY_TEST_PASSWORD"], let fingerprint = env["ROAMTTY_TEST_FINGERPRINT"] else {
            throw RoamError.invalid("Explicit disposable fixture missing")
        }
        let target = Host(name: "Disposable desktop fixture", address: host,
            port: Int(env["ROAMTTY_TEST_PORT"] ?? "22") ?? 22, username: user, auth: .password)
        let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: target, credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
            if case .verifyHost(let pin) = prompt { return pin.fingerprint == fingerprint ? ["verified"] : nil }
            return nil
        }
        try connection.connect()
        return connection
    }
}
#endif
