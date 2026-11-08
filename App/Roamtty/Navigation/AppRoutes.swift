import RoamttyCore

enum AppRoute: Hashable { case host(String), terminal(String), files(String, sessionID: String? = nil, directory: String = "."), desktop(String) }
enum HomeTab: Hashable { case sessions, hosts }
enum AppSheet: Identifiable {
    case editor(Host?)
    /// Fills in a new host on the way to a new session: the agent it starts, or nil for a terminal.
    case newHost(forAgent: CodingAgent?)
    case settings, plugins(Host), guide, about
    /// A launch sheet on a host; `agent` was picked first by the new-session sheet, whose last step this is when `newSession`.
    case launch(Host, Bool, directory: String = "~", agent: CodingAgent? = nil, newSession: Bool = false)
    case newSession
    /// The tmux sessions running on a host, from the new-session sheet's 继续会话.
    case continueSession(Host)
    var id: String {
        switch self {
        case .editor(let h): return "editor-\(h?.id ?? "new")"
        case .newHost(let agent): return "new-host-\(agent?.rawValue ?? "terminal")"
        case .settings: return "settings"
        case .newSession: return "new-session"
        case .continueSession(let h): return "continue-\(h.id)"
        case .launch(let h, let agent, let directory, let picked, _): return "launch-\(h.id)-\(agent)-\(directory)-\(picked?.rawValue ?? "")"
        case .plugins(let h): return "plugins-\(h.id)"
        case .guide: return "guide"
        case .about: return "about"
        }
    }
}
