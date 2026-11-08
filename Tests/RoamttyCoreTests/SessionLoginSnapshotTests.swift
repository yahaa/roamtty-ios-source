import XCTest
@testable import RoamttyCore

final class SessionLoginSnapshotTests: XCTestCase {
    private let original = Host(id: "same-row", name: "Original", address: "old.example", port: 22, username: "alice")

    func testChangedEndpointKeepsOriginalHostAndPassword() {
        let login = SessionLoginSnapshot(host: original, credentials: Credentials(password: Data("original-secret".utf8)))
        var edited = original; edited.address = "new.example"; edited.port = 2200; edited.username = "bob"
        let retry = login.reconnect(using: edited)
        XCTAssertEqual(retry.host, original)
        XCTAssertFalse(retry.usesSavedCredentials)
        XCTAssertEqual(retry.retainedCredentials?.password, Data("original-secret".utf8))
    }

    func testSameLoginUsesCurrentSavedCredentialsForCorrection() {
        let login = SessionLoginSnapshot(host: original, credentials: Credentials(password: Data("rejected-secret".utf8)))
        var renamed = original; renamed.name = "Renamed"; renamed.plugins = ["mosh"]
        let retry = login.reconnect(using: renamed)
        XCTAssertEqual(retry.host, renamed)
        XCTAssertTrue(retry.usesSavedCredentials)
        XCTAssertNil(retry.retainedCredentials)
    }

    func testChangedAuthenticationKeepsOriginalPrivateKey() {
        var keyHost = original; keyHost.auth = .key
        let login = SessionLoginSnapshot(host: keyHost, credentials: Credentials(privateKey: Data("old-key".utf8), passphrase: "old-phrase"))
        let retry = login.reconnect(using: original)
        XCTAssertEqual(retry.host.auth, .key)
        XCTAssertFalse(retry.usesSavedCredentials)
        XCTAssertEqual(retry.retainedCredentials?.privateKey, Data("old-key".utf8))
        XCTAssertEqual(retry.retainedCredentials?.passphrase, "old-phrase")
    }

    func testAuthenticationFailureClearsSecretsButKeepsKeyForNewPassphrase() {
        var login = SessionLoginSnapshot(host: original, credentials: Credentials(password: Data("bad-password".utf8), privateKey: Data("key".utf8), passphrase: "bad-phrase"))
        login.invalidateAuthentication()
        var edited = original; edited.port = 1
        let credentials = login.reconnect(using: edited).retainedCredentials
        XCTAssertNil(credentials?.password)
        XCTAssertNil(credentials?.passphrase)
        XCTAssertEqual(credentials?.privateKey, Data("key".utf8))
    }

    func testClearingOldRuntimeDoesNotEraseCopiedReplacementLogin() {
        var old = SessionLoginSnapshot(host: original, credentials: Credentials(password: Data("password".utf8), privateKey: Data("key".utf8), passphrase: "phrase"))
        let replacement = old
        old.clear()
        var edited = original; edited.port = 1
        let cleared = old.reconnect(using: edited)
        XCTAssertEqual(cleared.host, original)
        XCTAssertFalse(cleared.usesSavedCredentials)
        XCTAssertNil(cleared.retainedCredentials?.password)
        XCTAssertNil(cleared.retainedCredentials?.privateKey)
        XCTAssertNil(cleared.retainedCredentials?.passphrase)
        let retained = replacement.reconnect(using: edited).retainedCredentials
        XCTAssertEqual(retained?.password, Data("password".utf8))
        XCTAssertEqual(retained?.privateKey, Data("key".utf8))
        XCTAssertEqual(retained?.passphrase, "phrase")
    }
}
