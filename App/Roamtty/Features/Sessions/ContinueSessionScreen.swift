import SwiftUI
import RoamttyCore
import RoamttyTransport

/// The tmux sessions already running on `host`: tapping one picks it (the most recently used to start with), the button
/// opens it, or its card when it already has one. In landscape the picked one also shows beside the list. With none
/// running it offers a fresh terminal; without tmux, the host's plugins; a failed login can be retried.
struct ContinueSessionScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let host: Host
    private enum Listing { case sessions([TmuxSessionInfo]), missing, loginFailed(String), failed }
    @State private var listing: Listing?
    @State private var busy = false
    @State private var home: String?
    @State private var selection: String?
    private var sessions: [TmuxSessionInfo]? { if case .sessions(let sessions) = listing { return sessions } else { return nil } }
    private var attachReady: Bool { sessions?.contains { $0.name == selection && $0.attachable } == true }
    private var heading: String { model.text("继续会话 · \(host.name)", "Continue session · \(host.name)") }
    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass == .compact { landscape } else {
                HStack {
                    Text(heading).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("continue-close")
                }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 12)
                listBox.padding(.horizontal, 16)
                attachButton.padding(.horizontal, 16).padding(.vertical, 12)
            }
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
            .task { load() }
    }
    /// Like the launch sheet there: one flat bar, the list over the whole height, and a side column with the picked
    /// session and the button at its foot.
    @ViewBuilder private var landscape: some View {
        LandscapeBar(title: heading) {
            BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "continue-close") { dismiss() }
        } trailing: { EmptyView() }
        HStack(alignment: .top, spacing: 10) {
            listBox
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                if let session = sessions?.first(where: { $0.name == selection }) {
                    Text(model.text("已选择", "Selected")).font(.caption.weight(.medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 4)
                    TmuxSessionCard(hostID: host.id, session: session, home: home)
                }
                attachButton
            }.frame(width: 250)
        }.padding(.horizontal, 6).padding(.bottom, 8)
    }
    private var listBox: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.text("服务器上的 tmux 会话", "tmux sessions on the server")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { load() } label: { AppIcon("ic_refresh", size: 20).frame(width: 40, height: 40) }.disabled(busy)
                    .accessibilityLabel(model.text("刷新", "Refresh")).accessibilityIdentifier("continue-refresh")
            }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 48)
            Divider().overlay(Palette.outline)
            ZStack(alignment: .top) {
                content
                if busy && listing != nil { ProgressView().progressViewStyle(.linear).tint(Palette.accent) }
            }.frame(maxHeight: .infinity)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("continue-sheet")
    }
    @ViewBuilder private var content: some View {
        switch listing {
        case .none: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loginFailed(let message): centerNote(message, action: model.text("重新连接", "Reconnect")) { load() }
        case .missing:
            centerNote(model.text("\(host.name) 没有安装 tmux", "tmux is not installed on \(host.name)"), action: model.text("安装插件", "Install plugins")) {
                model.replaceSheet(with: .plugins(host))
            }
        case .failed: centerNote(model.text("无法读取 tmux 会话", "Cannot list tmux sessions"), action: model.text("重试", "Retry")) { load() }
        case .sessions(let sessions) where sessions.isEmpty:
            centerNote(model.text("\(host.name) 上没有正在运行的会话", "No sessions are running on \(host.name)"),
                       action: model.text("在 \(host.name) 新开终端", "Open a new terminal on \(host.name)")) {
                let current = model.host(host.id) ?? host
                model.launch(current, mode: current.newSessionMode, directory: StartDirectory.home, agent: nil, mosh: nil)
            }
        case .sessions(let sessions):
            TmuxSessionList(hostID: host.id, sessions: sessions, home: home, selected: selection, idPrefix: "continue") { selection = $0.name }
        }
    }
    /// The same words in both orientations: the list (and in landscape the card) already names the session.
    private var attachButton: some View {
        Button {
            guard attachReady, let name = selection else { return }
            model.attachExisting(host, name: name, mosh: nil)
        } label: {
            Text(selection == nil ? model.text("选择一个 tmux 会话", "Pick a tmux session") : model.text("打开会话", "Open session")).lineLimit(1)
                .font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(attachReady ? Palette.onAccent : Palette.foreground.opacity(0.38))
                .background(attachReady ? Palette.accent : Palette.foreground.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain).disabled(!attachReady).accessibilityIdentifier("continue-attach")
    }
    private func centerNote(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).accessibilityIdentifier("continue-note")
            Button(action, action: perform).buttonStyle(TextActionStyle()).accessibilityIdentifier("continue-note-action")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func load() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            // The login comes first, so a failure to sign in reads as such and offers to reconnect, not to retry a list.
            do { _ = try await model.connection(for: host.id) } catch {
                listing = .loginFailed(error.localizedDescription); return
            }
            // Only to show the sessions' folders as `~/…`; first, so the list does not change under the finger.
            if home == nil { home = await homeDirectory() }
            do { listing = try await model.tmuxSessions(on: host.id).map(Listing.sessions) ?? .missing } catch { listing = .failed }
            if let sessions {
                if let picked = selection, !sessions.contains(where: { $0.name == picked && $0.attachable }) { selection = nil }
                if selection == nil { selection = sessions.first(where: \.attachable)?.name }
            }
        }
    }
    private func homeDirectory() async -> String? {
        guard let ssh = try? await model.connection(for: host.id), let script = try? RemoteFolders.script(StartDirectory.home),
              let result = try? await ssh.runScript(script, timeout: 10),
              result.status == 0 else { return nil }
        return RemoteFolders.parse(result.text)?.home
    }
}
