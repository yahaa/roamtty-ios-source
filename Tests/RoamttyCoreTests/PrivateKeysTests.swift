import Foundation
import XCTest
@testable import RoamttyCore

final class PrivateKeysTests: XCTestCase {
    /// A key written by ssh-keygen, as users import them.
    private func key(type: String, passphrase: String, pem: Bool = false) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("id")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh-keygen", "-q", "-t", type] + (type == "rsa" ? ["-b", "2048"] : []) + (pem ? ["-m", "PEM"] : []) + ["-N", passphrase, "-f", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw XCTSkip("ssh-keygen unavailable") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ssh-keygen failed") }
        return try Data(contentsOf: file)
    }

    func testPlainKeysNeedNoPassphrase() throws {
        XCTAssertFalse(PrivateKeys.needsPassphrase(try key(type: "ed25519", passphrase: "")))
        XCTAssertFalse(PrivateKeys.needsPassphrase(try key(type: "rsa", passphrase: "", pem: true)))
    }

    func testEncryptedKeysNeedAPassphrase() throws {
        XCTAssertTrue(PrivateKeys.needsPassphrase(try key(type: "ed25519", passphrase: "secret1")))
        XCTAssertTrue(PrivateKeys.needsPassphrase(try key(type: "rsa", passphrase: "secret1", pem: true)))
    }

    func testUnreadableKeyStillAsks() {
        XCTAssertTrue(PrivateKeys.needsPassphrase(Data("not a key".utf8)))
        XCTAssertTrue(PrivateKeys.needsPassphrase(Data("-----BEGIN OPENSSH PRIVATE KEY-----\n!!!\n-----END OPENSSH PRIVATE KEY-----\n".utf8)))
        XCTAssertTrue(PrivateKeys.needsPassphrase(Data("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n".utf8)))
    }

    func testGreetingNeedsAValidVersionLine() {
        XCTAssertEqual(SSHGreeting.scan(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8)), .valid)
        XCTAssertEqual(SSHGreeting.scan(Data("banner line\r\nSSH-2.0-OpenSSH_9.6 Ubuntu-3\r\n".utf8)), .valid)
        XCTAssertEqual(SSHGreeting.scan(Data("SSH-1.99-Cisco_1.25\n".utf8)), .valid)
        XCTAssertEqual(SSHGreeting.scan(Data("SSH-2.0-Open".utf8)), .needMore)
        XCTAssertEqual(SSHGreeting.scan(Data()), .needMore)
        XCTAssertEqual(SSHGreeting.scan(Data("SSH-1.5-old\r\n".utf8)), .invalid)
        XCTAssertEqual(SSHGreeting.scan(Data("SSH-2.0-has-dash\r\n".utf8)), .invalid)
        XCTAssertEqual(SSHGreeting.scan(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)), .needMore)
        XCTAssertEqual(SSHGreeting.scan(Data(repeating: 65, count: 9000)), .invalid)
        XCTAssertEqual(SSHGreeting.scan(Data(("SSH-2.0-" + String(repeating: "x", count: 260) + "\r\n").utf8)), .invalid)
    }
}

final class SessionReconnectTests: XCTestCase {
    func testDroppedAndRestoredSessionsReconnectOnOpen() {
        XCTAssertTrue(SessionReconnect.onOpen(.dropped))
        XCTAssertTrue(SessionReconnect.onOpen(.restored))
        XCTAssertFalse(SessionReconnect.onOpen(.ended))
        XCTAssertFalse(SessionReconnect.onOpen(.unreachable))
        XCTAssertFalse(SessionReconnect.onOpen(nil))
        XCTAssertTrue(SessionReconnect.fromList(.unreachable))
        XCTAssertFalse(SessionReconnect.fromList(.ended))
    }

    func testOfflineHostsWaitForAFreshProbe() {
        let since = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(SessionReconnect.hostBack(online: true, checkedAt: Date(timeIntervalSince1970: 99), since: since))
        XCTAssertTrue(SessionReconnect.hostBack(online: true, checkedAt: since, since: since))
        XCTAssertFalse(SessionReconnect.hostBack(online: false, checkedAt: Date(timeIntervalSince1970: 200), since: since))
        XCTAssertFalse(SessionReconnect.hostBack(online: true, checkedAt: nil, since: since))
        XCTAssertEqual(SessionReconnect.delay(lastAttempt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 4)), 6)
        XCTAssertEqual(SessionReconnect.delay(lastAttempt: nil, now: since), 0)
    }
}
