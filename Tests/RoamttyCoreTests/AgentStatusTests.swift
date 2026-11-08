import Foundation
import XCTest
@testable import RoamttyCore

/// Ports Android's AgentStatusTest, AgentLaunchTest (hooks), SessionGroupsTest and SessionTransportTagsTest.
final class AgentStatusTests: XCTestCase {
    func testReadsTheStateTheToolAndTheTask() throws {
        let status = try XCTUnwrap(AgentStatus.parse("claude|working|1000|claude|Bash|npm test|fix the bug\n1042\n"))
        XCTAssertEqual(status.state, .working)
        XCTAssertEqual(status.tool, "Bash")
        XCTAssertEqual(status.detail, "npm test")
        XCTAssertEqual(status.task, "fix the bug")
        XCTAssertEqual(status.elapsedMillis, 42_000)
    }

    /// The list keeps what an agent reported last across launches, until its host answers again.
    func testALastReportSurvivesBeingSaved() throws {
        let status = AgentStatus(state: .idle, agent: "claude", task: "fix the bug", elapsedMillis: 42_000, directory: "~/app",
                                 workedSeconds: 75, reply: "Done.")
        XCTAssertEqual(try JSONDecoder().decode(AgentStatus.self, from: JSONEncoder().encode(status)), status)
    }

    func testAnAgentThatLeftLeavesNothing() {
        XCTAssertNil(AgentStatus.parse("zsh|working|1000|claude|Bash|x|task\n1042"))
        XCTAssertNil(AgentStatus.parse("-bash|idle|1000|claude|||task\n1042"))
        // Codex and Grok run under their launcher.
        XCTAssertEqual(AgentStatus.parse("sh|idle|1000|codex|||task\n1042")?.state, .idle)
        // On macOS /bin/sh is bash, so the launcher shows as "bash".
        XCTAssertEqual(AgentStatus.parse("bash|idle|1000|codex|||task\n1042")?.state, .idle)
        XCTAssertEqual(AgentStatus.parse("bash|working|1000|grok|||task\n1042")?.state, .working)
    }

    func testNoReportsOrUnknownStatesMeanNoStatus() {
        XCTAssertNil(AgentStatus.parse(nil))
        XCTAssertNil(AgentStatus.parse("claude|||||\n1042"))
        XCTAssertNil(AgentStatus.parse("claude|sleeping|1|claude|||\n2"))
        XCTAssertNil(AgentStatus.parse("garbage"))
    }

    func testHalfACharacterAtTheEndOfTheTaskIsDropped() {
        XCTAssertEqual(AgentStatus.parse("node|idle|1|claude|||修复\u{FFFD}\n2")?.task, "修复")
    }

    func testClockSkewNeverGivesNegativeTime() {
        XCTAssertEqual(AgentStatus.parse("node|waiting|50|claude|||\n40")?.elapsedMillis, 0)
    }

