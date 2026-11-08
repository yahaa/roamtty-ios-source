import Foundation
import RoamttyCore
import RoamttyTransport

/// Commands a session runs on its host beside the terminal, off the main thread.
enum SessionRemote {
    /// Puts the status hook script and the agent's hook file on the host; a failure only costs the agent's status.
    static func installAgentHooks(_ ssh: SSHConnection, agent: CodingAgent, session: String?, cancellation: TransferCancellation) {
        let file = AgentHooks.hostFile(agent, session: session)
        for (name, content, executable) in [(AgentHooks.scriptName, AgentHooks.script, false), (file.name, file.content, file.executable)] {
            guard let command = RemoteCommands.writeHostFile(name, executable: executable),
                  let result = try? ssh.exec(command, input: Data(content.utf8), timeout: 8, cancellation: cancellation), result.status == 0 else { return }
        }
        if agent == .claude { _ = try? ssh.exec(AgentHooks.pruneSettings, input: Data(), timeout: 8, cancellation: cancellation) }
    }
    /// The clients attached to the tmux session, to tell when this terminal's own client has joined.
    static func tmuxClients(_ ssh: SSHConnection, name: String, cancellation: TransferCancellation, timeout: TimeInterval = 2) throws -> Set<String> {
        let target = "=" + RemoteCommands.sanitizeSessionName(name)
        let script = RemoteCommands.pathSetup + "; tmux list-clients -t " + RemoteCommands.shellQuote(target) + " -F '__ROAMTTY_CLIENT__#{client_pid}|#{client_tty}' 2>/dev/null"
        let result = try ssh.exec(RemoteCommands.shell(script), input: Data(), timeout: timeout, cancellation: cancellation)
        return result.status == 0 ? TerminalStartupGate.clients(from: result.text) : []
    }
}
