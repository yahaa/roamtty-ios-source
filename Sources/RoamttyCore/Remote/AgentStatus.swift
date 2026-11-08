// Behavioral port of Roamtty Android's AgentStatus.kt: what a coding agent started with the app's hooks reports
// through its tmux session's options, and how the session list names and describes it.
import Foundation
import CNative

/// What an AI agent in a tmux session reports through the hooks `AgentHooks` adds: its state, the tool it is running
/// and the task (the last prompt), and the folder the pane is in. Read with `RemoteCommands.agentStatus`; see `parse`.
public struct AgentStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable { case working, waiting, idle }
    public var state: State
    public var agent: String
    public var tool: String
    public var detail: String
    public var task: String
    /// Elapsed milliseconds the state has lasted, on the host's clock.
    public var elapsedMillis: Int64
    /// The pane's working directory; empty when tmux did not say.
    public var directory: String
    /// Seconds the last turn worked, once it stopped; nil while one runs, or before the first.
    public var workedSeconds: Int64?
    /// The start of the agent's last answer, on one line; empty while a turn runs, or when it gave none.
    public var reply: String

    public init(state: State, agent: String, tool: String = "", detail: String = "", task: String = "", elapsedMillis: Int64 = 0,
                directory: String = "", workedSeconds: Int64? = nil, reply: String = "") {
        self.state = state; self.agent = agent; self.tool = tool; self.detail = detail; self.task = task
        self.elapsedMillis = elapsedMillis; self.directory = directory; self.workedSeconds = workedSeconds; self.reply = reply
    }

    static let shells: Set<String> = ["bash", "zsh", "fish", "dash", "ash", "ksh", "csh", "tcsh", "nu", "pwsh", "login"]

    /// Agents that run under their `/bin/sh` launcher, which ends the report itself: the pane shows the launcher's
    /// shell while they run, "sh" on Linux but "bash" on macOS, whose `/bin/sh` is bash.
    private static let launched: Set<String> = ["codex", "grok"]

    private static func lines(_ output: String?) -> [String]? {
        output?.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether `new` is `old` read again `seconds` later: the same in all but its age, which moved on by about as
    /// much (within `slack` seconds). A state that restarted, such as a new turn, does not count, even when its age
    /// went back by less than the slack: an age only grows while its state lasts.
    public static func sameExceptAge(_ old: AgentStatus?, _ new: AgentStatus?, after seconds: TimeInterval, slack: TimeInterval = 5) -> Bool {
        guard var old, let new else { return old == nil && new == nil }
        guard new.elapsedMillis >= old.elapsedMillis else { return false }
        let expected = Double(old.elapsedMillis) + seconds * 1000
        old.elapsedMillis = new.elapsedMillis
        return old == new && abs(Double(new.elapsedMillis) - expected) <= slack * 1000
    }

    /// Output of the status command: `pane_command|state|since|agent|tool|detail|worked|task|reply` (`worked` and
    /// `reply` missing in older reports), the pane's path, then the host's time. The state counts only while the pane
    /// still runs a program: an agent killed before it could report leaves its last state behind, but the pane is back
    /// at a shell.
    public static func parse(_ output: String?) -> AgentStatus? {
        guard let lines = lines(output), let first = lines.first else { return nil }
        let fields = first.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { return nil }
        let worked = fields.count >= 8 ? Int64(fields[6].trimmingCharacters(in: .whitespaces)) : nil
        let task = fields.count >= 8 ? fields[7] : fields[6]
        let reply = fields.count == 9 ? clean(fields[8]) : ""
        var command = Substring(fields[0]); while command.first == "-" { command.removeFirst() }
        if shells.contains(String(command)) && !launched.contains(fields[3]) { return nil }
        guard let state = State(rawValue: fields[1]) else { return nil }
        let since = Int64(fields[2])
        let now = lines.count > 1 ? Int64(lines[lines.count - 1].trimmingCharacters(in: .whitespaces)) : nil
        let elapsed = since.flatMap { since in now.map { max(0, ($0 - since) * 1000) } } ?? 0
        return AgentStatus(state: state, agent: fields[3], tool: fields[4].trimmingCharacters(in: .whitespaces),
                           detail: fields[5].trimmingCharacters(in: .whitespaces), task: clean(task), elapsedMillis: elapsed,
                           directory: directory(output), workedSeconds: state == .idle ? worked : nil, reply: state == .idle ? reply : "")
    }

    /// The folder the pane is in, from the same poll `parse` reads; known with or without an agent, empty when not.
    public static func directory(_ output: String?) -> String {
        guard let lines = lines(output), lines.count >= 3 else { return "" }
        return lines[1].trimmingCharacters(in: .whitespaces)
    }

    /// A byte-limited hook value may end in half a character.
    private static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix("\u{FFFD}") { result.removeLast() }
        return result
    }
}

