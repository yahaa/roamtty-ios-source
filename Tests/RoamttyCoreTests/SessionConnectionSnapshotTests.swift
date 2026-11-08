import XCTest
@testable import RoamttyCore

final class SessionConnectionSnapshotTests: XCTestCase {
    private final class Session { let id = "restored-session" }
    private final class Connection { var received = Data() }

    func testOperationUsesCapturedConnection() throws {
        let session = Session(), original = Connection(), otherHost = Connection()
        let target = SessionConnectionSnapshot(session: session, connection: original)
        let resolved = try target.resolve(currentSession: session, currentConnection: original, connected: true)
        resolved.received.append(Data("attachment".utf8))
        XCTAssertEqual(original.received, Data("attachment".utf8))
        XCTAssertTrue(otherHost.received.isEmpty)
    }

    func testReplacementSessionWithSameRecordIDCannotClaimOldWork() {
        let original = Session(), replacement = Session(), connection = Connection()
        XCTAssertEqual(original.id, replacement.id)
        let target = SessionConnectionSnapshot(session: original, connection: connection)
        XCTAssertThrowsError(try target.resolve(currentSession: replacement, currentConnection: connection, connected: true))
        XCTAssertThrowsError(try target.resolve(currentSession: nil, currentConnection: connection, connected: true))
    }

    func testClosedOrReplacedConnectionCannotClaimOldWork() {
        let session = Session(), original = Connection(), replacement = Connection()
        let target = SessionConnectionSnapshot(session: session, connection: original)
        XCTAssertThrowsError(try target.resolve(currentSession: session, currentConnection: replacement, connected: true))
        XCTAssertThrowsError(try target.resolve(currentSession: session, currentConnection: original, connected: false))
        XCTAssertThrowsError(try target.resolve(currentSession: session, currentConnection: nil, connected: true))
    }

    func testMissingOrReleasedOwnerNeverAcquiresLaterConnection() {
        var session: Session? = Session()
        let connection = Connection()
        let target = SessionConnectionSnapshot(session: session, connection: connection)
        let unavailable = SessionConnectionSnapshot(session: session, connection: Optional<Connection>.none)
        XCTAssertThrowsError(try unavailable.resolve(currentSession: session, currentConnection: connection, connected: true))
        session = nil
        XCTAssertNil(target.session)
        XCTAssertThrowsError(try target.resolve(currentSession: Session(), currentConnection: connection, connected: true))
    }
}
