import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class MoshTransportTests: XCTestCase {
    private let key = "4NeCCgvZFe2RnPgrcU1PQw"

    func testInputBudgetIncludesUnacknowledgedDataAndCloseRejectsWrites() throws {
        let transport = try MoshTransport(host: "127.0.0.1", port: 60001, key: key)
        XCTAssertFalse(transport.write(Data(repeating: 1, count: 256 * 1024 + 1)))
        for _ in 0..<4 { XCTAssertTrue(transport.write(Data(repeating: 1, count: 256 * 1024))) }
        XCTAssertFalse(transport.write(Data([1])))
        transport.close()
        XCTAssertFalse(transport.write(Data([1])))
        XCTAssertThrowsError(try transport.run(columns: 80, rows: 24, onOutput: { _ in })) {
            XCTAssertEqual($0 as? RoamError, .cancelled)
        }
    }

    func testClosedUDPPortTriggersFirstContactTimeoutWithoutUnboundedRetry() throws {
        let transport = try MoshTransport(host: "127.0.0.1", port: 9, key: key)
        let start = Date()
        XCTAssertThrowsError(try transport.run(columns: 80, rows: 24, firstContactTimeout: 0.2, onOutput: { _ in })) {
            XCTAssertEqual($0 as? RoamError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(transport.write(Data("stale input".utf8)))
    }

    func testCloseInterruptsRunningTransport() throws {
        let transport = try MoshTransport(host: "127.0.0.1", port: 9, key: key)
        let finished = expectation(description: "worker cancelled")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try transport.run(columns: 80, rows: 24, onOutput: { _ in })
                XCTFail("Closed mosh transport returned without cancellation")
            } catch { XCTAssertEqual(error as? RoamError, .cancelled) }
        }
        transport.close()
        wait(for: [finished], timeout: 2)
    }

    func testInvalidEndpointsAreRejectedBeforeRun() {
        XCTAssertThrowsError(try MoshTransport(host: "", port: 60001, key: key))
        XCTAssertThrowsError(try MoshTransport(host: "127.0.0.1", port: 0, key: key))
        XCTAssertThrowsError(try MoshTransport(host: "127.0.0.1", port: 70000, key: key))
        XCTAssertThrowsError(try MoshTransport(host: "127.0.0.1", port: 60001, key: "bad"))
    }

    #if os(Linux) || os(macOS)
    func testRealMoshServerInputResizeProbeAndRemoteShutdown() throws {
        let executable = ProcessInfo.processInfo.environment["ROAMTTY_MOSH_SERVER"] ?? "/usr/bin/mosh-server"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("mosh-server is not installed") }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["new", "-i", "127.0.0.1", "-p", "60001:60999", "--", "/bin/sh"]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"
        environment["TERM"] = "xterm-256color"
        environment["MOSH_SERVER_NETWORK_TMOUT"] = "20"
        server.environment = environment
        let pipe = Pipe()
        server.standardOutput = pipe
        server.standardError = pipe
        try server.run()
        // Foundation's waitUntilExit can wait for the detached server's inherited
        // descriptors. Connect upon its announcement while the server is alive.
        var announcement = Data()
        var connection: Mosh.Connect?
        while connection == nil {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            announcement.append(chunk)
            connection = Mosh.parseConnect(String(decoding: announcement, as: UTF8.self))
        }
        guard let connect = connection else {
            XCTFail("mosh-server did not announce a valid connection"); return
        }
        let transport = try MoshTransport(host: "127.0.0.1", port: connect.port, key: connect.key)
        defer { transport.close() }
        let initial = expectation(description: "initial terminal state")
        let echoed = expectation(description: "evaluated shell output")
        let resized = expectation(description: "remote terminal resized")
        let finished = expectation(description: "remote shell shutdown")
        let output = MoshTestOutput()
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                var sawInitial = false, sawEcho = false, sawSize = false
                try transport.run(columns: 80, rows: 24) { bytes in
                    let text = output.append(bytes)
                    if !sawInitial { sawInitial = true; initial.fulfill() }
                    if !sawEcho && text.contains("mosh-proof-42") { sawEcho = true; echoed.fulfill() }
                    if !sawSize && text.contains("33 91") { sawSize = true; resized.fulfill() }
                }
            } catch { XCTFail("Live mosh run failed: \(error)") }
        }
        guard XCTWaiter.wait(for: [initial], timeout: 10) == .completed else {
            XCTFail("No initial mosh terminal state"); return
        }
        XCTAssertTrue(transport.write(Data("printf 'mosh-proof-%s\\n' \"$((40+2))\"\r".utf8)))
        guard XCTWaiter.wait(for: [echoed], timeout: 10) == .completed else {
            XCTFail("Shell command did not produce its expected output"); return
        }
        transport.resize(columns: 91, rows: 33)
        transport.probe()
        XCTAssertTrue(transport.write(Data("stty size\r".utf8)))
        guard XCTWaiter.wait(for: [resized], timeout: 10) == .completed else {
            XCTFail("Remote PTY did not resize"); return
        }
        XCTAssertTrue(transport.write(Data("exit\r".utf8)))
        wait(for: [finished], timeout: 10)
        XCTAssertFalse(transport.write(Data("stale input".utf8)))
    }
    #endif
}

private final class MoshTestOutput {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        return String(decoding: bytes, as: UTF8.self)
    }
}
