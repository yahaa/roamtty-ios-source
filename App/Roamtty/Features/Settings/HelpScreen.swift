import SwiftUI

// swiftlint:disable line_length - each help paragraph is one bilingual string, kept whole to stay searchable.
struct HelpScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact { landscape } else { portrait }
            }.pageBackground().navigationTitle(title)
                .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { doneButton } }
        }
    }
    private var title: String { model.text("使用指南", "Guide") }
    private var doneButton: some View { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("guide-done") }
    private var portrait: some View {
        ScrollView {
            VStack(spacing: 24) { connectPanel; sessionsPanel; gesturesPanel; transfersPanel }.padding(16)
        }.accessibilityIdentifier("guide-scroll")
    }
    /// Landscape: the flat bar, and the four topics as two columns, so a line is short enough to read across.
    private var landscape: some View {
        VStack(spacing: 0) {
            LandscapeBar(title: title) { EmptyView() } trailing: { doneButton.buttonStyle(TextActionStyle()) }
            ScrollView {
                LandscapeColumns(spacing: 20) { connectPanel; sessionsPanel } right: { gesturesPanel; transfersPanel }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }.accessibilityIdentifier("guide-scroll")
        }
    }
    private var connectPanel: some View {
        Panel(title: model.text("连接主机", "Connect a host")) {
            Text(model.text("在“主机”页点“+”添加主机，可用密码、交互式认证或 Ed25519/RSA 私钥（支持加密私钥）。主机卡片显示系统图标、在线状态与 DNS + TCP 建连延时（不含 SSH 启动等待）。首次连接先核对 SHA-256 指纹再信任。",
                "Tap + on the Hosts tab to add a host. Sign in with a password, keyboard-interactive login or an Ed25519/RSA private key (encrypted keys work). Host cards show the system icon, online status and DNS + TCP connection latency (excluding SSH startup). Check the SHA-256 fingerprint before trusting a host the first time.")).padding(16)
        }
    }
    private var sessionsPanel: some View {
        Panel(title: model.text("会话与 AI Agent", "Sessions and AI agents")) {
            Text(model.text("“会话”页列出全部会话（每台主机最多 8 个），按 Agent 状态分组：待确认、运行中、已完成和终端，并显示 Agent 的任务、正在运行的命令和最后的回复。待确认时可直接“允许”，空闲时可“追问”。点“+”先选 AI Agent 或终端，再选主机（也可当场填写新主机），最后选择工作目录。断线的 tmux 会话保留卡片并自动重连；长按卡片可“关闭”（结束远端 tmux 会话及其中任务）；主机离线或无响应时可“强制删除”，卡片立即移除，主机能连上时同样结束远端会话。Agent 等你确认或做完一轮（超过 1 分钟）时会发通知，点通知直接进入该会话。iOS 会在应用进入后台约半分钟后暂停网络活动，之后的提醒在回到应用时发出。",
                "The Sessions tab lists every session (up to 8 per host), grouped by what the agent is doing: needs you, running, done and terminals, with the agent's task, the command it runs and its last reply. Allow a request or reply to an idle agent right from the row. + picks an AI agent or a terminal, then the host (or a new one filled in on the spot), then the working folder. A dropped tmux session keeps its card and reconnects by itself; long-press a card to Close it (ending the remote tmux session and its tasks), or Force delete it when its host is offline or not answering: the card goes at once, and the remote session ends too if the host can be reached. When an agent needs you or finishes a turn of over a minute you get a notification; tap it to open that session. iOS suspends network activity about half a minute after the app goes to the background; later notifications come once you are back in the app.")).padding(16)
        }
    }
    private var gesturesPanel: some View {
        Panel(title: model.text("终端手势", "Terminal gestures")) {
            Text(model.text("点击光标所在行及上下两行可打开键盘；双击发送 Tab，同时小精灵上方出现 ↑ 键、下方出现 ↓ 键、左边出现 ← 键用来选择补全项；三击粘贴。点击终端里的链接会在浏览器或对应 App 中打开。拖动查看回滚内容，长按选择文字，双指缩放调整字体。按住键盘删除键约 1 秒清空当前行，快速点按只逐字删除；清空需远端支持 Ctrl+U/Ctrl+K。键盘弹出时，光标行末多出收起键盘键，点它或点光标附近以外的区域即可收起；按回车后 15 秒内没有输入，键盘也会自动收起。停止输入后，光标行末显示回车键，其余时间显示 Esc；输入以 / 开头的斜杠命令时，小精灵旁也会出现 ↑/↓/← 键。点小幽灵打开工具箱，长按并滑动选择快捷键；会话菜单可返回主机详情、关闭或重启当前会话、切换会话。",
                "Tap within two rows of the cursor to open the keyboard. Double-tap sends Tab and brings ↑ above the pet, ↓ below it and ← to its left for picking a completion; triple-tap pastes. Tap a link in the terminal to open it in the browser or its app. Drag to scroll back, hold to select text, and pinch to adjust font size. Hold the keyboard's delete key for about a second to clear the current line; quick taps delete one character at a time. Clearing needs the host to support Ctrl+U/Ctrl+K. While the keyboard is up, a hide-keyboard key sits at the end of the cursor row; tap it, or tap away from the cursor, to put the keyboard away. After Enter it also hides by itself if you type nothing for 15 seconds. Enter appears at the cursor row after typing pauses; otherwise Esc is shown. On a line starting with / the ↑/↓/← keys also appear around the pet. Tap the ghost for tools, or hold and drag to a shortcut; the session menu goes back to the host, closes or restarts the session, or switches sessions.")).padding(16)
        }
    }
    private var transfersPanel: some View {
        Panel(title: model.text("传输文件", "Transfer files")) {
            Text(model.text("在文件页中选择上传或下载。上传文件或文件夹来自 iOS 文件；下载保存在 Roamtty/Downloads，或设置中选择的目录。传输可在传输面板查看进度和取消。",
                "Upload files or folders from iOS Files. Downloads go to Roamtty/Downloads or the folder chosen in Settings. View progress and cancel transfers in the transfer panel.")).padding(16)
        }
    }
}
// swiftlint:enable line_length
