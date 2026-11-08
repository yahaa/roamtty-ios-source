import SwiftUI
import RoamttyCore

/// The tmux sessions on a host's server, one row each with what runs there; tapping one calls `onTap`. `selected`
/// is checked, and a session that already has a card is badged 已打开. `home` shows folders as `~/…`.
struct TmuxSessionList: View {
    @EnvironmentObject var model: AppModel
    let hostID: String
    let sessions: [TmuxSessionInfo]
    var home: String?
    var selected: String?
    /// Prefixes the rows' and the list's accessibility identifiers.
    var idPrefix = "launch"
    let onTap: (TmuxSessionInfo) -> Void
    var body: some View {
        let text = TmuxSessionText(model: model, home: home)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    let picked = session.name == selected
                    let open = model.records.contains { $0.hostID == hostID && $0.mode == .tmux && $0.remoteName == session.name }
                    let agent = text.agent(session)
                    let headline = text.headline(session, agent: agent)
                    Button { onTap(session) } label: {
                        HStack(spacing: 12) {
                            if let agent { AgentIcon(agent: agent, size: 32, state: session.agent?.state) } else { TerminalTile(size: 32) }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(headline).font(.body.weight(.medium)).lineLimit(1)
                                    if open { Badge(text: model.text("已打开", "Open")) }
                                }
                                if let doing = text.doing(session) {
                                    Text(doing).font(.caption).foregroundStyle(session.agent?.state.color ?? Palette.secondary).lineLimit(1)
                                }
                                Text(text.detail(session, headline: headline)).font(.caption).foregroundStyle(session.attachable ? Palette.secondary : Palette.danger).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if picked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent) }
                        }.padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52).contentShape(Rectangle())
                            .background(picked ? Palette.accent.opacity(0.1) : Color.clear)
                    }.buttonStyle(.plain).disabled(!session.attachable).opacity(session.attachable ? 1 : 0.5)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 60) }
                        .accessibilityIdentifier("\(idPrefix)-tmux-\(session.name)")
                }
            }
        }.accessibilityIdentifier("\(idPrefix)-tmux-sessions")
    }
}

/// The selected session on its own, for the continue sheet's side column in landscape: its mark, what it is for, what it
/// is doing and where it runs.
struct TmuxSessionCard: View {
    @EnvironmentObject var model: AppModel
    let hostID: String
    let session: TmuxSessionInfo
    var home: String?
    var body: some View {
        let text = TmuxSessionText(model: model, home: home)
        let agent = text.agent(session)
        let headline = text.headline(session, agent: agent)
        let open = model.records.contains { $0.hostID == hostID && $0.mode == .tmux && $0.remoteName == session.name }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let agent { AgentIcon(agent: agent, size: 36, state: session.agent?.state) } else { TerminalTile(size: 36) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if open { Badge(text: model.text("已打开", "Open")) }
                }
            }
            if let doing = text.doing(session) {
                Text(doing).font(.caption).foregroundStyle(session.agent?.state.color ?? Palette.secondary).lineLimit(2)
            }
            Text(text.detail(session, headline: headline)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(3)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .combine)
            .accessibilityIdentifier("launch-tmux-selected")
    }
}

/// How a tmux session reads in the list and on the card. `home` shows folders as `~/…`.
@MainActor struct TmuxSessionText {
    let model: AppModel
    let home: String?
    /// The agent in the session: the one its hooks report, else one running without them, by its program's name.
    func agent(_ session: TmuxSessionInfo) -> CodingAgent? {
        CodingAgent.fromCommand(session.agent?.agent) ?? CodingAgent.fromCommand(session.command)
    }
    /// What the session is for: its agent's task, else the agent or the program it runs and the folder
    /// ("Claude · roamtty", "vim · roamtty"), else the folder of the shell; the session's own name when tmux said none.
    func headline(_ session: TmuxSessionInfo, agent: CodingAgent?) -> String {
        if let task = session.agent?.task, !task.isEmpty { return task }
        let folder = path(session.directory)
        let program = agent?.shortLabel ?? (session.idleShell ? nil : session.command)
        if let program { return folder.isEmpty ? program : program + " · " + sessionListFolder(folder) }
        return folder.isEmpty ? session.name : folder
    }
    /// The agent's state and what it runs or last answered: "运行中 · Running npm test", "空闲 · 已修复…".
    func doing(_ session: TmuxSessionInfo) -> String? {
        guard let status = session.agent else { return nil }
        let state: String
        switch status.state {
        case .working: state = model.text("运行中", "Running")
        case .waiting: state = model.text("等待确认", "Needs approval")
        case .idle: state = model.text("空闲", "Idle")
        }
        let more = status.state == .idle ? replyPreview(status.reply) : agentActivity(status)
        return more.isEmpty ? state : state + " · " + more
    }
    /// The home as `~`.
    func path(_ directory: String) -> String {
        if let home, home != "/", directory == home || directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }
    /// "~/work/app · 5分钟前 · 3 个窗口 · 2 个客户端已连接 · roamtty-1a2b": the folder unless the headline is it; a name
    /// the app made up goes last, as it says least, one somebody chose first.
    func detail(_ session: TmuxSessionInfo, headline: String) -> String {
        guard session.attachable else { return model.text("名称含有特殊字符，暂不支持打开", "Its name has special characters, so it can't be opened") }
        var parts: [String] = []
        let folder = path(session.directory)
        if !folder.isEmpty && folder != headline { parts.append(folder) }
        if let activity = session.activity { parts.append(ago(activity)) }
        if session.windows > 1 { parts.append(model.text("\(session.windows) 个窗口", "\(session.windows) windows")) }
        if session.attached > 0 { parts.append(model.text("\(session.attached) 个客户端已连接", session.attached == 1 ? "1 client attached" : "\(session.attached) clients attached")) }
        if headline != session.name {
            if session.name.hasPrefix("roamtty-") { parts.append(session.name) } else { parts.insert(session.name, at: 0) }
        }
        return parts.joined(separator: " · ")
    }
    /// How long ago, as the session list says it on Android: "刚刚", "3分钟前".
    private func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return model.text("刚刚", "now") }
        if seconds < 3600 { return model.text("\(seconds / 60)分钟前", "\(seconds / 60)m ago") }
        if seconds < 86400 { return model.text("\(seconds / 3600)小时前", "\(seconds / 3600)h ago") }
        return model.text("\(seconds / 86400)天前", "\(seconds / 86400)d ago")
    }
}
