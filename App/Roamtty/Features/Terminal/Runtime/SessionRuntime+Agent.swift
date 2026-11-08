import Foundation
import RoamttyCore
import RoamttyTransport

/// The agent's status (Android `TerminalConnection.agentStatus`) and the actions on the tmux session and its agent.
extension SessionRuntime {
    func startAgentStatusPolling() {
        agentPoll?.cancel()
        guard record.mode == .tmux else { return }
        agentPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .connected else { return }
                let status = await self.pollAgentStatus()
                // An agent shows up within seconds of starting; without one the poll can be lazy.
                do { try await Task.sleep(for: .seconds(status != nil ? 3 : 10)) } catch { return }
            }
        }
    }
    func stopAgentStatusPolling() { agentPoll?.cancel(); agentPoll = nil; agentStatus = nil; agentPolled = false }

    /// Asks the host what the agent is doing now and shows it; a poll that got no answer keeps what was shown.
    @discardableResult func pollAgentStatus() async -> AgentStatus? {
        guard record.mode == .tmux, let ssh = await sideConnection() else { return agentStatus }
        let command = RemoteCommands.agentStatus(record.remoteName), cancellation = lifetimeCancellation
        let output = try? await ssh.run(command, timeout: 5, cancellation: cancellation).text
        guard self.ssh === ssh, phase == .connected else { return agentStatus }
        // Only an answer without an agent clears it.
        guard let answer = output else { return agentStatus }
        let status = AgentStatus.parse(answer), now = Date()
        // The host's clock moves `elapsedMillis` on with every poll, and the list's own clock already counts from
        // `agentStatusAt`: a status that only aged as expected keeps both, so it does not redraw the app every poll.
        if !AgentStatus.sameExceptAge(agentStatus, status, after: now.timeIntervalSince(agentStatusAt)) {
            agentStatus = status; agentStatusAt = now
            AgentStatusMemory.set(status, for: record.id)
        } else if !agentPolled { AgentStatusMemory.set(status, for: record.id) }
        if !agentPolled { agentPolled = true }
        let previous = reportedAgentStatus
        reportedAgentStatus = status
        onAgentReport?(previous, status)
        let directory = AgentStatus.directory(answer)
        if !directory.isEmpty && directory != paneDirectory { paneDirectory = directory }
        return status
    }

    /// The folder the terminal is in now, asked of the host; what the shell last reported when the host does not say.
    func workingDirectory() async -> String {
        let fallback = paneDirectory.isEmpty ? currentDirectory : paneDirectory
        guard phase == .connected, let ssh = await sideConnection() else { return fallback }
        let command = RemoteCommands.workingDirectory(tmux: record.mode == .tmux ? record.remoteName : nil), cancellation = lifetimeCancellation
        let output = (try? await ssh.run(command, timeout: 5, cancellation: cancellation)).flatMap { $0.status == 0 ? $0.text : nil }
        guard let directory = validWorkingDirectory(output) else { return fallback }
        if record.mode == .tmux { paneDirectory = directory } else { currentDirectory = directory }
        return directory
    }

    /// Answers the agent's request for permission with its default choice (Enter: "Yes" in Claude Code, Codex and
    /// Grok). Asks the host first, so a request already answered on another screen gets no stray Enter.
    func approveAgent() async -> Bool {
        guard phase == .connected, await pollAgentStatus()?.state == .waiting else { return false }
        return send("\r")
    }

    /// Sends `text` to an agent that finished its turn, as if typed at its prompt and submitted. Only an idle agent
    /// takes a new prompt. The text goes as a paste when the agent accepts one, so its characters are not read as
    /// keys, and Enter follows a moment later: sent together, the agents take it as part of the paste.
    func followUpAgent(_ text: String) async -> Bool {
        let line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, phase == .connected, await pollAgentStatus()?.state == .idle else { return false }
        let input = terminalView.getTerminal().bracketedPasteMode ? "\u{1b}[200~" + line + "\u{1b}[201~" : line
        guard send(input) else { return false }
        try? await Task.sleep(for: .milliseconds(150))
        return send("\r")
    }

    /// Restarts the tmux pane in its folder and types its foreground program again; false when tmux was not reached.
    func restartPane() async -> Bool {
        guard record.mode == .tmux, phase == .connected, let ssh = await sideConnection() else { return false }
        let command = RemoteCommands.restartPane(record.remoteName), cancellation = lifetimeCancellation
        guard let result = try? await ssh.run(command, timeout: 10, cancellation: cancellation), result.status == 0 else { return false }
        let program = result.trimmedText
        guard !program.isEmpty, !program.contains("\n") else { return true }
        // Let the fresh shell print its prompt before the command echoes.
        try? await Task.sleep(for: .milliseconds(500))
        return send(program + "\r")
    }

    /// Ends this session's tmux session on the server over the live connection; false when it could not.
    func killRemoteSession() async -> Bool {
        guard record.mode == .tmux, let ssh = await sideConnection() else { return false }
        let script = RemoteCommands.killTmux(record.remoteName)
        return (try? await ssh.runScript(script, timeout: 15))?.status == 0
    }
}
