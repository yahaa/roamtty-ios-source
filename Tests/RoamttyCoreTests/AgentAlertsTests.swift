import XCTest
@testable import RoamttyCore

final class AgentAlertsTests: XCTestCase {
    private func status(_ state: AgentStatus.State, tool: String = "", detail: String = "", task: String = "fix the bug",
                        worked: Int64? = nil, reply: String = "") -> AgentStatus {
        AgentStatus(state: state, agent: "claude", tool: tool, detail: detail, task: task, directory: "/srv", workedSeconds: worked, reply: reply)
    }
    private var working: AgentStatus { status(.working, tool: "Bash", detail: "npm test") }
    private var waiting: AgentStatus { status(.waiting, tool: "Bash", detail: "./gradlew lint") }
    private var done: AgentStatus { status(.idle, worked: 720, reply: "All 48 passed") }

    func testARequestForPermissionIsShown() {
        XCTAssertEqual(AgentAlerts.next(working, waiting, shown: nil), .show(.waiting))
        XCTAssertEqual(AgentAlerts.next(nil, waiting, shown: nil), .show(.waiting))
        // The same request polled again is not shown twice; the next one is.
        XCTAssertEqual(AgentAlerts.next(waiting, waiting, shown: .waiting), .keep)
        var next = waiting; next.detail = "git push"
        XCTAssertEqual(AgentAlerts.next(waiting, next, shown: .waiting), .show(.waiting))
    }

    func testWorkingAgainWithdrawsEitherNotification() {
        XCTAssertEqual(AgentAlerts.next(waiting, working, shown: .waiting), .withdraw)
        XCTAssertEqual(AgentAlerts.next(done, working, shown: .done), .withdraw)
        XCTAssertEqual(AgentAlerts.next(nil, working, shown: nil), .keep)
    }

    func testALongTurnThatEndsIsShown() {
        XCTAssertEqual(AgentAlerts.next(working, done, shown: nil), .show(.done))
        // It replaces a request answered on another screen.
        XCTAssertEqual(AgentAlerts.next(waiting, done, shown: .waiting), .show(.done))
        // A whole turn that ran while the app was away still counts.
        var later = done; later.task = "next"; later.workedSeconds = 300
        XCTAssertEqual(AgentAlerts.next(done, later, shown: nil), .show(.done))
    }

    func testAShortTurnOrTheSameTurnAgainIsNot() {
        var short = done; short.workedSeconds = AgentAlerts.minDoneSeconds - 1
        XCTAssertEqual(AgentAlerts.next(working, short, shown: nil), .keep)
        XCTAssertEqual(AgentAlerts.next(waiting, short, shown: .waiting), .withdraw)
        // Only the folder or the age moved.
        var moved = done; moved.directory = "/tmp"; moved.elapsedMillis = 90_000
        XCTAssertEqual(AgentAlerts.next(done, moved, shown: .done), .keep)
    }

    func testAnAgentThatLeftWithdrawsOnlyARequest() {
        XCTAssertEqual(AgentAlerts.next(waiting, nil, shown: .waiting), .withdraw)
        XCTAssertEqual(AgentAlerts.next(done, nil, shown: .done), .keep)
    }

    func testTheSettingChoosesWhichKindsCome() {
        XCTAssertEqual(AgentAlerts.Kind.allCases.map(AgentNotifications.all.allows), [true, true])
        XCTAssertEqual(AgentAlerts.Kind.allCases.map(AgentNotifications.waitingOnly.allows), [true, false])
        XCTAssertEqual(AgentAlerts.Kind.allCases.map(AgentNotifications.off.allows), [false, false])
    }

    func testTheSettingIsSavedAndDefaultsToAll() throws {
        XCTAssertEqual(AppSettings().agentNotifications, .all)
        var settings = AppSettings(); settings.agentNotifications = .waitingOnly
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.agentNotifications, .waitingOnly)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"agentNotifications":"loud"}"#.utf8)).agentNotifications, .all)
    }

    func testTheNotificationSaysWhoWhatAndWhere() {
        XCTAssertEqual(AgentAlerts.title(.waiting, agent: .claude, english: false), "Claude 等你确认")
        XCTAssertEqual(AgentAlerts.title(.done, agent: nil, english: false), "Agent 已完成")
        XCTAssertEqual(AgentAlerts.title(.done, agent: .codex, english: true), "Codex finished")
        XCTAssertEqual(AgentAlerts.text(.waiting, host: "dev", status: waiting, english: false), "dev · ./gradlew lint")
        XCTAssertEqual(AgentAlerts.text(.waiting, host: "dev", status: status(.waiting, tool: "AskUserQuestion"), english: false), "dev · AskUserQuestion")
        XCTAssertEqual(AgentAlerts.text(.done, host: "macbook", status: done, english: false), "macbook · 12 分钟 · All 48 passed")
        var long = done; long.workedSeconds = 3900; long.reply = ""
        XCTAssertEqual(AgentAlerts.text(.done, host: "macbook", status: long, english: false), "macbook · 1 小时 5 分钟")
        long.reply = "**Fixed** the `build`"
        XCTAssertEqual(AgentAlerts.text(.done, host: "macbook", status: long, english: true), "macbook · 1 h 5 min · Fixed the build")
    }
}
