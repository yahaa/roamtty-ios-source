import XCTest
@testable import RoamttyCore

final class ConnectionGenerationsTests: XCTestCase {
    func testGenerationsAreStableUntilInvalidated() {
        var generations = ConnectionGenerations()
        let host = generations.host("h"), owner = generations.owner("s")
        XCTAssertEqual(generations.host("h"), host)
        XCTAssertEqual(generations.owner("s"), owner)
        XCTAssertTrue(generations.isCurrent(host: "h", generation: host, owner: "s", ownerGeneration: owner))
        XCTAssertTrue(generations.isCurrent(host: "h", generation: host, owner: nil, ownerGeneration: nil))
    }

    func testInvalidatingHostOrOwnerMakesAttemptsStale() {
        var generations = ConnectionGenerations()
        let host = generations.host("h"), owner = generations.owner("s")
        generations.invalidateOwner("s")
        XCTAssertFalse(generations.isCurrent(host: "h", generation: host, owner: "s", ownerGeneration: owner))
        XCTAssertTrue(generations.isCurrent(host: "h", generation: host, owner: nil, ownerGeneration: nil))
        generations.invalidateHost("h")
        XCTAssertFalse(generations.isCurrent(host: "h", generation: host, owner: nil, ownerGeneration: nil))
        XCTAssertNotEqual(generations.host("h"), host)
    }

    func testAttemptStaysCurrentUntilItsHostOrOwnerMovesOn() {
        var generations = ConnectionGenerations()
        let owned = generations.attempt(host: "h", owner: "s"), hostOnly = generations.attempt(host: "h", owner: nil)
        XCTAssertEqual(owned.hostGeneration, hostOnly.hostGeneration)
        XCTAssertNil(hostOnly.ownerGeneration)
        XCTAssertTrue(generations.isCurrent(owned))
        generations.invalidateOwner("other")
        XCTAssertTrue(generations.isCurrent(owned))
        generations.invalidateOwner("s")
        XCTAssertFalse(generations.isCurrent(owned))
        XCTAssertTrue(generations.isCurrent(hostOnly))
        generations.invalidateHost("h")
        XCTAssertFalse(generations.isCurrent(hostOnly))
        XCTAssertTrue(generations.isCurrent(generations.attempt(host: "h", owner: "s")))
    }

    func testUnknownHostIsNeverCurrent() {
        let generations = ConnectionGenerations()
        XCTAssertFalse(generations.isCurrent(host: "h", generation: UUID(), owner: nil, ownerGeneration: nil))
    }
}

final class CredentialCacheTests: XCTestCase {
    func testForgetWipesAndDrops() {
        var cache = CredentialCache()
        cache.store(Credentials(password: Data("secret".utf8)), for: "h")
        XCTAssertEqual(cache["h"]?.password, Data("secret".utf8))
        cache.forget("h")
        XCTAssertNil(cache["h"])
        XCTAssertFalse(cache.savedPasswordRejected("h"))
    }

    func testRejectedLoginStaysRejectedUntilAccepted() {
        var cache = CredentialCache()
        cache.store(Credentials(password: Data("secret".utf8)), for: "h")
        cache.rejectLogin("h")
        XCTAssertNil(cache["h"])
        XCTAssertTrue(cache.savedPasswordRejected("h"))
        cache.forgetAll()
        XCTAssertTrue(cache.savedPasswordRejected("h"))
        cache.acceptSavedPassword("h")
        XCTAssertFalse(cache.savedPasswordRejected("h"))
    }

    func testForgetAll() {
        var cache = CredentialCache()
        cache.store(Credentials(passphrase: "a"), for: "a"); cache.store(Credentials(passphrase: "b"), for: "b")
        cache.forgetAll()
        XCTAssertNil(cache["a"]); XCTAssertNil(cache["b"])
    }
}
