import XCTest
import Network

/// Real OpenSSH backends and a separately controlled TCP proxy. The app receives no
/// fault-injection hooks: each failure reaches its normal transport and trust policy.
final class NetworkRecoveryUITests: RoamttyLiveUITestCase {
    private var fixture: Configuration!

    override func setUpWithError() throws {
        fixture = try Configuration()
        try super.setUpWithError()
        _ = try control("a")
        app.terminate()
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "Recovery-\(UUID().uuidString)"
        app.launchEnvironment["ROAMTTY_TEST_HOST"] = fixture.host
        app.launchEnvironment["ROAMTTY_TEST_PORT"] = String(fixture.port)
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if fixture != nil { _ = try? control("a") }
        try super.tearDownWithError()
    }

    func testRealMoshFirstContactTimeoutFallsBackWithoutRepeatingStartup() throws {
        let before = try control("status")
        try openRecoveryHost(expectedFingerprint: before.fingerprints.a)
        let surface = try openTerminal(preferMosh: true, directory: before.workDirectory, mode: "SSH")
        let notice = app.staticTexts["terminal-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Mosh unavailable") && notice.label.contains("SSH"))
        XCTAssertFalse(terminalTransport.hasSuffix("mosh"))
        let after = try control("status")
        XCTAssertGreaterThan(after.counters.mosh, before.counters.mosh, "The real mosh-server must have bootstrapped successfully")
        XCTAssertGreaterThan(after.loopbackMoshServers, 0, "The actual UDP server must be isolated on loopback")
        XCTAssertGreaterThanOrEqual(after.lastShellStart - after.lastMoshStart, 7.5, "SSH must follow the production eight-second first-contact timeout")

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let file = "input-" + suffix
        _ = try runCommand("printf x >> '\(file)'; n=$(wc -c < '\(file)'); printf 'FALLBACK_%s_%s\\n' '\(suffix)' \"$n\"; printf 'DIRECTORY_%s\\n' \"$PWD\"")
        waitForOutput("FALLBACK_\(suffix)_1", surface: surface)
        waitForOutput("DIRECTORY_" + before.workDirectory, surface: surface)
        XCTAssertEqual(try control("status").counters.startup - before.counters.startup, 1, "The fixture shell counts actual successful cd calls into the launch directory")
        _ = try runCommand("rm -f -- '\(file)'; printf 'CLEAN_%s\\n' '\(suffix)'")
        waitForOutput("CLEAN_" + suffix, surface: surface)
        capture("Real UDP first-contact timeout reaches SSH with one startup and one input")
        closeTerminal()
    }

    func testChangedHostKeyRequiresReviewRemovalAndFreshExplicitTrust() throws {
        let original = try control("status")
        XCTAssertNotEqual(original.fingerprints.a, original.fingerprints.b)
        try openRecoveryHost(expectedFingerprint: original.fingerprints.a)
        var surface = try openTerminal(mode: "SSH")
        let suffix = String(UUID().uuidString.prefix(8))
        _ = try runCommand("printf 'KEY_A_%s\\n' '\(suffix)'")
        waitForOutput("KEY_A_" + suffix, surface: surface)

        _ = try control("b") // Same host and port; all old TCP flows are closed.
        let reconnect = app.buttons["terminal-reconnect"]
        // The dropped terminal reconnects by itself, straight into the changed key.
        assertChangedKey()
        reviewButton.tap()
        let cancel = app.navigationBars.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        assertChangedKey() // Cancelling review must leave A's pin intact.
        XCTAssertFalse(reconnect.exists, "A changed key offers only review, as on Android")

        reviewButton.tap()
        let forget = app.buttons["fingerprint-remove"]
        // Removing the old record reconnects at once and shows the new fingerprint for approval.
        XCTAssertTrue(forget.waitForExistence(timeout: 5)); forget.tap()
        let fingerprint = app.staticTexts["auth-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        XCTAssertEqual(fingerprint.label, original.fingerprints.b)
        XCTAssertNotEqual(fingerprint.label, original.fingerprints.a)
        app.buttons["auth-confirm"].tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        _ = try runCommand("printf 'KEY_B_%s\\n' '\(suffix)'")
        waitForOutput("KEY_B_" + suffix, surface: surface)
        capture("Changed key reconnects only after review and explicit approval of key B")
        leaveTerminal() // Back to the host page, whose monitor must use the approved key too.
        assertLiveMonitor()
        XCTAssertFalse(app.buttons["auth-confirm"].exists, "The explicitly approved replacement pin must also authenticate the host monitor")
    }

    func testHostMonitorAutomaticallyRecoversAfterEstablishedConnectionLoss() throws {
        let original = try control("status")
        try openRecoveryHost(expectedFingerprint: original.fingerprints.a)
        assertLiveMonitor()
        let before = try control("status")
        _ = try control("offline") // Closes listener AND existing flows, not only sshd's listener.
        let status = app.staticTexts["host-monitor-status"]
        let reconnecting = NSPredicate(format: "label CONTAINS '自动重连' OR label CONTAINS 'Reconnecting'")
        let retry = XCTNSPredicateExpectation(predicate: reconnecting, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [retry], timeout: 20), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists, "A network outage retains the last real readings")
        XCTAssertFalse(app.buttons["auth-confirm"].exists)
        capture("Monitor reports automatic retry while retaining its last sample")
        _ = try control("online")
        assertLiveMonitor(timeout: 40)
        XCTAssertFalse(app.buttons["auth-confirm"].exists)
        let after = try control("status")
        XCTAssertGreaterThan(after.counters.metrics, before.counters.metrics, "Recovery must execute another real metrics script, not merely redisplay cached gauges")
        capture("Monitor automatically resumes real sampling after the endpoint returns")
    }

    private var reviewButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == '重新核验…' OR label == 'Verify again…'")).firstMatch
    }
    private func assertChangedKey() {
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["auth-fingerprint"].exists, "A mismatched saved pin must block without offering implicit replacement")
        XCTAssertFalse(app.buttons["auth-confirm"].exists)
        XCTAssertFalse(phase("已连接").exists)
    }
    private func openRecoveryHost(expectedFingerprint: String) throws {
        showHostsTab()
        let host = app.buttons["host-UI Live Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        let fingerprint = app.staticTexts["auth-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        XCTAssertEqual(fingerprint.label, expectedFingerprint)
        app.buttons["auth-confirm"].tap()
        assertLiveMonitor()
    }
    private func assertLiveMonitor(timeout: TimeInterval = 20) {
        let status = app.staticTexts["host-monitor-status"]
        let sampled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '每 3 秒刷新' OR label == 'Refreshes every 3 seconds'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [sampled], timeout: timeout), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-memory"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["host-gauge-disk"].firstMatch.exists)
    }

    private struct Configuration {
        let host: String, token: String
        let port: Int, controlPort: UInt16
        init() throws {
            let env = ProcessInfo.processInfo.environment
            host = try XCTUnwrap(env["ROAMTTY_RECOVERY_HOST"], "Recovery fixture is required; do not skip this acceptance test")
            token = try XCTUnwrap(env["ROAMTTY_RECOVERY_TOKEN"])
            port = try XCTUnwrap(env["ROAMTTY_RECOVERY_PORT"].flatMap(Int.init))
            controlPort = try XCTUnwrap(env["ROAMTTY_RECOVERY_CONTROL_PORT"].flatMap(UInt16.init))
            XCTAssertFalse(token.isEmpty)
        }
    }
    private struct Snapshot: Decodable {
        struct Fingerprints: Decodable { let a: String, b: String }
        struct Counters: Decodable { let mosh: Int, shell: Int, startup: Int, metrics: Int }
        let ok: Bool
        let fingerprints: Fingerprints
        let workDirectory: String
        let counters: Counters
        let loopbackMoshServers: Int
        let lastMoshStart: Double
        let lastShellStart: Double
    }
    private func control(_ action: String) throws -> Snapshot {
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: fixture.controlPort))
        let connection = NWConnection(host: NWEndpoint.Host(fixture.host), port: port, using: .tcp)
        // This helper owns its waiter; do not register the expectation with the
        // test case, whose UI helpers later call waitForExpectations themselves.
        let completed = XCTestExpectation(description: "Recovery fixture control: " + action)
        let answer = ControlAnswer(completed)
        let payload = try JSONSerialization.data(withJSONObject: ["token": fixture.token, "action": action]) + Data([10])
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { bytes, _, ended, error in
                if let bytes { answer.bytes.append(bytes) }
                if error != nil || ended || answer.bytes.contains(10) { answer.finish(error); connection.cancel() } else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { answer.finish(error); connection.cancel() } else { receive() }
                })
            case .failed(let error): answer.finish(error); connection.cancel()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "roamtty.recovery.control"))
        defer { connection.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: 10) == .completed else {
            throw NSError(domain: "RecoveryFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture control timed out"])
        }
        if let error = answer.error { throw error }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(Snapshot.self, from: answer.bytes)
        XCTAssertTrue(result.ok)
        return result
    }
    private final class ControlAnswer {
        var bytes = Data()
        var error: Error?
        private var finished = false
        private let expectation: XCTestExpectation
        init(_ expectation: XCTestExpectation) { self.expectation = expectation }
        func finish(_ error: Error?) {
            guard !finished else { return }; finished = true
            self.error = error; expectation.fulfill()
        }
    }
}
