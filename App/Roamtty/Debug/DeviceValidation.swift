#if DEBUG
import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport

/// Explicitly requested, fixture-only transport diagnostics. This is not XCTest UI automation.
enum DeviceValidation {
    @MainActor private static var started = false

    @MainActor static func runIfRequested(model: AppModel) async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--device-validation"),
              let fixture = DeviceFixture(environment: ProcessInfo.processInfo.environment) else { return }
        started = true
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("Validation", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runner = try DeviceValidationRunner(fixture: fixture, folder: folder)
            let active = await waitUntilActive()
            runner.check("app_foreground") {
                guard active else { throw DeviceFailure("App remained inactive for 15 seconds; check pending system permission prompts") }
                return ["activeBeforeNetworkChecks": "true"]
            }
            guard active else { runner.finish(); return }
            try await performInBackground { runner.run() }
            // The app's own reachability probe: online only once the fixture's sshd greets it.
            let online = await ReachabilityProbe.measure(address: fixture.address, port: fixture.port)
            let closed = await ReachabilityProbe.measure(address: fixture.address, port: 9)
            runner.check("ssh_greeting_reachability") {
                guard case .online(let latency) = online else { throw DeviceFailure("The fixture's sshd did not answer the probe") }
                if case .online = closed { throw DeviceFailure("A port without sshd counted as online") }
                return ["sshdOnline": "true", "latencyRecorded": latency >= 0 ? "true" : "false", "closedPortOffline": "true"]
            }

            // Navigate the real app using an in-memory fixture host. Nothing is added
            // to the user's host database, keychain or persistent trust store.
            let host = fixture.host(auth: .password)
            let previousPath = model.path
            model.hosts.append(host)
            if let metrics = runner.displayMetrics { model.metrics[host.id] = metrics }
            model.path = []; model.homeTab = .sessions
            _ = await waitUntilActive()
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("home_sessions_snapshot") { try snapshot(model, folder: folder, name: "home-sessions.png", screen: "HomeSessionsTab") }
            model.homeTab = .hosts
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("home_hosts_snapshot") { try snapshot(model, folder: folder, name: "home-hosts.png", screen: "HomeHostsTab") }
            model.path = [.host(host.id)]
            _ = await waitUntilActive()
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("app_window_snapshot") {
                guard model.authentication == nil, model.sheet == nil, model.error == nil,
                      !model.drawer, UIApplication.shared.applicationState == .active,
                      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .flatMap(\.windows).first(where: { $0.isKeyWindow }),
                      window.bounds.width > 0, window.bounds.height > 0 else { throw DeviceFailure("App window unavailable") }
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                var rendered = false
                let png = renderer.pngData { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                guard rendered else { throw DeviceFailure("App window rendering failed") }
                try png.write(to: folder.appendingPathComponent("host-detail.png"), options: .atomic)
                return ["artifact": "host-detail.png", "screen": "HostDetailScreen", "method": "App-owned window capture; no automated tap or accessibility assertions"]
            }
            model.stopMonitor(host.id)
            model.path = previousPath
            model.hosts.removeAll { $0.id == host.id }
            model.metrics.removeValue(forKey: host.id)
            model.reachability.removeValue(forKey: host.id)
            runner.finish()
        } catch {
            // No environment values, credentials, SSH output or remote file contents
            // are logged. The report is the only diagnostic output.
        }
    }

    @MainActor private static func snapshot(_ model: AppModel, folder: URL, name: String, screen: String) throws -> [String: String] {
        guard model.authentication == nil, model.sheet == nil, model.error == nil, !model.drawer, UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: { $0.isKeyWindow }),
              window.bounds.width > 0, window.bounds.height > 0 else { throw DeviceFailure("App window unavailable") }
        var rendered = false
        let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard rendered else { throw DeviceFailure("App window rendering failed") }
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        return ["artifact": name, "screen": screen, "method": "App-owned window capture"]
    }
    @MainActor private static func waitUntilActive() async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while UIApplication.shared.applicationState != .active {
            guard Date() < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return true
    }
}

private struct DeviceFixture {
    let address: String
    let port: Int
    let username: String
    let password: String
    let fingerprint: String
    let id = "device-validation-" + UUID().uuidString

