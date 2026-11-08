// Behavioral ports of Roamtty Android's Tmux, HostPlugins, HostSystem, AgentLaunch,
// StartDirectory and ShellHistoryCommands helpers.
import Foundation

public enum RemoteCommands {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// `script` as one command line for `/bin/sh`, whatever the login shell is.
    public static func shell(_ script: String) -> String { "/bin/sh -c " + shellQuote(script) }
    /// Runs the script sent on standard input, which keeps it out of the command line and the process list.
    public static let stdinShell = "/bin/sh -s"
    public static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
    public static let pathSetup = "PATH=\"$PATH:\(extraPath)\"; export PATH"
    public static let tmuxProbe = shell(pathSetup + "; command -v tmux >/dev/null 2>&1")
    public static func sanitizeSessionName(_ name: String) -> String {
        let safe = String(name.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_" }.prefix(64))
        return safe.isEmpty ? "roamtty" : safe
    }
    // swiftlint:disable:next line_length - one shell script line
    private static let bottomPromptPane = ##"n=$(tmux display-message -p "#{pane_height}" 2>/dev/null); [ -n "$n" ] || { set -- $(stty size 2>/dev/null); n=${1:-0}; }; while [ "$n" -gt 1 ]; do echo; n=$((n - 1)); done; s=${SHELL:-/bin/sh}; c=$(tmux show-options -gv default-command 2>/dev/null); [ -n "$c" ] && exec "$s" -c "$c"; exec "$s" -l"##

    /// `existing`: a session that was already on the server, attached as it is: never created, its other clients stay
    /// attached and its status line stays; only mouse mode goes on, so swipes scroll its history. The client runs with
    /// `-u` because sshd may start the command without a UTF-8 locale (macOS does), and tmux then draws every
    /// non-ASCII character as "_".
    public static func tmuxAttach(_ name: String, existing: Bool = false) -> String {
        let name = sanitizeSessionName(name)
        if existing { return "exec " + shell(pathSetup + "; exec tmux -u attach-session -t =\(name) \\; set-option -t \(name) mouse on") }
        let pane = bottomPromptPane.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
        let options = "\\; set-option -t \(name) mouse on \\; set-option -t \(name) status off"
        let script = pathSetup + "; " +
            "if [ \"$(tmux display-message -p -t \(name) \"#{pane_mode}\" 2>/dev/null)\" = copy-mode ]; then " +
            "tmux send-keys -t \(name) -X cancel || true; fi; " +
            "case \"$(tmux -V 2>/dev/null)\" in \"tmux \"[0-2].*) exec tmux -u new-session -A -D -s \(name) \(options);; esac; " +
            "exec tmux -u new-session -A -D -s \(name) /bin/sh -c \"\(pane)\" \(options)"
        return "exec " + shell(script)
    }
    /// One line per tmux session on the server, `windows<TAB>attached clients<TAB>last activity<TAB>pane command<TAB>
    /// agent report<TAB>name<TAB>folder`, the report as `agentStatus` reads it (see `TmuxSessionInfo.parse`); nothing
    /// when no tmux server runs, and exit status 127 without tmux. The hook strips tabs from what it records.
    public static let tmuxSessions = shell(pathSetup + "; command -v tmux >/dev/null 2>&1 || exit 127; " +
        // swiftlint:disable:next line_length - the tmux format string is one argument
        "tmux -u list-sessions -F '#{session_windows}\t#{session_attached}\t#{session_activity}\t#{pane_current_command}\t#{@roamtty_agent}|#{@roamtty_worked}|#{@roamtty_task}|#{@roamtty_reply}\t#{session_name}\t#{pane_current_path}' 2>/dev/null; exit 0")
    public static func killTmux(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return pathSetup + "\ntmux has-session -t =\(name) 2>/dev/null || exit 0\nexec tmux kill-session -t =\(name)\n"
    }
    /// One line `pane_command|state|since|agent|tool|detail|worked|task|reply` of what an agent reports through the
    /// session options `@roamtty_agent`, `@roamtty_worked`, `@roamtty_task` and `@roamtty_reply` (empty when it
    /// reports nothing), the pane's folder, then the host's clock for the elapsed time. `-u`: sshd on macOS runs
    /// commands without a UTF-8 locale, and tmux then prints each non-ASCII character of a prompt or a folder as "_".
    public static func agentStatus(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return shell(pathSetup + "; tmux -u display-message -p -t \(name) " +
            "\"#{pane_current_command}|#{@roamtty_agent}|#{@roamtty_worked}|#{@roamtty_task}|#{@roamtty_reply}\" 2>/dev/null && " +
            "tmux -u display-message -p -t \(name) \"#{pane_current_path}\" 2>/dev/null; date +%s")
    }
    /// Restarts `name`'s pane in the folder it is in, ending whatever runs there. Prints the command line of the pane's
    /// foreground program (nothing when only the shell ran) so it can be typed into the fresh shell. tmux before 2.6
    /// has no `respawn-pane -c`, so it falls back to a plain respawn.
    public static func restartPane(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return shell(pathSetup + "; " +
            "p=$(tmux display-message -p -t \(name) \"#{pane_pid}\") && [ -n \"$p\" ] || exit 1; " +
            "d=$(tmux display-message -p -t \(name) \"#{pane_current_path}\"); " +
            "ps -A -ww -o ppid= -o stat= -o args= | while read q s a; do [ \"$q\" = \"$p\" ] || continue; " +
            "case \"$s\" in *+*) printf \"%s\\n\" \"$a\"; break;; esac; done; " +
            "tmux respawn-pane -k ${d:+-c \"$d\"} -t \(name) 2>/dev/null || exec tmux respawn-pane -k -t \(name)")
    }
    /// Writes its standard input to `~/.roamtty/<name>`, replacing it; `name` is a plain file name.
    public static func writeHostFile(_ name: String, executable: Bool = false) -> String? {
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else { return nil }
        let chmod = executable ? " && chmod +x \"$HOME/.roamtty/\(name)\"" : ""
        return shell("mkdir -p \"$HOME/.roamtty\" && cat > \"$HOME/.roamtty/\(name)\"" + chmod)
    }
    /// Prints the folder the terminal is in: the tmux pane's, or for a plain shell the login shell of this same SSH
    /// connection (found by its `SSH_CONNECTION` and `SSH_TTY`), without typing anything into its terminal.
    public static func workingDirectory(tmux name: String?) -> String {
        if let name {
            return shell(pathSetup + "; tmux -u display-message -p -t " + shellQuote("=" + sanitizeSessionName(name) + ":") + " '#{pane_current_path}'")
        }
        return shell(#"""
            test -n "$SSH_CONNECTION" || exit 1
            for pid in $(ps -u "$(id -u)" -o pid=,sid= | awk '$1 == $2 { print $1 }'); do
                p=/proc/$pid
                test -r "$p/environ" || continue
                env_lines=$(tr '\000' '\n' < "$p/environ" 2>/dev/null) || continue
                printf '%s\n' "$env_lines" | grep -Fxq "SSH_CONNECTION=$SSH_CONNECTION" || continue
                printf '%s\n' "$env_lines" | grep -q '^SSH_TTY=/dev/' || continue
                readlink "$p/cwd" && exit 0
            done
            exit 1
            """#)
    }
    public static func tmuxAlternateScreen(_ name: String) -> String {
        // The colon selects the active pane. A session-only target produces an empty format value.
        let target = "=" + sanitizeSessionName(name) + ":"
        return shell(pathSetup + "; tmux display-message -p -t " + shellQuote(target) + " '#{alternate_on}'")
    }
}

public enum CodingAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude = "CLAUDE", codex = "CODEX", grok = "GROK"
    public var id: String { rawValue }
    public var label: String { self == .claude ? "Claude Code" : shortLabel }
    public var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }
    public var command: String { rawValue.lowercased() }
    public var readOnlyFlag: String { self == .claude ? "--permission-mode plan" : "--sandbox read-only" }
    public var yoloFlag: String {
        switch self {
        case .claude: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        case .grok: return "--always-approve"
        }
    }
    public static func from(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .codex }
    /// The agent a hook reported itself as (its `command`), or nil for one this app does not know.
    public static func fromCommand(_ value: String?) -> Self? { allCases.first { $0.command == value } }
    /// The agent a session named by `AgentLaunch.title` was started for, or nil for any other title.
    public static func fromTitle(_ title: String) -> Self? { allCases.first { title.hasPrefix($0.shortLabel + " · ") || title.hasPrefix($0.label + " · ") } }
}

public enum AgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "READ_ONLY", standard = "STANDARD", yolo = "YOLO"
    public var id: String { rawValue }
    public static func from(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .standard }
}

public struct AgentLaunch: Equatable, Sendable {
    public var agent: CodingAgent
    public var directory: String
    public var mode: AgentMode
    public init(agent: CodingAgent, directory: String, mode: AgentMode = .standard) { self.agent = agent; self.directory = directory; self.mode = mode }
    public var agentCommand: String {
        switch mode {
        case .standard: return agent.command
        case .readOnly: return agent.command + " " + agent.readOnlyFlag
        case .yolo: return agent.command + " " + agent.yoloFlag
        }
    }
    /// Agents report their state through hooks on hosts that run POSIX scripts.
    public var reportsStatus: Bool { true }
    /// `agentCommand` as typed: with the hooks `AgentHooks.hostFile` puts on the host, which Claude Code reads from its
    /// settings and the other agents get from their launcher.
    public var typedCommand: String { typedCommand(session: nil) }
    /// As `typedCommand`, in tmux session `session`, which Claude Code's hooks then report to from outside tmux too.
    public func typedCommand(session: String?) -> String {
        if agent == .claude { return agentCommand + " --settings " + AgentHooks.settingsPath(session: session) }
        return AgentHooks.command(agent) + agentCommand.dropFirst(agent.command.count)
    }
    public var commandLine: String { commandLine(session: nil) }
    public func commandLine(session: String?) -> String {
        guard StartDirectory.isSupported(directory) else { return "printf '%s\\n' 'Unsupported directory control characters' >&2; false" }
        let typed = typedCommand(session: session)
        return StartDirectory.command(directory).map { $0 + " && " + typed } ?? typed
    }
    public var title: String {
        var value = directory; while value.hasSuffix("/") { value.removeLast() }
        let name = value.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return agent.shortLabel + " · " + (name.isEmpty ? "/" : name)
    }
}

public enum StartDirectory {
    public static let home = "~"
    public static func isSupported(_ value: String) -> Bool { !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
    public static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "~/" { return home }
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
    public static func isHome(_ value: String) -> Bool { isSupported(value) && normalize(value) == home }
    public static func command(_ directory: String) -> String? {
        guard isSupported(directory) else { return nil }
        let directory = normalize(directory)
        if directory == home { return nil }
        return directory.hasPrefix("~/") ? "cd -- ~/" + RemoteCommands.shellQuote(String(directory.dropFirst(2))) : "cd -- " + RemoteCommands.shellQuote(directory)
    }
    public static func segments(_ directory: String) -> [(name: String, path: String)] {
        guard isSupported(directory) else { return [] }
        let directory = normalize(directory), root: String, rest: String
        if directory == home || directory.hasPrefix("~/") {
            root = home
            rest = String(directory.dropFirst())
        } else if directory.hasPrefix("/") {
            root = "/"
            rest = directory
        } else {
            return [(directory, directory)]
        }
        var path = root, result = [(root, root)]
        for name in rest.split(separator: "/") { path += (path.hasSuffix("/") ? "" : "/") + name; result.append((String(name), path)) }
        return result
    }
    public static func sanitizeRecent(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return Array(values.filter(isSupported).map(normalize).filter { $0 != home && seen.insert($0).inserted }.prefix(6))
    }
    public static func remember(recent: [String], directory: String) -> [String] {
        let safe = sanitizeRecent(recent)
        guard isSupported(directory) else { return safe }
        let directory = normalize(directory)
        return directory == home ? safe : Array(([directory] + safe.filter { $0 != directory }).prefix(6))
    }
}

public enum ShellHistoryCommands {
    public static let defaultLimit = 200
    public static let maxCommandLength = 500
    public struct CommonCommands: Equatable, Sendable {
        public var commands: [String]
        public var source: String
    }
    /// The reader supplies a bounded tail and whether its first line may be incomplete.
    /// Unreadable files return nil; cancellation and transport failures may propagate.
    public static func load(readText: (String) async throws -> (String, Bool)?) async throws -> CommonCommands? {
        for path in [".bash_history", ".zsh_history"] {
            try Task.checkCancellation()
            guard let (raw, truncated) = try await readText(path) else { continue }
            let commands = rankByRecency(extractCommands(raw, zshStyle: path == ".zsh_history", skipFirstLine: truncated))
            if !commands.isEmpty { return CommonCommands(commands: commands, source: "~/" + path) }
        }
        return nil
    }
    public static func extractCommands(_ raw: String, zshStyle: Bool, skipFirstLine: Bool = false) -> [String] {
        let lines = raw.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        return lines.dropFirst(skipFirstLine ? min(1, lines.count) : 0).compactMap { line in
            var command = line.trimmingCharacters(in: .whitespaces)
            if zshStyle, let prefix = command.range(of: #"^:\s*\d+:\d+;"#, options: .regularExpression) { command = String(command[prefix.upperBound...]).trimmingCharacters(in: .whitespaces) }
            guard valid(command), zshStyle || command.range(of: #"^#\d+$"#, options: .regularExpression) == nil else { return nil }
            return command
        }
    }
    public static func rankByRecency(_ commands: [String], limit: Int = defaultLimit) -> [String] {
        var seen = Set<String>(); return Array(commands.reversed().filter { seen.insert($0).inserted }.prefix(max(0, limit)))
    }
    public static func mergeRecent(_ recent: [String], saved: [String]) -> [String] {
        var seen = Set<String>(); return Array((recent + saved).filter { seen.insert($0).inserted }.prefix(defaultLimit))
    }
    public static func executionInput(_ command: String, bracketed: Bool) throws -> String {
        guard valid(command) else { throw RoamError.invalid("Invalid history command") }
        return (bracketed ? "\u{1b}[200~" + command + "\u{1b}[201~" : command) + "\r"
    }
    public static func fuzzyFilter(_ commands: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return commands }
        return commands.filter { command in
            let value = command.lowercased(); if value.contains(needle) { return true }
            var remaining = value[...]
            for character in needle {
                guard let at = remaining.firstIndex(of: character) else { return false }
                remaining = remaining[remaining.index(after: at)...]
            }
            return true
        }
    }
    private static func valid(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf16.count <= maxCommandLength &&
            !command.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value) }
    }
}

public enum HostPlugin: String, Codable, CaseIterable, Sendable { case tmux, mosh
    public var id: String { rawValue }
}

public enum HostPluginProbe {
    public static let tmuxMarker = "__ITERMUX_TMUX__="
    public static let moshMarker = "__ITERMUX_MOSH__="
    public static let command = RemoteCommands.stdinShell
    public static var script: String {
        RemoteCommands.pathSetup + "\nm=$(command -v mosh-server 2>/dev/null)\nprintf '\(tmuxMarker)%s\\n' \"$(command -v tmux 2>/dev/null)\"\nprintf '\(moshMarker)%s\\n' \"$m\"\nexit 0"
    }
    public static func parse(_ output: String?) -> Set<HostPlugin>? {
        guard let lines = output?.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }),
              let tmux = lines.first(where: { $0.hasPrefix(tmuxMarker) }), let mosh = lines.first(where: { $0.hasPrefix(moshMarker) }) else { return nil }
        var result = Set<HostPlugin>()
        if !tmux.dropFirst(tmuxMarker.count).trimmingCharacters(in: .whitespaces).isEmpty { result.insert(.tmux) }
        if !mosh.dropFirst(moshMarker.count).trimmingCharacters(in: .whitespaces).isEmpty { result.insert(.mosh) }
        return result
    }
}

public enum HostPluginInstaller {
    public static let sudoFailed = "__ITERMUX_SUDO_FAILED__", noPrivilege = "__ITERMUX_NO_PRIVILEGE__", noPackageManager = "__ITERMUX_NO_PACKAGE_MANAGER__", done = "__ITERMUX_INSTALL_DONE__"
    public enum Result: Equatable, Sendable { case installed, sudoPassword, noPrivilege, noPackageManager, failed }
    /// Send this script on the stdin of /bin/sh -s; passwords must not enter the remote process list.
    public static func script(plugin: HostPlugin, sudoPassword: String?) -> String {
        let password = sudoPassword.flatMap { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") ? nil : $0 } ?? ""
        let pkg = plugin.rawValue
        let epel = plugin == .mosh ? " || { run \"$1\" install -y epel-release && run \"$1\" install -y \(pkg); }" : ""
        return #"""
        exec 2>&1
        \#(RemoteCommands.pathSetup)
        PW=\#(RemoteCommands.shellQuote(password))
        need_root() {
          if [ "$(id -u)" = 0 ]; then run() { "$@"; }
          elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then run() { sudo -n "$@"; }
          elif command -v sudo >/dev/null 2>&1 && [ -n "$PW" ]; then
            printf '%s\n' "$PW" | sudo -S -k -p '' true >/dev/null 2>&1 || { echo \#(sudoFailed); exit 3; }
            run() { printf '%s\n' "$PW" | sudo -S -k -p '' "$@"; }
          elif command -v sudo >/dev/null 2>&1; then echo \#(sudoFailed); exit 3
          else echo \#(noPrivilege); exit 5
          fi
        }
        has() { command -v "$1" >/dev/null 2>&1; }
        none() { echo \#(noPackageManager); exit 4; }
        dnf_like() { need_root; run "$1" install -y \#(pkg)\#(epel); }
        case "$(uname -s 2>/dev/null)" in
          Darwin)
            if has brew; then brew install \#(pkg)
            elif has port; then need_root; run port -N install \#(pkg)
            else none; fi ;;
          MSYS*|MINGW*)
            if has pacman; then pacman -Sy --noconfirm --needed \#(pkg); else none; fi ;;
          CYGWIN*)
            if has apt-cyg; then apt-cyg install \#(pkg); else none; fi ;;
          *)
            if [ -n "$TERMUX_VERSION" ] && has pkg; then pkg install -y \#(pkg)
            elif [ "$(id -u)" != 0 ] && ! has sudo && has brew; then brew install \#(pkg)
            elif has apt-get; then
              need_root
              run env DEBIAN_FRONTEND=noninteractive apt-get update -q && run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \#(pkg)
            elif has dnf; then dnf_like dnf
            elif has yum; then dnf_like yum
            elif has pacman; then need_root; run pacman -Sy --noconfirm --needed \#(pkg)
            elif has zypper; then need_root; run zypper --non-interactive install \#(pkg)
            elif has apk; then need_root; run apk add \#(pkg)
            elif has pkg; then need_root; run pkg install -y \#(pkg)
            elif has brew; then brew install \#(pkg)
            else none; fi ;;
        esac
        status=$?
        [ $status = 0 ] && echo \#(done)
        exit $status
        """#
    }
    public static func classify(exitStatus: Int?, output: String) -> Result {
        if exitStatus == 0 && output.contains(done) { return .installed }
        if output.contains(sudoFailed) { return .sudoPassword }
        if output.contains(noPrivilege) { return .noPrivilege }
        if output.contains(noPackageManager) { return .noPackageManager }
        return .failed
    }
    public static func displayLine(_ line: String) -> String? { line.hasPrefix("__ITERMUX_") ? nil : line }
}

public enum HostSystem: String, Codable, CaseIterable, Sendable {
    case UNKNOWN, OTHER, LINUX, WINDOWS, MACOS, UBUNTU, DEBIAN, CENTOS, FEDORA, ARCH, REDHAT, OPENSUSE, ROCKY, ALMALINUX, GENTOO, NIXOS, LINUXMINT
    public var label: String {
        switch self {
        case .UNKNOWN: return "未知系统"
        case .OTHER: return "其他系统"
        case .LINUX: return "Linux"
        case .WINDOWS: return "Windows"
        case .MACOS: return "macOS"
        case .UBUNTU: return "Ubuntu"
        case .DEBIAN: return "Debian"
        case .CENTOS: return "CentOS"
        case .FEDORA: return "Fedora"
        case .ARCH: return "Arch Linux"
        case .REDHAT: return "Red Hat Enterprise Linux"
        case .OPENSUSE: return "openSUSE"
        case .ROCKY: return "Rocky Linux"
        case .ALMALINUX: return "AlmaLinux"
        case .GENTOO: return "Gentoo"
        case .NIXOS: return "NixOS"
        case .LINUXMINT: return "Linux Mint"
        }
    }
    public static func fromStored(_ value: String) -> Self { Self(rawValue: value) ?? .UNKNOWN }
}

public enum HostSystemProbe {
    public static let kernelMarker = "__ITERMUX_KERNEL__", releaseMarker = "__ITERMUX_OS_RELEASE__", legacyMarker = "__ITERMUX_LEGACY_RELEASE__"
    public static let command = RemoteCommands.stdinShell, windowsCommand = "cmd.exe /c ver"
    public static let script = #"""
    printf '__ITERMUX_KERNEL__\n'; uname -s 2>/dev/null
    printf '__ITERMUX_OS_RELEASE__\n'
    if [ -r /etc/os-release ]; then head -c 4096 /etc/os-release
    elif [ -r /usr/lib/os-release ]; then head -c 4096 /usr/lib/os-release; fi
    printf '\n__ITERMUX_LEGACY_RELEASE__\n'
    if [ -r /etc/centos-release ]; then head -c 512 /etc/centos-release
    elif [ -r /etc/redhat-release ]; then head -c 512 /etc/redhat-release; fi
    exit 0
    """#
    public static func parse(unix: String?, windows: String? = nil) -> HostSystem {
        func section(_ start: String, until end: String?) -> String {
            guard let text = unix, let range = text.range(of: start + "\n") else { return "" }
            let rest = text[range.upperBound...]
            return String(end.flatMap { rest.range(of: $0).map { rest[..<$0.lowerBound] } } ?? rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let kernel = section(kernelMarker, until: releaseMarker).lowercased()
        if kernel == "linux" {
            var values: [String: String] = [:]
            for line in section(releaseMarker, until: legacyMarker).split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let at = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<at]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: at)...]).trimmingCharacters(in: .whitespaces)
                for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) { value = String(value.dropFirst().dropLast()) }
                values[key] = value
            }
            let supported: [String: HostSystem] = ["ubuntu": .UBUNTU, "debian": .DEBIAN, "centos": .CENTOS, "fedora": .FEDORA, "arch": .ARCH,
                "rhel": .REDHAT, "opensuse": .OPENSUSE, "opensuse-leap": .OPENSUSE, "opensuse-tumbleweed": .OPENSUSE, "rocky": .ROCKY,
                "almalinux": .ALMALINUX, "gentoo": .GENTOO, "nixos": .NIXOS, "linuxmint": .LINUXMINT]
            if let id = values["ID"], !id.isEmpty { return supported[id.lowercased()] ?? .LINUX }
            let legacy = section(legacyMarker, until: nil).lowercased()
            if legacy.hasPrefix("centos") { return .CENTOS }
            if legacy.hasPrefix("red hat enterprise linux") { return .REDHAT }
            return .LINUX
        }
        if kernel == "darwin" { return .MACOS }
        if ["mingw", "msys", "cygwin"].contains(where: kernel.hasPrefix) { return .WINDOWS }
        if (windows ?? "").range(of: #"(?im)^\s*Microsoft Windows\s+\["#, options: .regularExpression) != nil { return .WINDOWS }
        return ["freebsd", "openbsd", "netbsd", "dragonfly", "sunos", "aix"].contains(kernel) ? .OTHER : .UNKNOWN
    }
}

/// A tmux session already on the server, as the new-session sheet lists it to attach.
public struct TmuxSessionInfo: Equatable, Identifiable, Sendable {
    public var name: String
    public var windows: Int
    public var attached: Int
    public var activity: Date?
    /// The folder of its active pane.
    public var directory: String
    /// The program in the foreground of its active pane ("zsh", "vim", "claude"); empty when tmux did not say.
    public var command: String
    /// What an agent the app's hooks watch reports from it; nil without one, or once the pane is back at a shell.
    public var agent: AgentStatus?
    public var id: String { name }
    public init(name: String, windows: Int, attached: Int, activity: Date?, directory: String, command: String = "", agent: AgentStatus? = nil) {
        self.name = name; self.windows = windows; self.attached = attached; self.activity = activity; self.directory = directory
        self.command = command; self.agent = agent
    }
    /// Whether its pane is only at a shell prompt.
    public var idleShell: Bool {
        var program = Substring(command); while program.first == "-" { program.removeFirst() }
        return agent == nil && (program.isEmpty || AgentStatus.shells.contains(String(program)))
    }
    /// The app's tmux commands take only names `RemoteCommands.sanitizeSessionName` keeps as they are.
    public var attachable: Bool { RemoteCommands.sanitizeSessionName(name) == name }
    /// `RemoteCommands.tmuxSessions` output, most recently used first.
    public static func parse(_ output: String) -> [TmuxSessionInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> TmuxSessionInfo? in
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[5].isEmpty, let windows = Int(fields[0]), let attached = Int(fields[1]) else { return nil }
            let directory = fields.count > 6 ? fields[6] : ""
            // As `RemoteCommands.agentStatus` prints it; the clock is left out, as the list shows no elapsed time.
            let agent = AgentStatus.parse(fields[3] + "|" + fields[4] + (directory.isEmpty ? "" : "\n" + directory) + "\n0")
            return TmuxSessionInfo(name: fields[5], windows: windows, attached: attached,
                                   activity: TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:)), directory: directory,
                                   command: fields[3], agent: agent)
        }.sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
    }
}
