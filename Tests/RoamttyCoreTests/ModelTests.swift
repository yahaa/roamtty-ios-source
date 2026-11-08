import XCTest
@testable import RoamttyCore

final class ModelTests: XCTestCase {
    func testEndpointNormalizationAndValidation() throws {
        XCTAssertEqual(try Host(name: "test", address: "[2001:db8::1]", username: "root").validated().endpoint, "[2001:db8::1]:22")
        XCTAssertEqual(try Host(name: "test", address: "EXAMPLE.COM.", username: "root").validated().endpoint, "[example.com]:22")
        XCTAssertThrowsError(try Host(name: "test", address: "ssh://evil", username: "root").validated())
        XCTAssertThrowsError(try Host(name: "test", address: "a", port: 0, username: "root").validated())
    }
    /// Saved credentials are found by these names: renaming a case would orphan every stored password and key.
    func testSecretPurposesKeepTheirKeychainNames() {
        XCTAssertEqual(SecretPurpose.allCases.map(\.rawValue), ["password", "key"])
    }
    func testSessionLimitAndIndependentTmuxNames() throws {
        var journal = SessionJournal()
        let first = try journal.create(hostID: "one", mode: .tmux)
        let second = try journal.create(hostID: "one", mode: .tmux)
        XCTAssertNotEqual(first.remoteName, second.remoteName)
        for _ in 0..<6 { _ = try journal.create(hostID: "one", mode: .shell) }
        XCTAssertThrowsError(try journal.create(hostID: "one", mode: .tmux))
        XCTAssertNoThrow(try journal.create(hostID: "two", mode: .tmux))
        journal.forget(first.id)
        XCTAssertFalse(journal.records.contains { $0.id == first.id })
    }
    func testExistingTmuxSessionKeepsItsNameAndOlderJournalsDecode() throws {
        var journal = SessionJournal()
        let attached = try journal.create(hostID: "one", mode: .shell, title: "work", external: "work")
        XCTAssertEqual(attached.remoteName, "work"); XCTAssertEqual(attached.mode, .tmux); XCTAssertTrue(attached.external)
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(attached)), attached)
        let legacy = #"{"id":"a","hostID":"one","mode":"tmux","title":"","remoteName":"roamtty-1","number":2}"#
        XCTAssertFalse(try JSONDecoder().decode(SessionRecord.self, from: Data(legacy.utf8)).external)
    }
    func testInputNeverSurvivesReconnectAndRemainsBounded() {
        var queue = InputQueue()
        for _ in 0..<64 { XCTAssertTrue(queue.enqueue(Data([1]))) }
        XCTAssertFalse(queue.enqueue(Data([2])))
        queue.reset()
        XCTAssertNil(queue.pop())
        XCTAssertFalse(queue.enqueue(Data(repeating: 1, count: 256 * 1024 + 1)))
    }

    /// Android's TargetAddressTest: addresses typed into the editor are checked by their syntax alone.
    func testRejectsMalformedHostnamesAndAddresses() {
        for address in ["server..example", "server..", ".server", "-server.example", "server-.example", "server!", "_server", "server_", "host:22",
                        "[server]", "[::1", "::1]", "1.2.3.999", "1.2.3", "1:2:3", "1::2::3", "fe80::1%",
                        "192.0.2.1::", "1:192.0.2.1::", "ssh://server", "user@server", "server/path", "server name", ""] {
            XCTAssertFalse(isValidHostAddress(address), address)
        }
    }

    func testAcceptsOfflineNamesAndLiteralIpAddressesWithoutDns() {
        for address in ["dev", "server.example", "EXAMPLE.COM.", "my-server.local", "bücher.example", "192.168.1.42",
                        "build_box", "ci_runner.lan", "::1", "[::1]", "2001:db8::12", "fe80::1%wlan0", "[fe80::1%3]", "::ffff:192.0.2.1", "1:2:3:4:5:6:7:8"] {
            XCTAssertTrue(isValidHostAddress(address), address)
        }
    }

    /// Hosts saved before the check still load, so they can be opened and repaired.
    func testLegacyMalformedSavedHostsStillValidate() throws {
        XCTAssertEqual(try Host(name: "old", address: "server..example", username: "dev").validated().address, "server..example")
    }
}