    init?(environment: [String: String]) {
        guard let address = environment["ROAMTTY_TEST_HOST"], !address.isEmpty,
              let username = environment["ROAMTTY_TEST_USERNAME"], !username.isEmpty,
              let password = environment["ROAMTTY_TEST_PASSWORD"], !password.isEmpty,
              let fingerprint = environment["ROAMTTY_TEST_FINGERPRINT"], fingerprint.hasPrefix("SHA256:"),
              fingerprint.count == 50,
              let port = Int(environment["ROAMTTY_TEST_PORT"] ?? "22"), (1...65535).contains(port) else { return nil }
        self.address = address; self.port = port; self.username = username
        self.password = password; self.fingerprint = fingerprint
    }

    func host(auth: AuthMethod) -> RoamttyCore.Host {
        RoamttyCore.Host(id: id, name: "Device validation fixture", address: address, port: port, username: username, auth: auth, mode: .shell)
    }

    func connect(auth: AuthMethod = .password) throws -> SSHConnection {
        let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host(auth: auth), credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
            switch prompt {
            case .verifyHost(let received): return received.fingerprint == fingerprint ? ["verified fixture fingerprint"] : nil
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        let timeout = DispatchWorkItem { connection.disconnect() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer { timeout.cancel() }
        do { try connection.connect(); return connection } catch { connection.disconnect(); throw error }
    }
}

private struct DeviceFailure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private struct DeviceCheck: Encodable {
    let name: String
    let status: String
    let elapsedMilliseconds: Int
    let evidence: [String: String]
}
private struct DeviceReport: Encodable {
    let schema = 1
    let kind = "functional-diagnostic"
    let xctestUIAutomation = false
    let startedAt: String
    var finishedAt: String?
    var status = "running"
    var checks: [DeviceCheck] = []
}

private final class DeviceValidationRunner {
    let fixture: DeviceFixture
    let folder: URL
    private var report: DeviceReport
    private(set) var displayMetrics: HostMetrics?

    init(fixture: DeviceFixture, folder: URL) throws {
        self.fixture = fixture; self.folder = folder
        report = DeviceReport(startedAt: ISO8601DateFormatter().string(from: Date()))
        try save()
    }

    func check(_ name: String, _ operation: () throws -> [String: String]) {
        let start = Date()
        do {
            let evidence = try operation()
            report.checks.append(DeviceCheck(name: name, status: "passed", elapsedMilliseconds: Int(Date().timeIntervalSince(start) * 1000), evidence: evidence))
        } catch {
            report.checks.append(DeviceCheck(name: name, status: "failed", elapsedMilliseconds: Int(Date().timeIntervalSince(start) * 1000), evidence: ["reason": Self.safeReason(error)]))
        }
        try? save()
    }

    func finish() {
        report.finishedAt = ISO8601DateFormatter().string(from: Date())
        report.status = report.checks.allSatisfy { $0.status == "passed" } ? "passed" : "failed"
        try? save()
    }

    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func safeReason(_ error: Error) -> String {
        if let failure = error as? DeviceFailure { return failure.reason }
        guard let failure = error as? RoamError else { return "Local operation failed" }
        switch failure {
        case .authentication: return "Authentication failed"
        case .cancelled: return "Operation cancelled or watchdog expired"
        case .timeout: return "Transport timed out"
        case .hostKeyChanged, .rejected: return "Fixture fingerprint verification failed"
        case .tmuxMissing: return "Fixture tmux unavailable"
        case .transport(let message):
            let safeMessages = ["无法连接主机 / Cannot reach host", "SSH allocation failed", "Missing host key", "Network wait failed", "SSH connection is not authenticated"]
            if safeMessages.contains(message) { return message }
            if message.range(of: #"^SSH operation failed \(-?[0-9]+\)$"#, options: .regularExpression) != nil { return message }
            return "Transport operation failed"
        default: return "Transport or validation operation failed"
        }
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try condition() else { throw DeviceFailure(reason) }
    }

    func run() {
        check("keychain_share_inbox_roundtrip") {
            ["result": try ShareInboxStore.runDeviceSelfTest()]
        }
        var client: SSHConnection?
        check("password_authentication_and_exec") {
            let ssh = try fixture.connect(); client = ssh
            let result = try ssh.exec("printf 'DEVICE-%s' SSH", timeout: 8)
            try require(result.status == 0 && result.output == Data("DEVICE-SSH".utf8), "SSH command result mismatch")
            return ["hostTrust": "Exact configured SHA256 fingerprint; isolated memory pin store", "stdoutMatched": "true", "exitStatus": "0"]
        }
        defer { client?.disconnect() }
        check("keyboard_interactive_authentication") {
            let ssh = try fixture.connect(auth: .interactive); defer { ssh.disconnect() }
            let result = try ssh.exec("printf 'INTERACTIVE-%d' 42", timeout: 8)
            try require(result.status == 0 && result.output == Data("INTERACTIVE-42".utf8), "Interactive command result mismatch")
            return ["stdoutMatched": "true", "exitStatus": "0"]
        }
        check("remote_metrics") {
            guard let ssh = client else { throw DeviceFailure("Password connection unavailable") }
            let result = try ssh.exec(RemoteCommands.shell(HostMetrics.script), timeout: 10)
            let metrics = HostMetrics.parse(result.text)
            try require(result.status == 0 && (metrics.cpus ?? 0) > 0 && (metrics.memTotalBytes ?? 0) > 0, "Metrics response was incomplete")
            // Only numeric system readings enter the screenshot. Process names,
            // remote paths, hostname, user lists and raw output are discarded.
            var display = HostMetrics()
            display.cpus = metrics.cpus; display.cpuPercent = metrics.cpuPercent
            display.memTotalBytes = metrics.memTotalBytes; display.memAvailableBytes = metrics.memAvailableBytes
            display.load = metrics.load; displayMetrics = display
            return ["cpuCountPresent": "true", "memoryTotalPresent": "true", "rawRemoteOutputStored": "false"]
        }
        check("ssh_pty_input_and_resize") {
            try terminal(mode: .shell, name: "") { ssh, output in
                try require(ssh.write(Data("stty -echo; printf 'DEVICE-PTY-%d\\n' $((6*7))\r".utf8)), "PTY input was rejected")
                try output.expect("DEVICE-PTY-42", timeout: 8)
                ssh.resize(columns: 101, rows: 39)
                try require(ssh.write(Data("stty size\r".utf8)), "PTY resize command was rejected")
                try output.expect("39 101", timeout: 8)
            }
            return ["evaluatedOutputMatched": "true", "columns": "101", "rows": "39"]
        }
        if let client {
            sftp(client)
            tmux(client)
            mosh(client)
            agentHooks(client)
        } else {
            for name in ["sftp_binary_roundtrip", "tmux_isolation_and_reattach", "mosh_udp_roundtrip", "agent_hooks_status_restart_kill"] {
                check(name) { throw DeviceFailure("Password connection unavailable") }
            }
        }
    }

    /// What starting an agent writes on the host, the status poll, the pane restart and closing, as the app runs them.
    private func agentHooks(_ ssh: SSHConnection) {
        check("agent_hooks_status_restart_kill") {
            func sh(_ script: String) throws -> (Int32, String) {
                let result = try ssh.exec(RemoteCommands.stdinShell, input: Data((RemoteCommands.pathSetup + "\n" + script).utf8), timeout: 15)
                return (result.status, result.text)
            }
            try require(try sh("command -v tmux").0 == 0, "Fixture tmux unavailable")
            let name = "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            defer { _ = try? sh(RemoteCommands.killTmux(name)) }
            for (file, content, executable) in [(AgentHooks.scriptName, AgentHooks.script, false), (AgentHooks.hostFile(.claude).name, AgentHooks.hostFile(.claude).content, false)] {
                guard let command = RemoteCommands.writeHostFile(file, executable: executable) else { throw DeviceFailure("Invalid hook file name") }
                try require(try ssh.exec(command, input: Data(content.utf8), timeout: 10).status == 0, "Writing \(file) failed")
            }
            try require(try sh("cd /tmp && tmux new-session -d -s \(name) -x 80 -y 24 && tmux send-keys -t \(name) 'sleep 600' Enter && sleep 1").0 == 0, "tmux session did not start")
            let pane = try sh("tmux display-message -p -t \(name) '#{pane_id}'").1.trimmingCharacters(in: .whitespacesAndNewlines)
            for (event, json) in [("prompt", #"{"prompt":"device check"}"#), ("tool", #"{"tool_name":"Bash","tool_input":{"command":"make test"}}"#)] {
                try require(try sh("printf '%s' '\(json)' | TMUX_PANE='\(pane)' sh \"$HOME/.roamtty/agent-hook.sh\" claude \(event)").0 == 0, "Hook \(event) failed")
            }
            let poll = try ssh.exec(RemoteCommands.agentStatus(name), input: Data(), timeout: 10).text
            guard let status = AgentStatus.parse(poll) else { throw DeviceFailure("No agent status reported") }
            try require(status.state == .working && status.task == "device check" && agentActivity(status) == "Running make test", "Agent status mismatch")
            let restart = try ssh.exec(RemoteCommands.restartPane(name), input: Data(), timeout: 10)
            try require(restart.status == 0 && restart.trimmedText == "sleep 600", "Pane restart did not report its program")
            try require(try sh(RemoteCommands.killTmux(name)).0 == 0 && (try sh("tmux has-session -t =\(name) 2>/dev/null").0) != 0, "tmux session was not ended")
            return ["hooksInstalled": "true", "statusWorking": "true", "restartReportedProgram": "true", "sessionEnded": "true"]
        }
    }

    private func terminal(mode: SessionMode, name: String, body: (SSHConnection, DeviceOutput) throws -> Void) throws {
        let ssh = try fixture.connect()
        let output = DeviceOutput()
        let done = DispatchSemaphore(value: 0)
        defer { ssh.disconnect(); _ = done.wait(timeout: .now() + 2) }
        try ssh.openTerminal(mode: mode, remoteName: name, columns: 80, rows: 24)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try ssh.runTerminal { output.append($0) } } catch { output.finish(error) }
        }
        try output.expectAny(timeout: 8)
        if mode == .tmux { try waitForTmuxClient(ssh, name: name) }
        try body(ssh, output)
    }

    private func waitForTmuxClient(_ ssh: SSHConnection, name: String) throws {
        let command = RemoteCommands.pathSetup + "; tmux list-clients -t " + RemoteCommands.shellQuote("=" + name) + " -F '#{client_tty}'"
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let result = try ssh.exec(command, timeout: 2)
            if result.status == 0 && !result.output.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DeviceFailure("Owned tmux client did not attach")
    }

    private func sftp(_ ssh: SSHConnection) {
        let remote = "/tmp/roamtty-device-" + UUID().uuidString
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-device-" + UUID().uuidString)
        var created = false
        defer {
            try? FileManager.default.removeItem(at: local)
            if created {
                check("sftp_fixture_cleanup") {
                    let result = try ssh.exec("rm -rf -- " + RemoteCommands.shellQuote(remote), timeout: 8)
                    try require(result.status == 0, "Fixture directory cleanup failed")
                    return ["removedOwnedUUIDDirectory": "true"]
                }
            }
        }
        check("sftp_binary_roundtrip_truncation_and_no_overwrite") {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let result = try ssh.exec("mkdir -m 700 -- " + RemoteCommands.shellQuote(remote), timeout: 8)
            try require(result.status == 0, "Fixture directory creation failed"); created = true
            let bytes = Data((0..<250_000).map { UInt8($0 % 251) })
            let source = local.appendingPathComponent("source.bin")
            try bytes.write(to: source)
            let path = remote + "/中文 ' * ? \\ fixture.bin"
            try ssh.upload(source, to: path) { _, _ in }
            var refusedOverwrite = false
            do { try ssh.upload(source, to: path) { _, _ in } } catch { refusedOverwrite = true }
            try require(refusedOverwrite, "SFTP replaced an existing destination")
            let downloaded = local.appendingPathComponent("download.bin")
            try ssh.download(path, to: downloaded) { _, _ in }
            let actual = try Data(contentsOf: downloaded)
            try require(actual == bytes, "SFTP binary roundtrip mismatch")
            let preview = try ssh.readFile(path, maxBytes: 37)
            try require(preview.truncated && preview.data == bytes.prefix(37), "SFTP preview truncation mismatch")
            try require(try ssh.listDirectory(remote).entries.count == 1, "SFTP left an unexpected partial file")
            return ["bytesCompared": "250000", "literalFilenameRoundtrip": "true", "truncatedPreviewBytes": "37", "existingDestinationPreserved": "true"]
        }
        check("sftp_cancel_cleanup_and_connection_reuse") {
            try require(created, "SFTP fixture directory unavailable")
            let source = local.appendingPathComponent("source.bin")
            let uploadToken = TransferCancellation()
            var uploadCancelled = false
            do {
                try ssh.upload(source, to: remote + "/cancelled.bin", progress: { count, _ in if count > 0 { uploadToken.cancel() } }, cancellation: uploadToken)
            } catch RoamError.cancelled { uploadCancelled = true }
            try require(uploadCancelled, "Upload cancellation was not observed")
            let listing = try ssh.listDirectory(remote)
            try require(listing.entries.count == 1 && !listing.entries.contains(where: { $0.name.contains(".part") || $0.name == "cancelled.bin" }), "Cancelled upload left a remote partial")
            let destination = local.appendingPathComponent("cancelled-download.bin")
            let downloadToken = TransferCancellation()
            var downloadCancelled = false
            do {
                try ssh.download(remote + "/中文 ' * ? \\ fixture.bin", to: destination, progress: { count, _ in if count > 0 { downloadToken.cancel() } }, cancellation: downloadToken)
            } catch RoamError.cancelled { downloadCancelled = true }
            try require(downloadCancelled && !FileManager.default.fileExists(atPath: destination.path), "Cancelled download left a local partial")
            let probe = try ssh.exec("printf connected", timeout: 8)
            try require(probe.output == Data("connected".utf8), "Cancellation invalidated the SSH connection")
            return ["uploadCancelled": "true", "remotePartialRemoved": "true", "downloadCancelled": "true", "localPartialRemoved": "true", "sshStillUsable": "true"]
        }
    }

    private func tmux(_ ssh: SSHConnection) {
        let prefix = "roamtty-device-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let names = (1...8).map { prefix + "-\($0)" }
        var created: [String] = []
        defer {
            check("tmux_fixture_cleanup") {
                for name in created {
                    let result = try ssh.exec(RemoteCommands.killTmux(name), timeout: 8)
                    try require(result.status == 0, "Owned tmux session cleanup failed")
                }
                return ["ownedSessionsRemoved": String(created.count)]
            }
        }
        check("tmux_eight_independent_sessions_and_reattach") {
            try require(try ssh.exec(RemoteCommands.tmuxProbe, timeout: 8).status == 0, "Fixture tmux is unavailable")
            var ids = Set<String>()
            for name in names {
                let create = try ssh.exec(RemoteCommands.pathSetup + "; tmux new-session -d -s " + RemoteCommands.shellQuote(name), timeout: 8)
                try require(create.status == 0, "Owned tmux session creation failed"); created.append(name)
                let identity = try ssh.exec("tmux display-message -p -t " + RemoteCommands.shellQuote("=" + name + ":") + " '#{session_id}'", timeout: 8)
                try require(identity.status == 0, "tmux identity query failed")
                ids.insert(identity.trimmedText)
            }
            try require(ids.count == 8, "tmux session identities were not independent")
            try terminal(mode: .tmux, name: names[0]) { channel, output in
                try require(channel.write(Data("export ROAMTTY_DEVICE_TOKEN=42; printf 'TMUX-CREATED-%s\\n' \"$ROAMTTY_DEVICE_TOKEN\"\r".utf8)), "tmux input rejected")
                try output.expect("TMUX-CREATED-42", timeout: 8)
            }
            try terminal(mode: .tmux, name: names[0]) { channel, output in
                try require(channel.write(Data("printf 'TMUX-REATTACHED-%s\\n' \"$ROAMTTY_DEVICE_TOKEN\"\r".utf8)), "tmux reattach input rejected")
                try output.expect("TMUX-REATTACHED-42", timeout: 8)
            }
            return ["distinctRemoteSessionIDs": "8", "persistentShellVariableAfterReconnect": "42"]
        }
    }

    private func mosh(_ ssh: SSHConnection) {
        let name = "roamtty-device-mosh-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sizeFile = "/tmp/" + name + ".size"
        defer {
            check("mosh_fixture_cleanup") {
                let cleanup = "rm -f -- " + RemoteCommands.shellQuote(sizeFile) + "; " + RemoteCommands.killTmux(name)
                let result = try ssh.exec(cleanup, timeout: 8)
                try require(result.status == 0, "Owned mosh fixture cleanup failed")
                return ["ownedSessionAndSizeFileRemoved": "true"]
            }
        }
        check("mosh_udp_input_resize_and_roaming_probe") {
            let transport = try ssh.startMosh(mode: .tmux, remoteName: name)
            let output = DeviceOutput()
            let done = DispatchSemaphore(value: 0)
            defer { transport.close(); _ = done.wait(timeout: .now() + 2) }
            DispatchQueue.global().async {
                defer { done.signal() }
                do { try transport.run(columns: 80, rows: 24, firstContactTimeout: 8, silenceTimeout: 12, stallTimeout: 5) { output.append($0) } } catch { output.finish(error) }
            }
            try output.expectAny(timeout: 10)
            try waitForTmuxClient(ssh, name: name)
            try require(transport.write(Data("stty -echo; printf 'DEVICE-MOSH-%d\\n' $((40+2))\r".utf8)), "mosh input rejected")
            try output.expect("DEVICE-MOSH-42", timeout: 8)
            transport.resize(columns: 91, rows: 33); transport.probe()
            // tmux updates its layout before resizing the pane's underlying PTY.
            // Wait for the kernel dimensions, not merely tmux's layout metadata.
            let sizeCommand = RemoteCommands.pathSetup + "; pane=$(tmux display-message -p -t " + RemoteCommands.shellQuote("=" + name + ":")
                + " '#{pane_tty}'); stty -F \"$pane\" size 2>/dev/null || stty -f \"$pane\" size 2>/dev/null"
            let resizeDeadline = Date().addingTimeInterval(8)
            var resized = false
            while Date() < resizeDeadline {
                let size = try ssh.exec(sizeCommand, timeout: 2)
                if size.trimmedText == "33 91" { resized = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try require(resized, "mosh tmux pane resize timed out")
            // Mosh emits screen diffs, which may split visible text with cursor
            // controls. Verify the command's numeric result through its own
            // UUID fixture file instead of mistaking raw diffs for plain text.
            try require(transport.write(Data(("stty size > " + RemoteCommands.shellQuote(sizeFile) + "\r").utf8)), "mosh resize command rejected")
            let resultDeadline = Date().addingTimeInterval(8)
            var sizeMatched = false
            while Date() < resultDeadline {
                let result = try ssh.exec("cat -- " + RemoteCommands.shellQuote(sizeFile) + " 2>/dev/null", timeout: 2)
                if result.status == 0 && result.trimmedText == "33 91" { sizeMatched = true; break }
                try output.throwIfFailed()
                Thread.sleep(forTimeInterval: 0.05)
            }
            try require(sizeMatched, "mosh shell resize result timed out")
            try require(transport.write(Data("exit\r".utf8)), "mosh exit input rejected")
            try require(done.wait(timeout: .now() + 8) == .success, "mosh remote shutdown timed out")
            done.signal() // Leave the completion signal available for the cleanup defer.
            try output.throwIfFailed()
            return ["bootstrap": "SSH startMosh", "authenticatedUDPOutput": "true", "evaluatedOutputMatched": "true", "columns": "91", "rows": "33",
                "sourcePortProbe": "true", "remoteShutdown": "true"]
        }
    }
}

private final class DeviceOutput {
    private let condition = NSCondition()
    private var bytes = Data()
    private var failure: Error?
    func append(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        bytes.append(data)
        if bytes.count > 512 * 1024 { bytes.removeFirst(bytes.count - 512 * 1024) }
        condition.broadcast()
    }
    func finish(_ error: Error) { condition.lock(); failure = error; condition.broadcast(); condition.unlock() }
    func throwIfFailed() throws { condition.lock(); defer { condition.unlock() }; if let failure { throw failure } }
    func expect(_ value: String, timeout: TimeInterval) throws { try wait(timeout: timeout, label: value) { String(decoding: $0, as: UTF8.self).contains(value) } }
    func expectAny(timeout: TimeInterval) throws { try wait(timeout: timeout, label: "initial terminal state") { !$0.isEmpty } }
    private func wait(timeout: TimeInterval, label: String, matches: (Data) -> Bool) throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !matches(bytes) {
            if let failure { throw failure }
            guard condition.wait(until: deadline) else { throw DeviceFailure("Expected fixture output timed out: " + label) }
        }
    }
}
#endif