/// An agent's `AgentStatus.reply` as the session list shows it: the Markdown it answers in read as plain text (no
/// emphasis, code ticks, heading marks, a leading list mark, links as their text), on one line.
public func replyPreview(_ reply: String) -> String {
    var text = reply.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\*\*|`+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(^|\s)#{1,6}\s+"#, with: "$1", options: .regularExpression)
    // The hook joins the lines, so only the first line's list or quote mark is known for one; a dash further on may be text.
    text = text.replacingOccurrences(of: #"^\s*([-*+>]|\d+\.)\s+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespaces)
}

/// The tools agents run shell commands with.
private let shellTools: Set<String> = ["Bash", "PowerShell", "run_terminal_command", "shell", "exec_command", "local_shell"]

/// What the agent is running, for the session list: a shell command as `Running command`, as Claude Code says it,
/// another tool by its name and what it works on; empty while it runs nothing.
public func agentActivity(_ status: AgentStatus?) -> String {
    guard let status, status.state != .idle else { return "" }
    if status.detail.isEmpty { return status.tool }
    if status.tool.isEmpty { return status.detail }
    if shellTools.contains(status.tool) { return "Running " + status.detail }
    return status.tool + " " + status.detail
}

/// The last component of a session-list path, keeping `~` and `/` whole.
public func sessionListFolder(_ path: String) -> String {
    if path == "~" || path == "/" { return path }
    var trimmed = path; while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
}

/// A session's name in the session list: the task its agent was given, else the agent's name and the name of the
/// folder it works in ("Claude · roamtty", the home as `~`), else `title` (one saved as "Claude Code · roamtty"
/// shortened to "Claude · roamtty"). Without a known agent the folder stands alone. Empty when there is none of these.
public func sessionListTitle(_ title: String, status: AgentStatus?, agent: CodingAgent?, username: String) -> String {
    if let task = status?.task, !task.trimmingCharacters(in: .whitespaces).isEmpty { return task }
    let path = sessionListPath(status, username: username)
    if !path.isEmpty {
        let folder = sessionListFolder(path)
        return agent.map { $0.shortLabel + " · " + folder } ?? folder
    }
    guard let agent else { return title }
    let prefix = agent.label + " · "
    return title.hasPrefix(prefix) ? agent.shortLabel + " · " + title.dropFirst(prefix.count) : title
}

/// The folder the session's agent works in, the home as `~`; empty when tmux did not say.
public func sessionListPath(_ status: AgentStatus?, username: String) -> String { sessionListPath(status?.directory ?? "", username: username) }

/// `directory` as the session list shows it, the home as `~`; empty for none.
public func sessionListPath(_ directory: String, username: String) -> String {
    guard !directory.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
    let homes = username == "root" ? ["/root"] : ["/home/" + username, "/Users/" + username]
    guard let home = homes.first(where: { directory == $0 || directory.hasPrefix($0 + "/") }) else { return directory }
    return "~" + directory.dropFirst(home.count)
}

/// The session list's groups, in its order: what waits for the user first, sessions without an agent last.
public enum SessionGroup: String, CaseIterable, Sendable { case waiting, working, done, other }

/// The group of a session whose agent reports `status`: by its state while connected, else with the plain terminals.
public func sessionGroup(connected: Bool, status: AgentStatus?) -> SessionGroup {
    guard connected, let status else { return .other }
    switch status.state {
    case .waiting: return .waiting
    case .working: return .working
    case .idle: return .done
    }
}

/// A running state's length, short as Claude Code's own: "12s", "4m20s", "1h05m".
public func shortDuration(_ seconds: Int64) -> String {
    func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m\(two(seconds % 60))s" }
    return "\(seconds / 3600)h\(two(seconds % 3600 / 60))m"
}

/// How long ago an agent finished, without spaces so it never breaks across lines: "刚刚", "3分钟前".
public func agoText(_ seconds: Int64, english: Bool) -> String {
    if seconds < 60 { return english ? "now" : "刚刚" }
    if seconds < 3600 { return english ? "\(seconds / 60)m ago" : "\(seconds / 60)分钟前" }
    if seconds < 86_400 { return english ? "\(seconds / 3600)h ago" : "\(seconds / 3600)小时前" }
    return english ? "\(seconds / 86_400)d ago" : "\(seconds / 86_400)天前"
}

/// A turn's length in words: "15 秒", "3 分钟", "1 小时 5 分钟".
public func durationText(_ seconds: Int64, english: Bool) -> String {
    if seconds < 60 { return english ? "\(seconds) s" : "\(seconds) 秒" }
    if seconds < 3600 { return english ? "\(seconds / 60) min" : "\(seconds / 60) 分钟" }
    return english ? "\(seconds / 3600) h \(seconds % 3600 / 60) min" : "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
}

/// The tags a session card shows beside its status, like a host card's: tmux for a resumable session and mosh while
/// mosh carries it. A plain SSH shell has none.
public func sessionTransportTags(mode: SessionMode, mosh: Bool) -> [String] {
    (mode == .tmux ? ["tmux"] : []) + (mosh ? ["mosh"] : [])
}

/// Hooks of the coding agents that report to `AgentStatus` through a script kept on the host. Claude Code reads its
/// hooks from `--settings`; Codex and Grok start through a launcher in the same folder that adds theirs.
public enum AgentHooks {
    /// Where the script and the agents' hook files live on the host; the shell expands the home.
    public static let scriptPath = "~/.roamtty/agent-hook.sh"
    public static let settingsPath = "~/.roamtty/claude-hooks.json"
    public static let scriptName = "agent-hook.sh"

    public static var script: String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "agent-hook", withExtension: "sh"), let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("agent-hook.sh is missing from the app resources")
        }
        return source
    }

    /// The hook file `agent` needs on the host: a name in `~/.roamtty`, its contents and whether it must run.
    /// With `session`, Claude Code's file names the tmux session it reports to.
    public static func hostFile(_ agent: CodingAgent, session: String? = nil) -> (name: String, content: String, executable: Bool) {
        switch agent {
        case .claude:
            if let session = reportingSession(session) { return (settingsPrefix + session + ".json", claudeSettings(session: session), false) }
            return ("claude-hooks.json", claudeSettings, false)
        case .codex: return ("codex", codexLauncher, true)
        case .grok: return ("grok", grokLauncher, true)
        }
    }

    /// What `agent` is typed as: Claude Code with its settings, the others through their launcher.
    public static func command(_ agent: CodingAgent) -> String { agent == .claude ? agent.command : "~/.roamtty/" + hostFile(agent).name }

    /// Where Claude Code started for tmux session `session` reads its hooks.
    public static func settingsPath(session: String?) -> String {
        reportingSession(session).map { "~/.roamtty/" + settingsPrefix + $0 + ".json" } ?? settingsPath
    }

    private static let settingsPrefix = "claude-hooks-"

    /// `session` when it can go into a hook command and a file name as it is; anything else reports as before.
    private static func reportingSession(_ session: String?) -> String? {
        guard let session, !session.isEmpty, session.count <= 64,
              session.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { return nil }
        return session
    }

    /// Removes the settings of tmux sessions that ended long ago. A file stays while its session lives, and for a month
    /// after: a background job outlives its pane, and restarting one fails without its settings.
    public static let pruneSettings = RemoteCommands.shell(RemoteCommands.pathSetup + "; " +
        "find \"$HOME/.roamtty\" -maxdepth 1 -name '\(settingsPrefix)*.json' -mtime +30 2>/dev/null | while IFS= read -r file; do " +
        "name=${file##*/\(settingsPrefix)}; tmux has-session -t \"=${name%.json}\" 2>/dev/null || rm -f \"$file\"; done; exit 0")

    private static func hookCommand(_ agent: CodingAgent, _ action: String, session: String? = nil) -> String {
        "sh \(scriptPath) \(agent.command) \(action)" + (session.map { " " + $0 } ?? "")
    }

    /// Contents of `settingsPath`, for Claude Code's `--settings`: merged with the user's own settings and hooks.
    public static var claudeSettings: String { claudeSettings(session: nil) }

    /// As `claudeSettings`, for an agent started in tmux session `session`. Background jobs inherit `--settings`, which
    /// is all that tells them the session they belong to: they run outside tmux.
    public static func claudeSettings(session: String?) -> String {
        let events = [("SessionStart", "start"), ("UserPromptSubmit", "prompt"), ("PreToolUse", "tool"), ("PostToolUse", "post"),
                      ("Notification", "notify"), ("Stop", "stop"), ("SessionEnd", "end")]
        return "{\"hooks\":{" + events.map { event, action in
            "\"\(event)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.claude, action, session: session))\"}]}]"
        }.joined(separator: ",") + "}}"
    }

    /// Codex events, their key in Codex's hook state, and what the script makes of them.
    private static let codexEvents = [
        ("SessionStart", "session_start", "start"), ("UserPromptSubmit", "user_prompt_submit", "prompt"),
        ("PreToolUse", "pre_tool_use", "tool"), ("PermissionRequest", "permission_request", "ask"),
        ("PostToolUse", "post_tool_use", "post"), ("Stop", "stop", "stop"),
        ("Interrupt", "interrupt", "stop"), ("SessionEnd", "session_end", "end")]

    /// Seconds a Codex hook may take; within Codex's limit for SessionEnd and Interrupt hooks, so it hashes as written.
    private static let codexTimeout = 3

    /// The hash Codex trusts a hook by: SHA-256 of its normalized definition as sorted, compact JSON (codex-rs hooks
    /// `hook_hash`). Codex runs a session's hooks only once trusted, a trust it keeps in its config.toml.
    public static func codexHookHash(eventKey: String, command: String) -> String {
        let json = "{\"event_name\":\"\(eventKey)\",\"hooks\":[{\"async\":false,\"command\":\"\(command)\"," +
            "\"timeout\":\(codexTimeout),\"type\":\"command\"}]}"
        let input = Array(json.utf8)
        var digest = [UInt8](repeating: 0, count: 32)
        input.withUnsafeBufferPointer { roam_sha256($0.baseAddress, input.count, &digest) }
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A launcher ends the report however its agent ended, as the agent's own end hook would, and exits as the agent did.
    private static func launcherEnd(_ agent: CodingAgent) -> [String] { ["status=$?", hookCommand(agent, "end") + " </dev/null", "exit $status"] }

    /// `~/.roamtty/codex`: records the trust Codex's own "Trust all" would for the hooks it adds (once; a different
    /// trust already there is left for the user), then runs Codex with them. It stays the pane's program, so restarting
    /// the pane types it again.
    public static var codexLauncher: String {
        let trust = codexEvents.map { _, key, action in "trust \(key) \(codexHookHash(eventKey: key, command: hookCommand(.codex, action)))" }
        let hooks = codexEvents.map { event, _, action in
            "  -c 'hooks.\(event)=[{hooks=[{type=\"command\",command=\"\(hookCommand(.codex, action))\",timeout=\(codexTimeout)}]}]' \\"
        }
        let head = [
            "#!/bin/sh",
            "# Roamtty: starts Codex with hooks that report its state to agent-hook.sh.",
            "config=\"${CODEX_HOME:-$HOME/.codex}/config.toml\"",
            "trust() {",
            "  header=\"[hooks.state.\\\"/<session-flags>/config.toml:$1:0:0\\\"]\"",
            "  grep -qF \"$header\" \"$config\" 2>/dev/null || printf '\\n%s\\ntrusted_hash = \"%s\"\\n' \"$header\" \"$2\" >> \"$config\"",
            "}",
            "mkdir -p \"$(dirname \"$config\")\""
        ]
        return (head + trust + ["codex \\"] + hooks + ["  \"$@\""] + launcherEnd(.codex)).joined(separator: "\n") + "\n"
    }

    /// Grok events and what the script makes of them.
    private static let grokEvents = [("SessionStart", "start"), ("UserPromptSubmit", "prompt"), ("PreToolUse", "tool"),
        ("PostToolUse", "post"), ("PostToolUseFailure", "post"), ("Notification", "notify"), ("Stop", "stop"),
        ("StopFailure", "stop"), ("StopCancelled", "stop"), ("SessionEnd", "end")]

    /// `~/.roamtty/grok`: Grok reads hooks only from its own folders, so this puts them in `~/.grok/hooks`, where they
    /// act only for a Grok started here (the script checks `ROAMTTY_AGENT`), then runs Grok.
    public static var grokLauncher: String {
        let hooks = grokEvents.map { event, action in
            "\"\(event)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.grok, action))\"}]}]"
        }.joined(separator: ",")
        let lines = [
            "#!/bin/sh",
            "# Roamtty: starts Grok with hooks that report its state to agent-hook.sh.",
            "dir=\"${GROK_HOME:-$HOME/.grok}/hooks\"",
            "mkdir -p \"$dir\" && printf '%s\\n' '{\"hooks\":{\(hooks)}}' > \"$dir/roamtty.json\"",
            "export ROAMTTY_AGENT=grok",
            "grok \"$@\""
        ]
        return (lines + launcherEnd(.grok)).joined(separator: "\n") + "\n"
    }
}
