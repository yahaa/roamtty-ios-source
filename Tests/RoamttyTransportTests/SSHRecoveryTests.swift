import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class SSHRecoveryTests: XCTestCase {
    private func fixture() throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else {
            throw XCTSkip("Set ROAMTTY_TEST_PASSWORD_FILE to run live SSH recovery tests")
        }
        let password = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!
        let host = RoamttyCore.Host(name: "Recovery fixture", address: "127.0.0.1", port: port, username: "itermux_test")
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        return SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: store) { _ in ["trust"] }
    }

    func testRemoteConnectionDeathInvalidatesConnectionAndFreshConnectionWorks() throws {
        let client = try fixture()
        defer { client.disconnect() }
        XCTAssertFalse(client.isConnected)
        try client.connect()
        XCTAssertTrue(client.isConnected)
        let disconnected = expectation(description: "connection invalidated")
        client.onPhase = { if $0 == .disconnected { disconnected.fulfill() } }
        // Only this command's unprivileged sshd session process is terminated;
        // the fixture listener and other test connections remain alive.
        _ = try? client.exec("kill -TERM \"$PPID\"", timeout: 3)
        XCTAssertThrowsError(try client.exec("printf stale-connection", timeout: 3))
        XCTAssertFalse(client.isConnected)
        wait(for: [disconnected], timeout: 2)

        let replacement = try fixture()
        defer { replacement.disconnect() }
        try replacement.connect()
        XCTAssertEqual(try replacement.exec("printf recovered").output, Data("recovered".utf8))
        replacement.disconnect()
        XCTAssertFalse(replacement.isConnected)
    }

    func testMissingFileAndRemoteCommandFailureKeepConnectionUsable() throws {
        let client = try fixture()
        defer { client.disconnect() }
        try client.connect()
        XCTAssertThrowsError(try client.readFile("/tmp/roamtty-missing-" + UUID().uuidString))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("exit 7").status, 7)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try client.exec("printf still-usable").output, Data("still-usable".utf8))
    }

    func testConcurrentSFTPAndExecInitializationReturnIndependentResults() throws {
        let client = try fixture()
        defer { client.disconnect() }
        try client.connect()
        let directory = "/tmp/roamtty-recovery-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + directory + "; printf file-a > " + directory + "/a; printf file-b > " + directory + "/b").status, 0)
        defer { _ = try? client.exec("rm -rf " + directory) }
        let finished = expectation(description: "concurrent requests")
        finished.expectedFulfillmentCount = 6
        let start = DispatchSemaphore(value: 0)
        for worker in 0..<6 {
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                start.wait()
                do {
                    for _ in 0..<5 {
                        switch worker % 3 {
                        case 0:
                            let data = try client.readFile(directory + "/a").data
                            XCTAssertEqual(data, Data("file-a".utf8))
                        case 1:
                            let data = try client.readFile(directory + "/b").data
                            XCTAssertEqual(data, Data("file-b".utf8))
                        default:
                            let token = "exec-\(worker)"
                            let data = try client.exec("printf " + token).output
                            XCTAssertEqual(data, Data(token.utf8))
                        }
                    }
                } catch { XCTFail("Concurrent SSH request failed: \(error)") }
            }
        }
        for _ in 0..<6 { start.signal() }
        wait(for: [finished], timeout: 15)
        XCTAssertTrue(client.isConnected)
    }
}