    func testHookSettingsNeedNoShellQuoting() {
        let json = AgentHooks.claudeSettings
        XCTAssertFalse(json.contains("'") || json.contains("\\"))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"] {
            XCTAssertTrue(json.contains("\"\(event)\""), event)
        }
        XCTAssertTrue(json.contains("sh ~/.roamtty/agent-hook.sh claude prompt"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testCodexTrustsItsHooksByTheHashCodexComputes() {
        // Codex 0.162 recorded these when its "Trust all" trusted the hooks, given with a 3 s timeout.
        let log = "sh /tmp/claude-1000/-home-v-work-roamtty/50a4e347-10a1-4c15-b785-1225642298e2/scratchpad/log.sh"
        XCTAssertEqual(AgentHooks.codexHookHash(eventKey: "stop", command: log + " stop"), "sha256:4f1b2dd4a5d87385b74e8495a0d38d8a4b88cccbd10f8b0b1efe806677c4e1ad")
        XCTAssertEqual(AgentHooks.codexHookHash(eventKey: "interrupt", command: log + " stop"), "sha256:9d388d80df6c839ca91447ad8ec4ad0b9b42f961b8d1d704b77381cd7e484800")
        let launcher = AgentHooks.codexLauncher
        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh"))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"] {
            XCTAssertTrue(launcher.contains("-c 'hooks.\(event)=[{hooks=[{type=\"command\",command=\"sh ~/.roamtty/agent-hook.sh codex "), event)
        }
        XCTAssertTrue(launcher.contains("trust stop " + AgentHooks.codexHookHash(eventKey: "stop", command: "sh ~/.roamtty/agent-hook.sh codex stop")))
        XCTAssertTrue(launcher.contains("  \"$@\"\nstatus=$?\nsh ~/.roamtty/agent-hook.sh codex end </dev/null\nexit $status\n"))
    }

    func testGrokHooksActOnlyForAGrokStartedByTheApp() {
        let launcher = AgentHooks.grokLauncher
        XCTAssertTrue(launcher.contains("\"StopCancelled\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh grok stop\"}]}]"))
        XCTAssertTrue(launcher.contains("export ROAMTTY_AGENT=grok\ngrok \"$@\"\n"))
        XCTAssertTrue(AgentHooks.script.contains("[ \"$ROAMTTY_AGENT\" = grok ]"))
        XCTAssertTrue(AgentHooks.script.hasPrefix("#!/bin/sh"))
    }

    func testAgentsStartWithTheirHooks() {
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "/home/v/app").commandLine, "cd -- '/home/v/app' && claude --settings ~/.roamtty/claude-hooks.json")
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "~").commandLine, "claude --settings ~/.roamtty/claude-hooks.json")
        XCTAssertEqual(AgentLaunch(agent: .grok, directory: "~/work/app").commandLine, "cd -- ~/'work/app' && ~/.roamtty/grok")
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/srv/it's $(x) dir").commandLine, "cd -- '/srv/it'\\''s $(x) dir' && ~/.roamtty/codex")
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/a", mode: .readOnly).commandLine, "cd -- '/a' && ~/.roamtty/codex --sandbox read-only")
        XCTAssertEqual(AgentLaunch(agent: .grok, directory: "/a", mode: .yolo).commandLine, "cd -- '/a' && ~/.roamtty/grok --always-approve")
        XCTAssertEqual(AgentHooks.hostFile(.claude).name, "claude-hooks.json")
        XCTAssertTrue(AgentHooks.hostFile(.codex).executable)
    }

    func testRestoredSessionsTellTheirAgentByTitle() {
        XCTAssertEqual(CodingAgent.fromTitle(AgentLaunch(agent: .grok, directory: "/srv/roamtty").title), .grok)
        XCTAssertEqual(CodingAgent.fromTitle("Codex · roamtty"), .codex)
        XCTAssertEqual(CodingAgent.fromTitle("Claude Code · roamtty"), .claude)
        XCTAssertNil(CodingAgent.fromTitle("部署脚本"))
        XCTAssertNil(CodingAgent.fromTitle("Grokking notes"))
        XCTAssertEqual(CodingAgent.fromCommand("claude"), .claude)
        XCTAssertNil(CodingAgent.fromCommand("gemini"))
    }

    func testActivityShowsWhatTheAgentRuns() throws {
        let working = try XCTUnwrap(AgentStatus.parse("sh|working|1|codex|Bash|make test|t\n2"))
        func with(_ change: (inout AgentStatus) -> Void) -> AgentStatus { var copy = working; change(&copy); return copy }
        XCTAssertEqual(agentActivity(working), "Running make test")
        XCTAssertEqual(agentActivity(with { $0.tool = "run_terminal_command"; $0.detail = "sleep 6" }), "Running sleep 6")
        XCTAssertEqual(agentActivity(with { $0.tool = "Read"; $0.detail = "src/a.kt" }), "Read src/a.kt")
        XCTAssertEqual(agentActivity(with { $0.tool = "WebSearch"; $0.detail = "" }), "WebSearch")
        XCTAssertEqual(agentActivity(with { $0.state = .waiting; $0.tool = ""; $0.detail = "Claude needs your permission to use Bash" }), "Claude needs your permission to use Bash")
        XCTAssertEqual(agentActivity(with { $0.tool = ""; $0.detail = "" }), "")
        XCTAssertEqual(agentActivity(with { $0.state = .idle }), "")
        XCTAssertEqual(agentActivity(nil), "")
    }

    func testReadsTheReplyOfAnIdleAgentOnly() throws {
        let idle = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||75|fix the bug|All fixed.\n/home/v\n1042\n"))
        XCTAssertEqual(idle.task, "fix the bug")
        XCTAssertEqual(idle.reply, "All fixed.")
        XCTAssertEqual(idle.workedSeconds, 75)
        XCTAssertEqual(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug|old\n1042")?.reply, "")
        XCTAssertEqual(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug|old\n1042")?.task, "fix the bug")
    }

    func testAReplyReadsAsPlainText() {
        XCTAssertEqual(replyPreview("## Fixed **the parser** in `AgentStatus.kt`, see [docs](https://x.y/z); ready   to merge."),
                       "Fixed the parser in AgentStatus.kt, see docs; ready to merge.")
        XCTAssertEqual(replyPreview("- Two branches - both fine"), "Two branches - both fine")
        XCTAssertEqual(replyPreview("__init__.py updated"), "__init__.py updated")
    }

    func testAStoppedTurnSaysHowLongItWorked() throws {
        let idle = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||75|fix the bug\n/home/v\n1042\n"))
        XCTAssertEqual(idle.workedSeconds, 75)
        XCTAssertEqual(idle.task, "fix the bug")
        XCTAssertEqual(idle.directory, "/home/v")
        XCTAssertNil(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug\n1042")?.workedSeconds)
        XCTAssertNil(AgentStatus.parse("claude|idle|1000|claude||||fix the bug\n1042")?.workedSeconds)
        XCTAssertNil(AgentStatus.parse("claude|idle|1000|claude|||fix the bug\n1042")?.workedSeconds)
    }

    func testReadsThePanesFolderBeforeTheClock() throws {
        let status = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||\n/home/v/roamtty\n1042\n"))
        XCTAssertEqual(status.directory, "/home/v/roamtty")
        XCTAssertEqual(status.elapsedMillis, 42_000)
        XCTAssertEqual(AgentStatus.parse("claude|idle|1000|claude|||\n1042")?.directory, "")
    }

    func testReadsThePanesFolderWithoutAnAgent() {
        XCTAssertNil(AgentStatus.parse("bash||||||\n/home/v/work\n1042"))
        XCTAssertEqual(AgentStatus.directory("bash||||||\n/home/v/work\n1042"), "/home/v/work")
        XCTAssertEqual(sessionListPath("/home/v/work", username: "v"), "~/work")
        XCTAssertEqual(AgentStatus.directory("bash||||||\n1042"), "")
        XCTAssertEqual(AgentStatus.directory(nil), "")
        XCTAssertEqual(sessionListPath("", username: "v"), "")
    }

    func testListTitleIsTheTaskThenTheAgentAndFolderThenTheTitle() throws {
        let working = try XCTUnwrap(AgentStatus.parse("claude|working|1|claude|||fix the bug\n/home/v/roamtty\n2"))
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: working, agent: .claude, username: "v"), "fix the bug")
        var fresh = working; fresh.task = ""
        func at(_ directory: String) -> AgentStatus { var copy = fresh; copy.directory = directory; return copy }
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: fresh, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListPath(fresh, username: "v"), "~/roamtty")
        XCTAssertEqual(sessionListTitle("", status: at("/Users/v"), agent: .claude, username: "v"), "Claude · ~")
        XCTAssertEqual(sessionListTitle("", status: at("/"), agent: .codex, username: "v"), "Codex · /")
        XCTAssertEqual(sessionListTitle("", status: at("/srv/web"), agent: nil, username: "v"), "web")
        XCTAssertEqual(sessionListPath(at("/srv/web"), username: "v"), "/srv/web")
        XCTAssertEqual(sessionListPath(at("/root/x"), username: "root"), "~/x")
        XCTAssertEqual(sessionListPath(nil as AgentStatus?, username: "v"), "")
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: nil, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListTitle("Claude Code · roamtty", status: nil, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListTitle("部署脚本", status: nil, agent: .claude, username: "v"), "部署脚本")
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: nil, agent: nil, username: "v"), "Claude · roamtty")
    }

    func testGroupsByWhatTheAgentDoesWhileConnected() {
        func status(_ state: AgentStatus.State) -> AgentStatus { AgentStatus(state: state, agent: "claude") }
        XCTAssertEqual(sessionGroup(connected: true, status: status(.waiting)), .waiting)
        XCTAssertEqual(sessionGroup(connected: true, status: status(.working)), .working)
        XCTAssertEqual(sessionGroup(connected: true, status: status(.idle)), .done)
        XCTAssertEqual(sessionGroup(connected: true, status: nil), .other)
        XCTAssertEqual(sessionGroup(connected: false, status: status(.waiting)), .other)
    }

    func testDurationsStayShortAndUnbroken() {
        XCTAssertEqual(shortDuration(12), "12s")
        XCTAssertEqual(shortDuration(174), "2m54s")
        XCTAssertEqual(shortDuration(245), "4m05s")
        XCTAssertEqual(shortDuration(3900), "1h05m")
        XCTAssertEqual(agoText(30, english: false), "刚刚")
        XCTAssertEqual(agoText(200, english: false), "3分钟前")
        XCTAssertEqual(agoText(7300, english: false), "2小时前")
        XCTAssertEqual(agoText(90_000, english: false), "1天前")
        XCTAssertEqual(agoText(200, english: true), "3m ago")
    }

    func testResumableSessionNamesItsMultiplexerAndMoshWhileMoshCarriesIt() {
        XCTAssertEqual(sessionTransportTags(mode: .tmux, mosh: true), ["tmux", "mosh"])
        XCTAssertEqual(sessionTransportTags(mode: .tmux, mosh: false), ["tmux"])
        XCTAssertEqual(sessionTransportTags(mode: .shell, mosh: false), [])
        XCTAssertEqual(sessionTransportTags(mode: .shell, mosh: true), ["mosh"])
    }

    func testTmuxCommandsAreSingleQuotedForSh() {
        let status = RemoteCommands.agentStatus("roamtty-abc;rm")
        XCTAssertTrue(status.hasPrefix("/bin/sh -c '"))
        XCTAssertTrue(status.contains("-t roamtty-abcrm "))
        XCTAssertTrue(status.contains("#{@roamtty_reply}"))
        // sshd on macOS runs commands without a UTF-8 locale: tmux would print each non-ASCII character as "_".
        XCTAssertTrue(status.contains("tmux -u display-message -p -t roamtty-abcrm \"#{pane_current_command}"))
        XCTAssertTrue(status.contains("tmux -u display-message -p -t roamtty-abcrm \"#{pane_current_path}"))
        XCTAssertTrue(RemoteCommands.restartPane("x").contains("respawn-pane -k ${d:+-c \"$d\"} -t x"))
        XCTAssertNil(RemoteCommands.writeHostFile("../evil"))
        XCTAssertNil(RemoteCommands.writeHostFile(".hidden"))
        XCTAssertEqual(RemoteCommands.writeHostFile("codex", executable: true),
                       "/bin/sh -c 'mkdir -p \"$HOME/.roamtty\" && cat > \"$HOME/.roamtty/codex\" && chmod +x \"$HOME/.roamtty/codex\"'")
    }

    // MARK: The hook script against a stand-in tmux

    private final class HookFixture {
        let dir: URL
        let script: URL
        init(listPanes: Bool = false) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hook-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            script = dir.appendingPathComponent("agent-hook.sh")
            try AgentHooks.script.write(to: script, atomically: true, encoding: .utf8)
            // A stand-in tmux keeping each option in a file: `show-options -qv -t P NAME`, `set-option -q -t P NAME VALUE`,
            // `set-option -u -q -t P NAME`.
            var tmux = "#!/bin/sh\ncase \"$1\" in\n  show-options) cat \"\(dir.path)/opt$5\" 2>/dev/null ;;\n" +
                "  set-option) if [ \"$2\" = -u ]; then rm -f \"\(dir.path)/opt$6\"; else printf '%s' \"$6\" > \"\(dir.path)/opt$5\"; fi ;;\n"
            if listPanes { tmux += "  list-panes) printf '%%1 %s\\n' \"$(cat \"\(dir.path)/opt@roamtty_session\" 2>/dev/null)\" ;;\n" }
            // Every tmux session lives but one.
            tmux += "  has-session) [ \"$3\" != =gone ] ;;\n"
            tmux += "esac\n"
            let tool = dir.appendingPathComponent("tmux")
            try tmux.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
        func run(_ arguments: [String], json: String, pane: String?, grok: Bool = false) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = dir.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment.removeValue(forKey: "TMUX_PANE")
            if let pane { environment["TMUX_PANE"] = pane }
            if grok { environment["ROAMTTY_AGENT"] = "grok" }
            environment["COLUMNS"] = "20"
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(json.utf8)); try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func hook(_ event: String, _ json: String = "{}", agent: String = "claude", grok: Bool = false) throws {
            try run([script.path, agent, event], json: json, pane: "%1", grok: grok)
        }
        func option(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent("opt" + name), encoding: .utf8) }
        func reported() -> String {
            let fields = (option("@roamtty_agent") ?? "").components(separatedBy: "|")
            return fields.count >= 5 ? "\(fields[0])|\(fields[3])|\(fields[4])" : ""
        }
    }

    func testAFinishedToolStaysShownUntilTheNextOneOrTheTurnsEnd() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"fix the bug"}"#)
        XCTAssertEqual(fixture.reported(), "working||")
        try fixture.hook("tool", #"{"tool_name":"Bash","tool_input":{"command":"make test"}}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make test")
        try fixture.hook("post")
        XCTAssertEqual(fixture.reported(), "working|Bash|make test")
        try fixture.hook("tool", #"{"tool_name":"Read","tool_input":{"file_path":"src/a.kt"}}"#)
        try fixture.hook("post")
        XCTAssertEqual(fixture.reported(), "working|Read|src/a.kt")
        XCTAssertNil(fixture.option("@roamtty_worked"), "no turn has stopped yet")
        try fixture.hook("stop")
        XCTAssertEqual(fixture.reported(), "idle||")
        let worked = try XCTUnwrap(fixture.option("@roamtty_worked").flatMap(Int.init))
        XCTAssertTrue((0...60).contains(worked))
        try fixture.hook("prompt", #"{"prompt":"again"}"#)
        XCTAssertNil(fixture.option("@roamtty_worked"))
        try fixture.hook("end")
        XCTAssertNil(fixture.option("@roamtty_turn"))
    }

    func testAStoppedTurnLeavesTheStartOfItsAnswerUntilTheNextPrompt() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"fix the bug"}"#, agent: "claude", grok: true)
        try fixture.hook("stop", #"{"stop_hook_active":false,"last_assistant_message":"**Fixed** it.\nTests pass | 3/3"}"#, agent: "claude", grok: true)
        XCTAssertEqual(fixture.option("@roamtty_reply"), "**Fixed** it. Tests pass / 3/3")
        try fixture.hook("prompt", #"{"prompt":"again"}"#, agent: "claude", grok: true)
        XCTAssertNil(fixture.option("@roamtty_reply"))
        try fixture.hook("stop", #"{"stopHookActive":false,"lastAssistantMessage":"Done."}"#, agent: "grok", grok: true)
        XCTAssertEqual(fixture.option("@roamtty_reply"), "Done.")
        try fixture.hook("end", agent: "grok", grok: true)
        XCTAssertNil(fixture.option("@roamtty_reply"))
    }

    func testATurnWaitingForBackgroundWorkGoesOnUntilThatWorkWakesItAndEnds() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"run the suite"}"#)
        let turn = fixture.option("@roamtty_turn")
        // Claude Code's Stop as it comes while a background shell runs (an answer quoting the key changes nothing).
        try fixture.hook("stop", #"{"stop_hook_active":false,"last_assistant_message":"started \"background_tasks\":[{}]","#
            + #""background_tasks":[{"id":"b1","type":"shell","status":"running","description":"Run the suite","command":"make test"}],"session_crons":[]}"#)
        XCTAssertEqual(fixture.reported(), "working|Background|make test")
        XCTAssertNil(fixture.option("@roamtty_worked"))
        // Idle for a minute only to look at: it stays at work.
        try fixture.hook("notify", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#)
        XCTAssertEqual(fixture.reported(), "working|Background|make test")
        // The work ends and wakes it: the same turn and task go on, then end.
        try fixture.hook("prompt", #"{"prompt":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}"#)
        XCTAssertEqual(fixture.option("@roamtty_turn"), turn)
        XCTAssertEqual(fixture.option("@roamtty_task"), "run the suite")
        try fixture.hook("stop", #"{"last_assistant_message":"All green.","background_tasks":[],"session_crons":[]}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertNotNil(fixture.option("@roamtty_worked"))
        XCTAssertEqual(fixture.option("@roamtty_reply"), "All green.")
        // Grok names it in camelCase; a subagent says what it does. Only a scheduled wakeup is no work in flight.
        try fixture.hook("prompt", #"{"prompt":"review"}"#, agent: "grok", grok: true)
        try fixture.hook("stop",
            #"{"lastAssistantMessage":"spawned","backgroundTasks":[{"id":"a1","type":"subagent","status":"running","description":"Review the diff","agentType":"general"}],"sessionCrons":[]}"#,
            agent: "grok", grok: true)
        XCTAssertEqual(fixture.reported(), "working|Background|Review the diff")
        try fixture.hook("stop", #"{"lastAssistantMessage":"ok","backgroundTasks":[],"sessionCrons":[{"id":"c1","schedule":"*/5 * * * *"}]}"#, agent: "grok", grok: true)
        XCTAssertEqual(fixture.reported(), "idle||")
        // A new prompt of the user's while work runs in the background starts a turn of its own.
        try fixture.hook("stop", #"{"background_tasks":[{"id":"b2","type":"shell","status":"running","command":"sleep 60"}]}"#)
        try FileManager.default.removeItem(at: fixture.dir.appendingPathComponent("opt@roamtty_turn"))
        try fixture.hook("prompt", #"{"prompt":"something else"}"#)
        XCTAssertNotNil(fixture.option("@roamtty_turn"), "the user's prompt starts a turn")
        XCTAssertEqual(fixture.option("@roamtty_task"), "something else")
    }

    func testASessionSentToTheBackgroundStillReportsToItsPane() throws {
        let fixture = try HookFixture(listPanes: true)
        let id = "32c4597e-61a4-4ddd-ba0a-51f68f9d1148"
        // In the pane, or (pane = nil) under a process resuming the session, as Claude Code's background job runs.
        func hook(_ event: String, _ json: String, pane: String?, resumed: String = id) throws {
            if pane != nil {
                try fixture.run([fixture.script.path, "claude", event], json: json, pane: pane)
            } else {
                try fixture.run(["-c", "sh '\(fixture.script.path)' claude \(event); :", "--resume", "/p/\(resumed).jsonl", "--reply-on-resume"], json: json, pane: nil)
            }
        }
        try hook("tool", #"{"session_id":"\#(id)","tool_name":"Bash","tool_input":{"command":"make"}}"#, pane: "%1")
        XCTAssertEqual(fixture.option("@roamtty_session"), id)
        try hook("post", #"{"session_id":"forked"}"#, pane: nil)
        try hook("stop", #"{"session_id":"forked"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "idle||")
        try hook("prompt", #"{"session_id":"forked","prompt":"next"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "working||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "next")
        try hook("end", #"{"session_id":"forked"}"#, pane: nil)
        try hook("start", #"{"session_id":"cleared"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_session"), id)
        try hook("prompt", #"{"session_id":"other","prompt":"elsewhere"}"#, pane: nil, resumed: "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(fixture.reported(), "idle||")
    }

    func testABackgroundJobReportsToTheTmuxSessionItsSettingsName() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ json: String) throws { try fixture.run([fixture.script.path, "claude", event, "roamtty-a"], json: json, pane: nil) }
        try fixture.run([fixture.script.path, "claude", "start", "roamtty-a"], json: #"{"session_id":"pane"}"#, pane: "%1")
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_session"), "pane")
        // A spare process starts before any task: nothing changes until a job has one.
        try job("start", #"{"session_id":"spare"}"#)
        XCTAssertEqual(fixture.option("@roamtty_owner"), "pane")
        try job("prompt", #"{"session_id":"job","prompt":"fix it"}"#)
        XCTAssertEqual(fixture.reported(), "working||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "fix it")
        try job("tool", #"{"session_id":"job","tool_name":"Bash","tool_input":{"command":"make"}}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make")
        XCTAssertEqual(fixture.option("@roamtty_session"), "pane", "a job's id never replaces the pane's")
        // The session left in the pane has nothing to say about the job's work.
        try fixture.run([fixture.script.path, "claude", "notify", "roamtty-a"], json: #"{"session_id":"pane","notification_type":"idle_prompt"}"#, pane: "%1")
        XCTAssertEqual(fixture.reported(), "working|Bash|make")
        try job("notify", #"{"session_id":"job","notification_type":"permission_prompt","message":"needs permission"}"#)
        XCTAssertEqual(fixture.reported(), "waiting|Bash|make")
        try job("post", #"{"session_id":"job"}"#)
        try job("stop", #"{"session_id":"job","last_assistant_message":"done"}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_reply"), "done")
    }

    func testAJobThatEndsMidTurnStopsTheWorkButLeavesThePanesOptions() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ json: String) throws { try fixture.run([fixture.script.path, "claude", event, "s"], json: json, pane: nil) }
        try job("prompt", #"{"session_id":"job","prompt":"long"}"#)
        try job("tool", #"{"session_id":"job","tool_name":"Bash","tool_input":{"command":"make"}}"#)
        try job("end", #"{"session_id":"other"}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make", "another session's end says nothing about this work")
        try job("end", #"{"session_id":"job"}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "long")
    }

    func testOnlyTheSessionThatReportedLastSaysTheWorkStopped() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ id: String) throws { try fixture.run([fixture.script.path, "claude", event, "s"], json: #"{"session_id":"\#(id)","prompt":"go"}"#, pane: nil) }
        try job("prompt", "a")
        try job("prompt", "b")
        try job("stop", "a")
        XCTAssertEqual(fixture.reported(), "working||")
        try job("stop", "b")
        XCTAssertEqual(fixture.reported(), "idle||")
    }

    func testAJobLeavesAPaneRunningAnotherAgentAndAnEndedSessionAlone() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"codex work"}"#, agent: "codex")
        let codex = fixture.option("@roamtty_agent")
        try fixture.run([fixture.script.path, "claude", "prompt", "s"], json: #"{"session_id":"job","prompt":"not yours"}"#, pane: nil)
        XCTAssertEqual(fixture.option("@roamtty_agent"), codex)
        XCTAssertEqual(fixture.option("@roamtty_task"), "codex work")

        let ended = try HookFixture()
        try ended.run([ended.script.path, "claude", "prompt", "gone"], json: #"{"session_id":"job","prompt":"late"}"#, pane: nil)
        XCTAssertNil(ended.option("@roamtty_agent"))
    }

    func testCodexKeepsReportingWhateverSessionIdsItSends() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"session_id":"a","prompt":"go"}"#, agent: "codex")
        try fixture.hook("stop", #"{"session_id":"b"}"#, agent: "codex")
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertNil(fixture.option("@roamtty_owner"))
    }

    func testPruningKeepsSettingsOfLiveSessionsAndRecentFiles() throws {
        let fixture = try HookFixture()
        let folder = fixture.dir.appendingPathComponent(".roamtty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        for (name, date) in [("claude-hooks-gone.json", old), ("claude-hooks-live.json", old), ("claude-hooks.json", old), ("claude-hooks-new.json", Date())] {
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        // The stand-in tmux takes `has-session -t =name` as $3; a pruned name other than "gone" counts as alive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooks.pruneSettings]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.dir.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["HOME"] = fixture.dir.path
        process.environment = environment
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["claude-hooks-live.json", "claude-hooks-new.json", "claude-hooks.json"])
    }

    func testClaudeStartedInATmuxSessionNamesItInItsSettings() {
        let launch = AgentLaunch(agent: .claude, directory: "/home/v/app")
        XCTAssertEqual(launch.commandLine(session: "roamtty-AB12"), "cd -- '/home/v/app' && claude --settings ~/.roamtty/claude-hooks-roamtty-AB12.json")
        let file = AgentHooks.hostFile(.claude, session: "roamtty-AB12")
        XCTAssertEqual(file.name, "claude-hooks-roamtty-AB12.json")
        XCTAssertFalse(file.executable)
        XCTAssertTrue(file.content.contains(#""command":"sh ~/.roamtty/agent-hook.sh claude stop roamtty-AB12""#))
        // Without a tmux session, or with a name that cannot go into a command as it is, as before.
        for session in [nil, "", "a b", "a;b", "会话"] as [String?] {
            XCTAssertEqual(launch.commandLine(session: session), launch.commandLine)
            XCTAssertEqual(AgentHooks.hostFile(.claude, session: session).name, "claude-hooks.json")
        }
        XCTAssertEqual(AgentHooks.hostFile(.claude).content, AgentHooks.claudeSettings)
        // Other agents have one launcher and report from inside the pane.
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "~").commandLine(session: "s"), AgentLaunch(agent: .codex, directory: "~").commandLine)
        XCTAssertEqual(AgentHooks.hostFile(.codex, session: "s").name, "codex")
    }

    func testAStatusThatOnlyAgedIsTheSameButARestartedOneIsNot() {
        let working = AgentStatus(state: .working, agent: "claude", tool: "Bash", elapsedMillis: 10_000)
        var aged = working; aged.elapsedMillis = 13_200
        XCTAssertTrue(AgentStatus.sameExceptAge(working, aged, after: 3))
        var restarted = working; restarted.elapsedMillis = 400
        XCTAssertFalse(AgentStatus.sameExceptAge(working, restarted, after: 3))
        // A turn that restarted just after the last poll went back by less than the slack, but it is a new state.
        var young = working; young.elapsedMillis = 1_000
        var restartedYoung = working; restartedYoung.elapsedMillis = 0
        XCTAssertFalse(AgentStatus.sameExceptAge(young, restartedYoung, after: 3))
        var otherTool = aged; otherTool.tool = "Edit"
        XCTAssertFalse(AgentStatus.sameExceptAge(working, otherTool, after: 3))
        XCTAssertFalse(AgentStatus.sameExceptAge(working, nil, after: 3))
        XCTAssertFalse(AgentStatus.sameExceptAge(nil, working, after: 3))
        XCTAssertTrue(AgentStatus.sameExceptAge(nil, nil, after: 3))
    }
}
