import XCTest
import RoamttyCore
@testable import RoamttyTransport

/// The agent hooks, status poll, pane restart and session kill against a real OpenSSH server and tmux.
final class AgentHooksLiveTests: XCTestCase {
    private func connect() throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Set ROAMTTY_TEST_PASSWORD_FILE to run live OpenSSH tests") }
        let password = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(name: "Fixture", address: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test", auth: .password)
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: store) { prompt in
            switch prompt {
            case .verifyHost: return ["trust"]
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        try connection.connect()
        return connection
    }
    private func sh(_ ssh: SSHConnection, _ script: String) throws -> (Int32, String) {
        let result = try ssh.exec("/bin/sh -s", input: Data((RemoteCommands.pathSetup + "\n" + script).utf8), timeout: 15)
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }

    func testHooksReportThroughTmuxAndThePaneRestartsAndEnds() throws {
        let ssh = try connect(); defer { ssh.disconnect() }
        guard try sh(ssh, "command -v tmux").0 == 0 else { throw XCTSkip("tmux is not installed on the fixture") }
        let name = "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        defer { _ = try? sh(ssh, RemoteCommands.killTmux(name)) }

        // The app writes the script and Claude's settings into ~/.roamtty over exec's standard input.
        for (file, content, executable) in [(AgentHooks.scriptName, AgentHooks.script, false), (AgentHooks.hostFile(.claude)
            .name, AgentHooks.hostFile(.claude).content, false), (AgentHooks.hostFile(.codex).name, AgentHooks.hostFile(.codex).content, true)] {
            let command = try XCTUnwrap(RemoteCommands.writeHostFile(file, executable: executable))
            XCTAssertEqual(try ssh.exec(command, input: Data(content.utf8), timeout: 10).status, 0)
        }
        XCTAssertEqual(try sh(ssh, "test -x \"$HOME/.roamtty/codex\" && test ! -x \"$HOME/.roamtty/claude-hooks.json\" && cat \"$HOME/.roamtty/claude-hooks.json\"").1, AgentHooks.claudeSettings)

        // A pane running a program, as an agent would; the hooks report into its session's options.
        XCTAssertEqual(try sh(ssh, "cd /tmp && tmux new-session -d -s \(name) -x 80 -y 24 && tmux send-keys -t \(name) 'sleep 600' Enter && sleep 1").0, 0)
        let pane = try sh(ssh, "tmux display-message -p -t \(name) '#{pane_id}'").1.trimmingCharacters(in: .whitespacesAndNewlines)
        func hook(_ event: String, _ json: String) throws {
            XCTAssertEqual(try sh(ssh, "printf '%s' '\(json)' | TMUX_PANE='\(pane)' sh \"$HOME/.roamtty/agent-hook.sh\" claude \(event)").0, 0)
        }
        try hook("prompt", #"{"session_id":"s1","prompt":"fix the bug"}"#)
        try hook("tool", #"{"tool_name":"Bash","tool_input":{"command":"make test"}}"#)

        let poll = try ssh.exec(RemoteCommands.agentStatus(name), input: Data(), timeout: 10)
        let output = String(decoding: poll.output, as: UTF8.self)
        let status = try XCTUnwrap(AgentStatus.parse(output), output)
        XCTAssertEqual(status.state, .working)
        XCTAssertEqual(status.task, "fix the bug")
        XCTAssertEqual(agentActivity(status), "Running make test")
        XCTAssertEqual(AgentStatus.directory(output), "/tmp")

        try hook("stop", #"{"last_assistant_message":"All **done**."}"#)
        let idle = try XCTUnwrap(AgentStatus.parse(String(decoding: try ssh.exec(RemoteCommands.agentStatus(name), input: Data(), timeout: 10).output, as: UTF8.self)))
        XCTAssertEqual(idle.state, .idle)
        XCTAssertEqual(replyPreview(idle.reply), "All done.")
        XCTAssertNotNil(idle.workedSeconds)

        // Restarting reports the program the pane ran and leaves a fresh pane in the same folder.
        let restarted = try ssh.exec(RemoteCommands.restartPane(name), input: Data(), timeout: 10)
        XCTAssertEqual(restarted.status, 0)
        XCTAssertEqual(String(decoding: restarted.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "sleep 600")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try sh(ssh, "tmux display-message -p -t \(name) '#{pane_current_path}'").1.trimmingCharacters(in: .whitespacesAndNewlines), "/tmp")
        // A bare shell has no program to type again.
        XCTAssertEqual(String(decoding: try ssh.exec(RemoteCommands.restartPane(name), input: Data(), timeout: 10).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "")

        // Closing ends the session on the server.
        XCTAssertEqual(try sh(ssh, RemoteCommands.killTmux(name)).0, 0)
        XCTAssertNotEqual(try sh(ssh, "tmux has-session -t =\(name) 2>/dev/null").0, 0)
    }
}
