import XCTest
import RoamttyCore
import CNative
@testable import RoamttyTransport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class SSHExecTests: XCTestCase {
    private func connection() throws -> SSHConnection {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Live SSH fixture not configured") }
        let password = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = AuthMethod(rawValue: environment["ROAMTTY_TEST_AUTH"] ?? "password") ?? .password
        let host = RoamttyCore.Host(name: "Exec fixture", address: environment["ROAMTTY_TEST_HOST"] ?? "127.0.0.1",
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

    func testScriptStdinStreamsBothOutputsWithoutPuttingInputInArguments() throws {
        let client = try connection(); defer { client.disconnect() }
        let marker = "stdin-only-" + UUID().uuidString
        let script = """
        value='\(marker)'
        case "$(tr '\\000' ' ' < /proc/$$/cmdline)" in *"$value"*) exit 91;; esac
        printf 'stdout-%s\\n' "$((40+2))"
        printf 'stderr-OK\\n' >&2
        exit 7
        """
        var streamed = Data()
        let result = try client.exec("/bin/sh -s", input: Data(script.utf8), timeout: 5, onOutput: { streamed.append($0) })
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(streamed, result.output)
        let text = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(text.contains("stdout-42")); XCTAssertTrue(text.contains("stderr-OK"))
        XCTAssertFalse(text.contains(marker))
    }

    func testLargeBidirectionalInputDrainsOutputBeforeTheRemoteWindowFills() throws {
        let client = try connection(); defer { client.disconnect() }
        let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        var streamedBytes = 0; var chunks = 0
        let result = try client.exec("cat", input: bytes, timeout: 12, onOutput: { streamedBytes += $0.count; chunks += 1 })
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, bytes)
        XCTAssertEqual(streamedBytes, bytes.count)
        XCTAssertGreaterThan(chunks, 1)
        let empty = try client.exec("wc -c", input: Data(), timeout: 3)
        XCTAssertEqual(String(decoding: empty.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }

    func testStreamingCancellationDoesNotCancelOtherChannels() throws {
        let client = try connection(); defer { client.disconnect() }
        let cancellation = TransferCancellation()
        var sawOutput = false
        XCTAssertThrowsError(try client.exec("cat", input: Data(repeating: 37, count: 3 * 1024 * 1024), timeout: 10, cancellation: cancellation, onOutput: { _ in
            sawOutput = true; cancellation.cancel()
        })) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertTrue(sawOutput)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("printf reusable").output, Data("reusable".utf8))
        XCTAssertThrowsError(try client.exec("printf must-not-run", input: Data(), cancellation: cancellation)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
    }

    func testStdinAndOutputLimitsFailWithoutPoisoningConnection() throws {
        let client = try connection(); defer { client.disconnect() }
        XCTAssertThrowsError(try client.exec("cat", input: Data(repeating: 0, count: 8 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try client.exec("head -c 8388609 /dev/zero", input: Data(), timeout: 8))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("printf bounded").output, Data("bounded".utf8))
    }

    func testExitStatusCanArriveAfterOutputEOF() throws {
        let client = try connection(); defer { client.disconnect() }
        let script = "printf completed-output; exec 1>&- 2>&-; sleep 2.5; exit 7\n"
        let result = try client.exec("/bin/sh -s", input: Data(script.utf8), timeout: 5)
        XCTAssertEqual(result.output, Data("completed-output".utf8))
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(client.isConnected)
    }

    func testCancellationTerminatesRemoteShellAndChildBeforeReusingConnection() throws {
        try assertRemoteTermination(timeout: false)
    }

    func testTimeoutTerminatesRemoteShellAndChildBeforeReusingConnection() throws {
        try assertRemoteTermination(timeout: true)
    }

    func testCancellationEscalatesOnlyItsChannelWhenCommandIgnoresTERM() throws {
        try assertRemoteTermination(timeout: false, ignoringTerm: true)
    }

    func testCancellationCompletesPendingTERMBeforeSendingDistinctKILL() throws {
        try assertRemoteTermination(timeout: false, ignoringTerm: true, sendBackpressure: 0.8)
    }

    func testUnrecoverablePendingSignalInvalidatesConnectionWithinBudget() throws {
        let client = try connection(); defer { client.disconnect() }
        let control = try connection(); defer { control.disconnect() }
        let token = TransferCancellation(), gate = ExecSendBackpressure(until: .distantFuture)
        var output = "", restore: (() -> Void)?
        defer { restore?() }
        let started = Date()
        XCTAssertThrowsError(try client.exec("/bin/sh -s", input: Data("printf 'OWNED-PID=%s\\nREADY\\n' \"$$\"; exec sleep 60\n".utf8), timeout: 10, cancellation: token, onOutput: { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            if restore == nil, output.contains("\nREADY\n") { restore = self.blockSends(client, using: gate); token.cancel() }
        })) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        restore?(); restore = nil
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertGreaterThan(gate.blockedSends, 1)
        XCTAssertFalse(client.isConnected, "A pending libssh2 packet must not remain in the shared connection pool")
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("OWNED-PID=") })
        let pid = try XCTUnwrap(Int(line.dropFirst("OWNED-PID=".count)))
        _ = try control.exec("kill -KILL " + String(pid) + " 2>/dev/null || true")
        XCTAssertEqual(try control.exec("printf independent-connection-alive").output, Data("independent-connection-alive".utf8))
    }

    func testSudoCancellationTerminatesDirectPrivilegedCommand() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_SUDO_FIXTURE"] == "1" else { throw XCTSkip("Requires an isolated password-sudo fixture") }
        // sudo forwards SSH's TERM to its direct command. An arbitrary root
        // shell can orphan root grandchildren; this does not claim to kill
        // those. The next test verifies the real installer's full apt tree.
        try assertRemoteTermination(timeout: false, sudo: true)
    }

    func testSudoInstallerCancellationStopsAptDownload() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_SUDO_FIXTURE"] == "1" else { throw XCTSkip("Requires an isolated Debian password-sudo fixture without tmux") }
        let client = try connection(); defer { client.disconnect() }
        XCTAssertNotEqual(try client.exec("command -v tmux").status, 0)
        let release = "/tmp/roamtty-exec-survivor-" + UUID().uuidString
        let concurrentReady = expectation(description: "Another exec is active on the same SSH connection")
        let concurrentDone = expectation(description: "The other exec survives installer cancellation")
        DispatchQueue.global().async {
            do {
                var output = "", ready = false
                let script = "printf 'CONCURRENT-READY\\n'; while [ ! -f " + self.quote(release) + " ]; do sleep 0.03; done; printf 'CONCURRENT-SURVIVED\\n'\n"
                let result = try client.exec("/bin/sh -s", input: Data(script.utf8), timeout: 15, onOutput: { bytes in
                    output += String(decoding: bytes, as: UTF8.self)
                    if !ready, output.contains("CONCURRENT-READY") { ready = true; concurrentReady.fulfill() }
                })
                XCTAssertEqual(result.status, 0)
                XCTAssertTrue(output.contains("CONCURRENT-SURVIVED"), "Cancelling the installer must not signal this other channel")
            } catch { XCTFail("Concurrent exec failed: \(error)") }
            concurrentDone.fulfill()
        }
        defer {
            _ = try? client.exec("touch " + quote(release), timeout: 3)
            wait(for: [concurrentDone], timeout: 5)
            _ = try? client.exec("rm -f -- " + quote(release), timeout: 3)
        }
        wait(for: [concurrentReady], timeout: 5)
        let password = try String(contentsOfFile: XCTUnwrap(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"]), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = TransferCancellation()
        var streamed = "", downloading = false
        let script = HostPluginInstaller.script(plugin: .tmux, sudoPassword: password)
        XCTAssertThrowsError(try client.exec("/bin/sh -s", input: Data(script.utf8), timeout: 20, cancellation: token, onOutput: { bytes in
            streamed += String(decoding: bytes, as: UTF8.self)
            if streamed.contains("Get:") { downloading = true; token.cancel() }
        })) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertTrue(downloading, "A real apt download must start before cancellation")
        let scan = "for f in /proc/[0-9]*/comm; do IFS= read -r c < \"$f\" 2>/dev/null || continue; case \"$c\" in apt-get|http|https) printf '%s\\n' \"$c\";; esac; done"
        var live = Data()
        let deadline = Date().addingTimeInterval(3)
        repeat {
            live = try client.exec(scan, timeout: 2).output
            if live.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < deadline
        XCTAssertTrue(live.isEmpty, "apt-get and its download workers must be absent after cancellation")
        XCTAssertNotEqual(try client.exec("command -v tmux").status, 0)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("printf cached-connection-reusable").output, Data("cached-connection-reusable".utf8))
    }

    func testCancellingSFTPRequestDuringSendBackpressureKeepsConnectionUsable() throws {
        let client = try connection(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote, timeout: 3) }
        let token = TransferCancellation()
        // Channel open, subsystem request and SFTP init go first; the mkdir request is the fourth send.
        let gate = ExecSendBackpressure(until: .distantFuture, skipping: 3, window: 0.2) { token.cancel() }
        let restore = blockSends(client, using: gate)
        let started = Date()
        do { try client.createDirectory(remote + "/created", cancellation: token) } catch { XCTAssertEqual(error as? RoamError, .cancelled) }
        restore()
        XCTAssertGreaterThan(gate.blockedSends, 0, "The SFTP request must meet EAGAIN")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // A request left half-sent would hold libssh2's send slot and time this out after 20 s.
        XCTAssertTrue(client.isConnected)
        let reuse = Date()
        XCTAssertEqual(try client.exec("printf reusable", timeout: 3).output, Data("reusable".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(reuse), 3)
    }

    func testResizeDuringSendBackpressureEndsAtTheLastSize() throws {
        let client = try connection(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let lock = NSLock(); var output = ""
        func text() -> String { lock.lock(); defer { lock.unlock() }; return output }
        func waitFor(_ marker: String, timeout: TimeInterval = 8) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if text().contains(marker) { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return false
        }
        let finished = expectation(description: "terminal worker ends")
        DispatchQueue.global().async {
            try? client.runTerminal { data in lock.lock(); output += String(decoding: data, as: UTF8.self); lock.unlock() }
            finished.fulfill()
        }
        defer { client.disconnect(); wait(for: [finished], timeout: 5) }
        XCTAssertTrue(client.write(Data("printf 'READY-%s\\n' OK\r".utf8)))
        XCTAssertTrue(waitFor("READY-OK"))
        let gate = ExecSendBackpressure(until: Date().addingTimeInterval(0.6))
        let restore = blockSends(client, using: gate)
        client.resize(columns: 100, rows: 40)
        let blocked = Date().addingTimeInterval(0.5)
        while gate.blockedSends == 0 && Date() < blocked { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertGreaterThan(gate.blockedSends, 0, "The first resize must meet EAGAIN")
        client.resize(columns: 120, rows: 50)
        while Date() < gate.until { Thread.sleep(forTimeInterval: 0.02) }
        restore()
        XCTAssertTrue(client.write(Data("printf 'SIZE-%s-\\n' \"$(stty size)\"\r".utf8)))
        XCTAssertTrue(waitFor("SIZE-50 120-"), "stty saw: \(text().components(separatedBy: "SIZE-").last ?? "")")
    }

    private func assertRemoteTermination(timeout: Bool, sudo: Bool = false, ignoringTerm: Bool = false, sendBackpressure: TimeInterval? = nil) throws {
        let client = try connection(); defer { client.disconnect() }
        let token = TransferCancellation()
        var output = Data()
        var gate: ExecSendBackpressure?, restore: (() -> Void)?
        defer { restore?() }
        let child = (ignoringTerm ? "trap '' TERM; " : "") + "sleep 60 & child=$!; printf 'OWNED-PIDS=%s,%s\\nREADY\\n' \"$$\" \"$child\"; wait"
        let script: String
        if sudo {
            let password = try String(contentsOfFile: XCTUnwrap(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"]), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            // As with the installer, the fixture password travels only inside
            // channel stdin; printf is the shell builtin, never an argv secret.
            let privileged = "printf '%s\\nREADY\\n' \"$$\"; exec sleep 60"
            script = "printf 'OWNED-PIDS=%s,' \"$$\"\nprintf '%s\\n' " + quote(password) + " | sudo -S -k -p '' /bin/sh -c " + quote(privileged) + "\n"
        } else { script = child + "\n" }
        let started = Date()
        XCTAssertThrowsError(try client.exec("/bin/sh -s", input: Data(script.utf8), timeout: timeout ? 0.6 : 6, cancellation: token, onOutput: { bytes in
            output.append(bytes)
            if !timeout && String(decoding: output, as: UTF8.self).contains("\nREADY\n") {
                if let sendBackpressure, restore == nil {
                    let state = ExecSendBackpressure(until: Date().addingTimeInterval(sendBackpressure))
                    gate = state; restore = self.blockSends(client, using: state)
                }
                token.cancel()
            }
        })) { XCTAssertEqual($0 as? RoamError, timeout ? .timeout : .cancelled) }
        restore?(); restore = nil
        if let gate { XCTAssertGreaterThan(gate.blockedSends, 1, "The real libssh2 send sequence must encounter EAGAIN") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "Remote termination must be bounded")
        let line = try XCTUnwrap(String(decoding: output, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("OWNED-PIDS=") })
        let pids = String(line.dropFirst("OWNED-PIDS=".count))
        XCTAssertEqual(pids.split(separator: ",").compactMap { Int($0) }.count, 2)
        guard pids.allSatisfy({ $0.isNumber || $0 == "," }) else { return }
        defer { if !sudo { _ = try? client.exec("kill -KILL " + pids.replacingOccurrences(of: ",", with: " ") + " 2>/dev/null || true") } }
        // A zombie has stopped executing. The fixture's init reaps it; do not
        // mistake a non-running PID for a still-running install/download.
        let probe = "ps -o stat= -p " + pids + " 2>/dev/null | grep -v '^[[:space:]]*Z' || true"
        var live = Data()
        let deadline = Date().addingTimeInterval(3)
        repeat {
            live = try client.exec(probe, timeout: 2).output
            if live.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < deadline
        XCTAssertTrue(live.isEmpty, "The command and its child must stop, not merely lose their SSH channel")
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("printf cached-connection-reusable").output, Data("cached-connection-reusable".utf8))
    }
    private func blockSends(_ client: SSHConnection, using gate: ExecSendBackpressure) -> () -> Void {
        client.locked {
            let previousContext = roam_ssh_set_user(client.session, Unmanaged.passUnretained(gate).toOpaque())
            let callback = unsafeBitCast(execBackpressuredSend, to: (@convention(c) () -> Void).self)
            let previousCallback = libssh2_session_callback_set2(client.session, LIBSSH2_CALLBACK_SEND, callback)
            return {
                client.locked {
                    _ = libssh2_session_callback_set2(client.session, LIBSSH2_CALLBACK_SEND, previousCallback)
                    _ = roam_ssh_set_user(client.session, previousContext)
                }
                withExtendedLifetime(gate) {}
            }
        }
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class ExecSendBackpressure {
    private(set) var until: Date
    var blockedSends = 0
    /// With `onBlock`, sends pass until `skipping` went; the next one starts a `window` of EAGAIN and calls it.
    private var skipping: Int
    private let window: TimeInterval
    private var onBlock: (() -> Void)?
    init(until: Date, skipping: Int = 0, window: TimeInterval = 0, onBlock: (() -> Void)? = nil) {
        self.until = until; self.skipping = skipping; self.window = window; self.onBlock = onBlock
    }
    func blocks() -> Bool {
        if skipping > 0 { skipping -= 1; return false }
        if let start = onBlock { onBlock = nil; until = Date().addingTimeInterval(window); start() }
        return Date() < until
    }
}

// This is libssh2's existing per-session socket callback, not a production test
// hook. The library still builds/encrypts/retries its real pending signal packet;
// after temporary backpressure the bytes reach the real OpenSSH fixture.
private let execBackpressuredSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { socket, bytes, count, flags, abstract in
    guard let pointer = roam_ssh_user(abstract) else { return -Int(EINVAL) }
    let gate = Unmanaged<ExecSendBackpressure>.fromOpaque(pointer).takeUnretainedValue()
    if gate.blocks() {
        gate.blockedSends += 1
        Thread.sleep(forTimeInterval: 0.003)
        return -Int(EAGAIN)
    }
    let result = send(socket, bytes, count, flags)
    return result < 0 ? -Int(errno) : result
}
