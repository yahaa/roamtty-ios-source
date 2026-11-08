import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class SSHIntegrationTests: XCTestCase {
    private func connect(auth: AuthMethod = .password, key: Data? = nil) throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Set ROAMTTY_TEST_PASSWORD_FILE to run live OpenSSH tests") }
        let secret = try Data(contentsOf: URL(fileURLWithPath: path))
        let password = String(decoding: secret, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(name: "Fixture", address: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test", auth: auth)
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host,
            credentials: Credentials(password: Data(password.utf8), privateKey: key, passphrase: key == nil ? nil : "itermux-test-passphrase"),
            pinStore: store) { prompt in
            switch prompt {
            case .verifyHost: return ["trust"]
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        try connection.connect()
        return connection
    }
    func testPasswordAndInteractiveExec() throws {
        for method in [AuthMethod.password, .interactive] {
            let client = try connect(auth: method); defer { client.disconnect() }
            let result = try client.exec("printf 'roamtty-ssh-ok'")
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "roamtty-ssh-ok")
        }
    }
    func testSFTPFileRoundTripLiteralPathsAndNoOverwrite() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let bytes = Data((0..<250_000).map { UInt8($0 % 251) })
        let source = local.appendingPathComponent("source"); try bytes.write(to: source)
        let remoteFile = remote + "/中文 ' * ? \\ file.bin"
        var last: Int64 = 0
        try client.upload(source, to: remoteFile) { size, _ in last = size }
        XCTAssertEqual(last, Int64(bytes.count))
        XCTAssertThrowsError(try client.upload(source, to: remoteFile) { _, _ in })
        let listed = try client.listDirectory(remote)
        XCTAssertEqual(listed.entries.count, 1)
        XCTAssertEqual(listed.entries.first?.name, "中文 ' * ? \\ file.bin")
        let destination = local.appendingPathComponent("download")
        try client.download(remoteFile, to: destination) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let preview = try client.readFile(remoteFile, maxBytes: 10)
        XCTAssertEqual(preview.data.count, 10)
        XCTAssertTrue(preview.truncated)
        try client.rename(remoteFile, to: remote + "/renamed")
        try client.remove(remote + "/renamed")
        XCTAssertTrue(try client.listDirectory(remote).entries.isEmpty)
    }
    func testNonUTF8NamesAreLeftOutRatherThanAliasingAnotherFile() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        // bad\xff decodes lossily to the valid name bad\u{FFFD}, so both used to share one path.
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && cd " + remote + " && printf X > \"$(printf 'bad\\377')\" && printf KEEP > \"$(printf 'bad\\357\\277\\275')\"").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let listed = try client.listDirectory(remote)
        XCTAssertEqual(listed.entries.map(\.name), ["bad\u{FFFD}"])
        XCTAssertEqual(listed.unreadableNames, 1)
        let entry = try XCTUnwrap(listed.entries.first)
        XCTAssertEqual(entry.size, 4)
        XCTAssertEqual(try client.readFile(entry.path).text, "KEEP")
        XCTAssertThrowsError(try client.remove(remote, recursive: true), "A folder with unnamed entries must not be emptied")
        XCTAssertEqual(try client.listDirectory(remote).entries.count, 1)
        try client.remove(entry.path)
        XCTAssertEqual(String(decoding: try client.exec("cd " + remote + " && cat -- *").output, as: UTF8.self), "X")
    }
    func testEncryptedEd25519AndRSAKeys() throws {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_KEYS"] else { throw XCTSkip("No fixture keys") }
        for name in ["ed25519", "rsa"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name))
            let client: SSHConnection
            do { client = try connect(auth: .key, key: data) } catch { XCTFail("Key authentication failed for \(name): \(error)"); continue }
            defer { client.disconnect() }
            XCTAssertEqual(try client.exec("printf key-ok").output, Data("key-ok".utf8))
        }
    }
    func testCreateDirectoryUsesLiteralPathAndRefusesExistingOrCancelledRequests() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let name = "中文 ' ; $(echo unsafe) folder"
        let path = joinRemotePath(directory: remote, name: name)
        try client.createDirectory(path)
        let entry = try XCTUnwrap(client.listDirectory(remote).entries.first)
        XCTAssertEqual(entry.name, name)
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.permissions & 0o777, 0o755)
        XCTAssertThrowsError(try client.createDirectory(path))
        let cancelled = TransferCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try client.createDirectory(remote + "/cancelled", cancellation: cancelled))
        XCTAssertThrowsError(try client.createDirectory(remote + "/nul\0suffix"))
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), [name])
        XCTAssertTrue(client.isConnected)
    }
    func testCancelledDownloadCleansLocalPartial() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("dd if=/dev/zero of=" + remote + " bs=1048576 count=4 2>/dev/null").status, 0)
        defer { _ = try? client.exec("rm -f " + remote) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.download(remote, to: file, progress: { count, _ in
            if count > 0 { token.cancel() }
        }, cancellation: token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try client.exec("printf still-connected").output, Data("still-connected".utf8))
    }
    func testBrowserMutationCancellationDoesNotRetargetOrCloseSharedConnection() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-mutation-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && printf original > " + remote + "/source").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try client.rename(remote + "/source", to: remote + "/destination", cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertThrowsError(try client.createDirectory(remote + "/new", cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertThrowsError(try client.remove(remote, recursive: true, cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["source"])
        try client.rename(remote + "/source", to: remote + "/destination", cancellation: TransferCancellation())
        XCTAssertEqual(try client.readFile(remote + "/destination").text, "original")
        XCTAssertEqual(try client.exec("printf shared-terminal-alive").output, Data("shared-terminal-alive".utf8))
    }
    func testRecursiveBrowserDeleteCancelsAfterActualRemoteProgressAndKeepsOtherOperationsUsable() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-delete-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && i=0; while [ \"$i\" -lt 5000 ]; do : > " + remote + "/entry-$i; i=$((i+1)); done").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let token = TransferCancellation()
        let done = expectation(description: "Only the requested recursive deletion is cancelled")
        DispatchQueue.global().async {
            do { try client.remove(remote, recursive: true, cancellation: token); XCTFail("Delete completed without observing cancellation") } catch { XCTAssertEqual(error as? RoamError, .cancelled) }
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(8)
        var observedProgress = false
        while Date() < deadline {
            let result = try client.exec("find " + remote + " -type f 2>/dev/null | wc -l")
            if let count = Int(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), count < 5000 {
                observedProgress = count > 0; break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        token.cancel()
        XCTAssertTrue(observedProgress, "Cancel after a real unlink, while work remains")
        wait(for: [done], timeout: 8)
        XCTAssertFalse(try client.listDirectory(remote).entries.isEmpty, "Cancellation must stop before deleting the remaining files")
        try client.createDirectory(remote + "/still-usable")
        XCTAssertEqual(try client.exec("printf shared-terminal-alive").output, Data("shared-terminal-alive".utf8))
    }
    func testIndividualTransferCancellationDoesNotCancelOtherJob() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 262_144).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.upload(local, to: remote + "/cancelled", progress: { count, _ in
            if count > 0 { token.cancel() }
        }, cancellation: token))
        try client.upload(local, to: remote + "/completed") { _, _ in }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["completed"])
        token.cancel()
        XCTAssertThrowsError(try client.listDirectory(remote, cancellation: token))
    }
    func testCancelAtLastUploadProgressCannotPublishDestination() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 10).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.upload(local, to: remote + "/cancelled", progress: { count, _ in
            if count == 10 { token.cancel() }
        }, cancellation: token))
        XCTAssertTrue(try client.listDirectory(remote).entries.isEmpty)
    }
    func testTerminalRemainsUsableDuringSFTP() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let received = expectation(description: "concurrent terminal input")
        let output = LockedOutput()
        DispatchQueue.global().async {
            var matched = false
            try? client.runTerminal { data in
                output.append(data)
                if !matched && output.text.contains("CONCURRENT-OK") { matched = true; received.fulfill() }
            }
        }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        try Data(repeating: 37, count: 2_000_000).write(to: local)
        defer { try? FileManager.default.removeItem(at: local); _ = try? client.exec("rm -f " + remote) }
        var sent = false
        try client.upload(local, to: remote) { count, _ in
            if !sent && count > 0 { sent = true; XCTAssertTrue(client.write(Data("printf 'CONCURRENT-%s\\n' OK\r".utf8))) }
        }
        wait(for: [received], timeout: 8)
        XCTAssertEqual(try client.exec("wc -c < " + remote).status, 0)
    }
    /// A loop parks on the socket for long only while nothing else can take its packets off it.
    func testLoopWaitsLongOnlyWhileItIsTheConnectionsSoleUser() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let host = Host(name: "Unused", address: "127.0.0.1", port: 22, username: "nobody", auth: .password)
        let client = SSHConnection(host: host, credentials: Credentials(password: nil, privateKey: nil, passphrase: nil), pinStore: store) { _ in nil }
        let terminal = try XCTUnwrap(WorkerWake()), stream = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(terminal) {
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
            client.asOtherWork {
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "an exec or SFTP request in flight")
                client.asOtherWork { XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs) }
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "the outer request still runs")
            }
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
            client.asWaitingLoop(stream) {
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "two loops share the socket")
                XCTAssertEqual(client.waitMilliseconds(for: stream), SSHConnection.sharedWaitMs)
            }
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
        }
    }
    /// An idle terminal waits up to a second at a time; typed input and remote output still end the wait at once.
    func testIdleTerminalAnswersInputAndLateOutputPromptly() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let output = LockedOutput()
        let echoed = expectation(description: "input echo"), late = expectation(description: "output with no input")
        DispatchQueue.global().async {
            var sawEcho = false, sawLate = false
            try? client.runTerminal { data in
                output.append(data)
                if !sawEcho && output.text.contains("IDLE-ECHO-OK") { sawEcho = true; echoed.fulfill() }
                if !sawLate && output.text.contains("IDLE-LATE-OK") { sawLate = true; late.fulfill() }
            }
        }
        Thread.sleep(forTimeInterval: 1.5) // Let the loop settle into its long waits.
        let typed = Date()
        XCTAssertTrue(client.write(Data("printf 'IDLE-ECHO-%s\\n' OK\r".utf8)))
        wait(for: [echoed], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(typed), 0.8, "input wakes the wait")
        XCTAssertTrue(client.write(Data("sleep 1.5; printf 'IDLE-LATE-%s\\n' OK\r".utf8)))
        let asked = Date()
        wait(for: [late], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 2.3, "readable socket wakes the wait")
        // A side command reads the socket meanwhile: the terminal still gets its own output.
        XCTAssertTrue(client.write(Data("sleep 0.3; printf 'IDLE-SIDE-%s\\n' OK\r".utf8)))
        let side = Date()
        XCTAssertEqual(try client.exec("sleep 1.2; printf done").output, Data("done".utf8))
        XCTAssertTrue(output.text.contains("IDLE-SIDE-OK"), "terminal output arrived while the exec ran")
        XCTAssertLessThan(Date().timeIntervalSince(side), 3)
    }
    /// A folder transfer on one SFTP session: create, upload, list, download, then a recursive delete.
    func testSharedSFTPSessionTransfersATreeAndRecursiveDeleteReusesIt() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-tree-" + UUID().uuidString
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("one".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let back = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: back) }
        let names: [String] = try client.withSFTPSession { sftp in
            try sftp.createDirectory(remote)
            XCTAssertThrowsError(try sftp.createDirectory(remote), "an existing folder fails without ending the session")
            try sftp.createDirectory(remote + "/nested")
            try sftp.upload(local, to: remote + "/nested/a.txt") { _, _ in }
            try sftp.upload(local, to: remote + "/b.txt") { _, _ in }
            try sftp.download(remote + "/nested/a.txt", to: back) { _, _ in }
            return try sftp.listDirectory(remote).entries.map(\.name)
        }
        XCTAssertEqual(names, ["nested", "b.txt"])
        XCTAssertEqual(try Data(contentsOf: back), Data("one".utf8))
        XCTAssertEqual(try client.exec("mkdir -p \(remote)/nested/deeper/deepest && touch \(remote)/nested/deeper/x \(remote)/nested/deeper/deepest/y").status, 0)
        try client.remove(remote, recursive: true)
        XCTAssertNotEqual(try client.exec("test -e " + remote).status, 0)
        XCTAssertTrue(client.isConnected)
    }
    /// A path search reads every folder through one held session, across awaits, then closes it.
    func testHeldSFTPSessionServesAPathSearchAndEndsWhenClosed() async throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-search-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -p \(remote)/alpha/one \(remote)/alpha/two \(remote)/beta && touch \(remote)/alpha/one/f.txt").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let sftp = try client.holdSFTPSession()
        var reads: [String] = []
        let result = try await resolveRemoteSearchDirectories(directory: remote, prefix: "al/on", showHidden: false) { path in
            reads.append(path)
            return try sftp.listDirectory(path)
        }
        XCTAssertEqual(reads.count, 3, "the base folder, alpha, then one")
        XCTAssertEqual(result.directories.map(\.path), [remote + "/alpha/one"])
        XCTAssertEqual(result.directories.first?.entries.map(\.name), ["f.txt"])
        XCTAssertThrowsError(try sftp.listDirectory(remote + "/missing"), "a failed read leaves the session usable")
        XCTAssertEqual(try sftp.listDirectory(remote).entries.map(\.name), ["alpha", "beta"])
        // While it is held, a terminal loop on this connection waits briefly; closing it restores the long wait.
        let loop = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.sharedWaitMs) }
        sftp.close(); sftp.close()
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.idleWaitMs) }
        XCTAssertThrowsError(try sftp.listDirectory(remote)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["alpha", "beta"])
        XCTAssertTrue(client.isConnected)
    }
    func testHeldSFTPSessionRefusesACancelledRequest() throws {
        let client = try connect(); defer { client.disconnect() }
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try client.holdSFTPSession(cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        let loop = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.idleWaitMs, "a refused open ends its work") }
        XCTAssertEqual(try client.exec("printf ok").output, Data("ok".utf8))
    }
    func testPTYInputAndResize() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let ready = expectation(description: "terminal output")
        let output = LockedOutput()
        DispatchQueue.global().async {
            try? client.runTerminal { data in
                output.append(data)
                if output.text.contains("ROAMTTY-PTY-OK") { ready.fulfill(); client.disconnect() }
            }
        }
        XCTAssertTrue(client.write(Data("printf 'ROAMTTY-PTY-%s\\n' OK\r".utf8)))
        client.resize(columns: 100, rows: 40)
        wait(for: [ready], timeout: 8)
    }
    func testTmuxGuardQueriesActivePaneOfExactSession() throws {
        let client = try connect(); defer { client.disconnect() }
        guard try client.exec(RemoteCommands.tmuxProbe).status == 0 else { throw XCTSkip("tmux is not installed on fixture") }
        let name = "roamtty-test-" + UUID().uuidString.prefix(8)
        XCTAssertEqual(try client.exec("tmux new-session -d -s " + name).status, 0)
        defer { _ = try? client.exec(RemoteCommands.killTmux(name)) }
        let state = try client.exec(RemoteCommands.tmuxAlternateScreen(name))
        XCTAssertEqual(state.status, 0)
        XCTAssertEqual(String(decoding: state.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }
}
private final class LockedOutput {
    let lock = NSLock(); var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}
