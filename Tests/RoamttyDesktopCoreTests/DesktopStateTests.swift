import XCTest
@testable import RoamttyDesktopCore

/// Every row of the plan's §4.3 button table; mirrors Android's DesktopStateTest.
final class DesktopStateTests: XCTestCase {
    private let now = 10 * DesktopProbe.cacheMs
    private func derive(online: Bool = true, connected: Bool = true, os: String = "LINUX",
                        supported: Bool = true, probe: DesktopProbe? = .yes, at: Int64?? = .none,
                        phase: DesktopPhase = .idle) -> DesktopButton {
        let probedAt: Int64? = at ?? (now - 1000)
        return DesktopButton.derive(hostOnline: online, sessionConnected: connected, os: os, osSupported: supported,
                                    probe: probe, probedAt: probedAt, now: now, phase: phase)
    }

    func testHiddenRows() {
        XCTAssertEqual(.hidden, derive(online: false))
        XCTAssertEqual(.hidden, derive(connected: false))
        XCTAssertEqual(.hidden, derive(probe: .no))
        XCTAssertEqual(.hidden, derive(supported: false))
        // Linux waits for a probe; a stale probe counts as none.
        XCTAssertEqual(.hidden, derive(probe: nil, at: .some(nil)))
        XCTAssertEqual(.hidden, derive(at: now - DesktopProbe.cacheMs - 1))
    }

    func testOpenableRows() {
        XCTAssertEqual(.openable, derive())
        XCTAssertEqual(.openable, derive(os: "MACOS", probe: nil, at: .some(nil)))
        XCTAssertEqual(.openable, derive(os: "WINDOWS", probe: nil, at: .some(nil)))
    }

    func testLiveRows() {
        XCTAssertEqual(.connecting, derive(phase: .connecting(step: .start)))
        XCTAssertEqual(.needsAction, derive(phase: .needsAction(needs: ["not-logged-in"])))
        XCTAssertEqual(.needsAction, derive(probe: .nologin))
        XCTAssertEqual(.connected, derive(phase: .connected()))
        XCTAssertEqual(.connected, derive(phase: .connected(paused: true)))
        XCTAssertEqual(.poor, derive(phase: .connected(poor: true)))
        XCTAssertEqual(.recovering, derive(phase: .recovering(sinceMs: 0)))
        // An open desktop keeps its button even after its session card's terminal dropped.
        XCTAssertEqual(.connected, derive(connected: false, phase: .connected()))
    }

    func testProbeDecodes() {
        XCTAssertEqual(.nologin, DesktopProbe.decode("nologin"))
        XCTAssertNil(DesktopProbe.decode("maybe"))
        XCTAssertNil(DesktopProbe.decode(nil))
    }
}
