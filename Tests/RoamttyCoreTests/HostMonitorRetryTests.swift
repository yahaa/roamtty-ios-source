import XCTest
@testable import RoamttyCore

final class HostMonitorRetryTests: XCTestCase {
    func testNetworkFailuresBackOffFiveTimesThenStop() {
        let failure = RoamError.transport("Connection closed")
        XCTAssertEqual((1...6).map { HostMonitorRetry.delay(after: failure, attempt: $0, interactive: false) }, [2, 4, 8, 16, 30, nil])
        XCTAssertEqual(HostMonitorRetry.delay(after: RoamError.timeout, attempt: 1, interactive: false), 2)
        XCTAssertNil(HostMonitorRetry.delay(after: failure, attempt: 0, interactive: false))
    }
    func testRejectedCancelledAndInteractiveLoginsNeverRetry() {
        let errors: [RoamError] = [.authentication, .hostKeyChanged("a", "b"), .rejected, .cancelled, .invalid("Unreadable key")]
        for error in errors { XCTAssertNil(HostMonitorRetry.delay(after: error, attempt: 1, interactive: false)) }
        XCTAssertNil(HostMonitorRetry.delay(after: RoamError.transport("Network failed"), attempt: 1, interactive: true))
    }
    func testFailurePhaseTellsWhyTheLoginStopped() {
        XCTAssertEqual(ConnectionPhase(failure: RoamError.authentication), .authFailed)
        XCTAssertEqual(ConnectionPhase(failure: RoamError.hostKeyChanged("a", "b")), .hostKeyChanged)
        XCTAssertEqual(ConnectionPhase(failure: RoamError.tmuxMissing), .tmuxMissing)
        XCTAssertEqual(ConnectionPhase(failure: RoamError.rejected), .disconnected)
        XCTAssertEqual(ConnectionPhase(failure: RoamError.cancelled), .disconnected)
        XCTAssertEqual(ConnectionPhase(failure: RoamError.timeout), .failed)
        XCTAssertEqual(ConnectionPhase(failure: CocoaError(.fileNoSuchFile)), .failed)
    }
    func testSessionEndWaitsForTheUserOnlyAfterARefusedLogin() {
        for error: RoamError in [.authentication, .hostKeyChanged("a", "b"), .rejected, .cancelled, .tmuxMissing, .sessionLimit, .invalid("x")] {
            XCTAssertEqual(SessionEnd(failure: error, wasConnected: true), .ended)
        }
        for error: Error in [RoamError.timeout, RoamError.transport("closed"), CocoaError(.fileNoSuchFile)] {
            XCTAssertEqual(SessionEnd(failure: error, wasConnected: true), .dropped)
            XCTAssertEqual(SessionEnd(failure: error, wasConnected: false), .unreachable)
        }
    }
}
