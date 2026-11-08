import Foundation
import XCTest
@testable import RoamttyCore

final class RemoteCommandsTests: XCTestCase {
    func testAgentLaunchQuotesDirectoryAndMatchesAndroidModes() {
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/work/a'b", mode: .readOnly).commandLine, "cd -- '/work/a'\\''b' && ~/.roamtty/codex --sandbox read-only")
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "~/work dir/", mode: .yolo).commandLine,
            "cd -- ~/'work dir' && claude --dangerously-skip-permissions --settings ~/.roamtty/claude-hooks.json")
        XCTAssertEqual(AgentLaunch(agent: .grok, directory: "~").commandLine, "~/.roamtty/grok")
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/work/demo/").title, "Codex · demo")
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "/").title, "Claude · /")
        XCTAssertFalse(StartDirectory.isSupported("/work\u{1b}[31m"))
        XCTAssertEqual(StartDirectory.remember(recent: ["/a/", "/b", "~"], directory: "/b/"), ["/b", "/a"])
        XCTAssertEqual(CodingAgent.from(nil), .codex)
        XCTAssertEqual(AgentMode.from("YOLO"), .yolo)
    }

    func testHistoryRejectsControlsRanksRecentAndSubmitsOutsidePasteMarkers() throws {
        let commands = ShellHistoryCommands.extractCommands("#1234\nls\n\n git status \nls\nbad\u{1b}[m\n", zshStyle: false)
        XCTAssertEqual(ShellHistoryCommands.rankByRecency(commands), ["ls", "git status"])
        XCTAssertEqual(ShellHistoryCommands.extractCommands(": 123:0;git status\n: 124:1;echo hi", zshStyle: true), ["git status", "echo hi"])
        XCTAssertEqual(ShellHistoryCommands.extractCommands("partial\nls\n", zshStyle: false, skipFirstLine: true), ["ls"])
        XCTAssertEqual(ShellHistoryCommands.mergeRecent(["pwd", "ls"], saved: ["ls", "git status"]), ["pwd", "ls", "git status"])
        XCTAssertEqual(ShellHistoryCommands.fuzzyFilter(["git status", "pwd", "git stash"], query: "gsts"), ["git status", "git stash"])
        XCTAssertEqual(try ShellHistoryCommands.executionInput("echo hi", bracketed: true), "\u{1b}[200~echo hi\u{1b}[201~\r")
        XCTAssertThrowsError(try ShellHistoryCommands.executionInput("echo hi\nrm file", bracketed: false))
    }

    func testCommonCommandsTryZshOnlyWhenBashHasNoUsableHistory() async throws {
        var reads: [String] = []
        let result = try await ShellHistoryCommands.load { path in
            reads.append(path)
            return path == ".bash_history" ? ("#1234\n", false) : ("cut command\n: 123:0;git status\n: 124:0;ls\n", true)
        }
        XCTAssertEqual(reads, [".bash_history", ".zsh_history"])
        XCTAssertEqual(result?.source, "~/.zsh_history")
        XCTAssertEqual(result?.commands, ["ls", "git status"])
        reads = []
        let bash = try await ShellHistoryCommands.load { path in reads.append(path); return ("pwd\n", false) }
        XCTAssertEqual(reads, [".bash_history"])
        XCTAssertEqual(bash?.commands, ["pwd"])
    }

    func testHostSystemAndPluginMarkersDistinguishFailureFromAbsentTools() {
        XCTAssertNil(HostPluginProbe.parse("command failed"))
        XCTAssertEqual(HostPluginProbe.parse("__ITERMUX_TMUX__=/opt/homebrew/bin/tmux\n__ITERMUX_MOSH__="), [.tmux])
        XCTAssertEqual(HostPluginProbe.parse("__ITERMUX_TMUX__=\n__ITERMUX_MOSH__="), [])
        XCTAssertEqual(HostSystemProbe.parse(unix: "__ITERMUX_KERNEL__\nLinux\n__ITERMUX_OS_RELEASE__\nID=ubuntu\n__ITERMUX_LEGACY_RELEASE__\n"), .UBUNTU)
        XCTAssertEqual(HostSystemProbe.parse(unix: "__ITERMUX_KERNEL__\nLinux\n__ITERMUX_OS_RELEASE__\nID=pop\nID_LIKE=ubuntu\n__ITERMUX_LEGACY_RELEASE__\nCentOS"), .LINUX)
        XCTAssertEqual(HostSystemProbe.parse(unix: "__ITERMUX_KERNEL__\nDarwin\n__ITERMUX_OS_RELEASE__\n"), .MACOS)
        XCTAssertEqual(HostSystemProbe.parse(unix: nil, windows: "\nMicrosoft Windows [Version 10.0]"), .WINDOWS)
        XCTAssertEqual(HostPluginInstaller.classify(exitStatus: 3, output: "__ITERMUX_SUDO_FAILED__"), .sudoPassword)
        XCTAssertEqual(HostPluginInstaller.classify(exitStatus: 0, output: "__ITERMUX_INSTALL_DONE__"), .installed)
    }

    #if os(Linux) || os(macOS)
    func testShellQuotingRoundTripsMetacharactersWithoutEvaluation() throws {
        let value = "a'b $(echo injected) `echo injected` ; hi\nnext"
        let result = try run("printf '%s' " + RemoteCommands.shellQuote(value))
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1, value)
    }

    func testShellRunsTheWholeScriptAsOneSHCommand() throws {
        XCTAssertEqual(RemoteCommands.shell("echo 'a'"), "/bin/sh -c 'echo '\\''a'\\'''")
        let result = try run(RemoteCommands.shell("x='it''s'; printf '%s|' \"$x\" $((1 + 2))"))
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1, "its|3|")
    }

    func testTmuxAttachCancelsCopyModeAndKillsOnlyExactName() throws {
        try withCommands(["tmux": """
        case "$1" in
          display-message) printf 'copy-mode';;
          -V) printf 'tmux 3.4';;
          *) printf '%s|' "$@"; printf '\\n';;
        esac
        """]) { environment in
            let attach = try run(RemoteCommands.tmuxAttach("roamtty-ab;rm"), environment: environment)
            XCTAssertEqual(attach.0, 0)
            XCTAssertTrue(attach.1.contains("send-keys|-t|roamtty-abrm|-X|cancel|"))
            XCTAssertTrue(attach.1.contains("-u|new-session|-A|-D|-s|roamtty-abrm|/bin/sh|-c|"), "UTF-8 even without a locale")
            XCTAssertTrue(attach.1.contains("set-option|-t|roamtty-abrm|mouse|on|"))
            let kill = try run(RemoteCommands.killTmux("roamtty"), environment: environment)
            XCTAssertEqual(kill.0, 0)
            XCTAssertTrue(kill.1.contains("has-session|-t|=roamtty|"))
            XCTAssertTrue(kill.1.contains("kill-session|-t|=roamtty|"))
            XCTAssertEqual(try run(RemoteCommands.tmuxProbe, environment: environment).0, 0)
        }
    }

    func testExistingTmuxSessionAttachesWithoutCreatingOrDetachingAndListsSessions() throws {
        try withCommands(["tmux": """
        case "$2" in
          list-sessions) printf '2\\t1\\t1700000000\\tclaude\\tworking|1699999990|claude|Bash|npm test||fix the build|\\twork\\t/home/me/a|b\\n1\\t0\\t1700000500\\tzsh\\t|||\\tmy session\\t/tmp\\n';;
          *) printf '%s|' "$@"; printf '\\n';;
        esac
        """]) { environment in
            let attach = try run(RemoteCommands.tmuxAttach("work;rm", existing: true), environment: environment)
            XCTAssertEqual(attach.0, 0)
            XCTAssertEqual(attach.1, "-u|attach-session|-t|=workrm|;|set-option|-t|workrm|mouse|on|\n")
            let list = try run(RemoteCommands.tmuxSessions, environment: environment)
            XCTAssertEqual(list.0, 0)
            let sessions = TmuxSessionInfo.parse(list.1)
            XCTAssertEqual(sessions.map(\.name), ["my session", "work"])
            XCTAssertEqual(sessions[1], TmuxSessionInfo(name: "work", windows: 2, attached: 1, activity: Date(timeIntervalSince1970: 1_700_000_000), directory: "/home/me/a|b",
                                                        command: "claude", agent: AgentStatus(state: .working, agent: "claude", tool: "Bash", detail: "npm test",
                                                                                              task: "fix the build", directory: "/home/me/a|b")))
            XCTAssertEqual(sessions.map(\.attachable), [false, true])
            XCTAssertEqual(sessions.map(\.idleShell), [true, false])
            XCTAssertNil(sessions[0].agent)
        }
        XCTAssertEqual(TmuxSessionInfo.parse("garbage\nx\t1\t0\tname\n\n"), [])
        // A pane back at its shell leaves an agent's last report behind: it no longer counts; a program still shows.
        let stale = TmuxSessionInfo.parse("1\t0\t0\t-zsh\tidle|0|claude||||task|\tx\t/tmp\n1\t0\t0\tvim\t|||\ty\t\n")
        XCTAssertEqual(stale.map(\.agent), [nil, nil]); XCTAssertEqual(stale.map(\.idleShell), [true, false])
    }

    func testPluginInstallerUsesUserHomebrewOnDarwin() throws {
        try withCommands(["uname": "printf Darwin", "brew": "printf 'brew:'; printf '%s|' \"$@\""]) { environment in
            let result = try run(HostPluginInstaller.script(plugin: .mosh, sudoPassword: nil), environment: environment)
            XCTAssertEqual(result.0, 0)
            XCTAssertTrue(result.1.contains("brew:install|mosh|"))
            XCTAssertEqual(HostPluginInstaller.classify(exitStatus: Int(result.0), output: result.1), .installed)
        }
    }

    private func run(_ command: String, environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Foundation.Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func withCommands(_ scripts: [String: String], body: ([String: String]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, script) in scripts {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        var environment = ProcessInfo.processInfo.environment; environment["PATH"] = directory.path
        try body(environment)
    }
    #endif
}
