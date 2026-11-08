import SwiftUI
import RoamttyCore

/// A new session in two steps: first what runs (an AI agent or a plain terminal), then the host it runs on; the
/// launch sheet that follows picks the folder. Saved hosts are shortcuts; the last row fills in a new host on the spot.
/// The last first-step row instead continues a session already running on a host; with one host it goes straight
/// there, and the new-host row is left out, as a new host has nothing running yet.
struct NewSessionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// What the host step is for: running an agent (nil for a terminal) or continuing a session.
    private enum Pick: Equatable { case run(CodingAgent?), continuing }
    /// Nil until picked.
    @State private var picked: Pick?
    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass == .compact { landscape } else { portrait }
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
            .presentationDetents([.medium, .large])
    }
    private var title: String { picked == nil ? model.text("新建会话", "New session") : model.text("选择主机", "Choose a host") }
    private var backButton: some View {
        Button { withAnimation { picked = nil } } label: { AppIcon("ic_chevron_left", size: 22).frame(width: 44, height: 48) }
            .accessibilityLabel(model.text("返回", "Back")).accessibilityIdentifier("new-session-back")
    }
    @ViewBuilder private var portrait: some View {
        HStack(spacing: 0) {
            if picked != nil { backButton }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
            }.padding(.leading, picked == nil ? 12 : 0)
            Spacer()
            Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("new-session-close")
        }.padding(.leading, 12).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 8)
        ScrollView {
            VStack(spacing: 0) { rows }.padding(.bottom, 16)
        }.accessibilityIdentifier("new-session-sheet")
    }
    /// Landscape: the flat bar with the question after the title, and the choices as two columns, so all of them
    /// are in view without scrolling.
    @ViewBuilder private var landscape: some View {
        LandscapeBar(title: title, detail: subtitle) {
            if picked != nil {
                BarIconButton(icon: "ic_chevron_left", label: model.text("返回", "Back"), id: "new-session-back") { withAnimation { picked = nil } }
            } else {
                BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "new-session-close") { dismiss() }
            }
        } trailing: {
            if picked != nil { BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "new-session-close") { dismiss() } }
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) { rows }
                .padding(.horizontal, 6).padding(.bottom, 12)
        }.accessibilityIdentifier("new-session-sheet")
    }
    @ViewBuilder private var rows: some View {
        if let picked {
            ForEach(model.hosts) { host in
                row(host.name, "\(host.username)@\(host.address):\(host.port)", id: "new-session-host-\(host.id)") { HostSystemMark(system: host.system).frame(width: 40, height: 40) } action: {
                    switch picked {
                    case .run(let agent): model.replaceSheet(with: .launch(host, agent != nil, agent: agent, newSession: true))
                    case .continuing: model.replaceSheet(with: .continueSession(host))
                    }
                }
            }
            if case .run(let agent) = picked {
                row(model.text("新主机", "New host"), model.text("填写地址和登录方式", "Enter its address and sign-in"), id: "new-session-new-host") {
                    IconTile(icon: "ic_add")
                } action: { model.replaceSheet(with: .newHost(forAgent: agent)) }
            }
        } else {
            ForEach(CodingAgent.allCases) { agent in
                row(agent.shortLabel, agent.command, id: "new-session-pick-\(agent.command)") { AgentIcon(agent: agent, size: 40) } action: { withAnimation { picked = .run(agent) } }
            }
            row(model.text("终端", "Terminal"), model.text("登录 shell", "Login shell"), id: "new-session-pick-terminal") { TerminalTile(size: 40) } action: { withAnimation { picked = .run(nil) } }
            // Every host keeps its sessions in tmux here (Android leaves out psmux-only ones, which iOS does not have).
            if !model.hosts.isEmpty {
                row(model.text("继续会话", "Continue session"), model.text("回到服务器上还在运行的会话", "Return to a session still running on a server"), id: "new-session-pick-continue") {
                    IconTile(icon: "ic_history")
                } action: {
                    if model.hosts.count == 1 { model.replaceSheet(with: .continueSession(model.hosts[0])) } else { withAnimation { picked = .continuing } }
                }
            }
        }
    }
    private var subtitle: String {
        switch picked {
        case nil: return model.hosts.isEmpty ? model.text("选择要运行的 AI Agent，或打开终端。", "Pick the AI Agent to run, or open a terminal.")
            : model.text("启动 AI Agent、打开终端，或继续已有会话。", "Start an AI Agent, open a terminal, or continue a session.")
        case .continuing: return model.text("继续哪台主机上的会话？", "Continue a session on which host?")
        case .run(let agent):
            let name = agent?.shortLabel ?? model.text("终端", "Terminal")
            return model.text("在哪台主机上运行 \(name)？", "Which host should run \(name)?")
        }
    }
    private func row<Leading: View>(_ title: String, _ subtitle: String, id: String, @ViewBuilder leading: () -> Leading, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                AppIcon("ic_chevron_right", size: 18).foregroundStyle(Palette.secondary)
            }.padding(.leading, verticalSizeClass == .compact ? 16 : 24).padding(.trailing, verticalSizeClass == .compact ? 12 : 20)
                .padding(.vertical, 8).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

/// A plain tile around `icon`, for rows that start no program.
private struct IconTile: View {
    let icon: String
    var body: some View {
        AppIcon(icon, size: 22).foregroundStyle(Palette.secondary).frame(width: 40, height: 40).background(Palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 11))
    }
}
