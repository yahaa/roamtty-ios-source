import SwiftUI
import RoamttyCore
import RoamttyTransport

/// Android `CommonCommandsSheet`: the remote shell history, searchable; a tap runs the command in this session.
struct CommandSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var runtime: SessionRuntime
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var query = ""
    @State private var historyCommands: [String] = []
    @State private var historySource = ""
    @State private var historyFailure: String?
    @State private var historyLoading = true
    @State private var refreshID = 0
    init(runtime: SessionRuntime) {
        self.runtime = runtime
        _connectionTarget = State(initialValue: .session(runtime))
    }
    private var commands: [String] { ShellHistoryCommands.fuzzyFilter(ShellHistoryCommands.mergeRecent(runtime.recentCommands, saved: historyCommands), query: query) }
    private var connected: Bool { runtime.phase == .connected }
    var body: some View {
        // Merged, filtered and given their font once per update, not once per line that reads them.
        let commands = self.commands, font = Font(FontCatalog.shared.font(selection: model.settings.font, size: 13) as CTFont)
        VStack(spacing: 0) {
            if compact {
                // Landscape: one flat bar with the count after the title and the search in it, so the list keeps the height.
                LandscapeBar(title: model.text("常用命令", "Common commands"), detail: historyLoading || commands.isEmpty ? nil : sourceLine(commands.count)) {
                    BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "command-done") { dismiss() }
                } trailing: {
                    AppSearchField(text: $query, placeholder: model.text("搜索命令", "Search commands"), id: "history-search", compact: true).frame(width: 260)
                    refreshButton
                }
            } else {
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.text("常用命令", "Common commands")).font(.system(size: 20, weight: .semibold))
                        Text(model.text("点按即执行", "Tap to run")).font(.footnote).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    refreshButton
                    Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }
                        .foregroundStyle(Palette.secondary).accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("command-done")
                }.padding(.leading, 17).padding(.trailing, 8).padding(.top, 20).padding(.bottom, 12)
                AppSearchField(text: $query, placeholder: model.text("搜索命令", "Search commands"), id: "history-search").padding(.horizontal, 16)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if historyLoading {
                        HStack(spacing: 12) { ProgressView().controlSize(.small); Text(model.text("正在读取 shell 历史…", "Reading shell history…")).foregroundStyle(Palette.secondary) }
                            .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 24).accessibilityIdentifier("history-loading")
                    } else if let historyFailure, commands.isEmpty {
                        note(historyFailure)
                    } else if commands.isEmpty {
                        note(query.trimmingCharacters(in: .whitespaces).isEmpty ? model.text("未找到可用命令", "No commands found") : model.text("无匹配命令", "No matching commands"))
                    } else {
                        if !compact {
                            Text(sourceLine(commands.count)).font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.secondary).lineLimit(1).padding(.horizontal, 16).padding(.bottom, 8).accessibilityIdentifier("history-source")
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                                row(command, index: index, last: index == commands.count - 1, font: font)
                            }
                        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 16).padding(.top, compact ? 4 : 16).padding(.bottom, 24)
            }.accessibilityIdentifier("command-history-list")
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
            .presentationDetents([.fraction(0.88), .large]).presentationDragIndicator(.visible)
            .modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }
            .task(id: refreshID) { await refreshHistory() }
    }
    private var compact: Bool { verticalSizeClass == .compact }
    private func sourceLine(_ count: Int) -> String { model.text("\(count) 条 · \(historySource)", "\(count) · \(historySource)") }
    private var refreshButton: some View {
        Button { refreshID += 1 } label: { AppIcon("ic_refresh").frame(width: compact ? 44 : 48, height: compact ? 44 : 48) }
            .foregroundStyle(Palette.secondary).disabled(!connected || historyLoading)
            .accessibilityLabel(model.text("刷新", "Refresh")).accessibilityIdentifier("history-refresh")
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
    }
    private func row(_ command: String, index: Int, last: Bool, font: Font) -> some View {
        Button { run(command) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\u{276F}").foregroundStyle(Palette.accent.opacity(0.8))
                Text(command).foregroundStyle(Palette.foreground).lineLimit(2).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }.font(font).lineSpacing(4).padding(.horizontal, 16).padding(.vertical, 11)
                .frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!connected)
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 34) } }
            .accessibilityLabel(command).accessibilityIdentifier("history-command-\(index)")
    }
    private func refreshHistory() async {
        historyLoading = true; historyFailure = nil
        let cancellation = TransferCancellation()
        await withTaskCancellationHandler(operation: {
            do {
                let ssh = try await model.connection(for: connectionTarget)
                let result = try await ShellHistoryCommands.load { path in
                    try model.validate(connectionTarget)
                    // Keep history in memory and read a bounded tail, including a truncation marker.
                    let script = "f=\"$HOME/\(path)\"; [ -r \"$f\" ] || exit 1; n=$(wc -c < \"$f\") || exit 1; printf '%s\\n' \"$n\"; tail -c 262144 \"$f\""
                    let response = try await ssh.run(RemoteCommands.shell(script), timeout: 8, cancellation: cancellation)
                    guard response.status == 0, let newline = response.output.firstIndex(of: 10) else { return nil }
                    let sizeLine = String(decoding: response.output[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let size = Int64(sizeLine) else { return nil }
                    return (String(decoding: response.output[response.output.index(after: newline)...], as: UTF8.self), size > 262144)
                }
                try Task.checkCancellation()
                try model.validate(connectionTarget)
                historyCommands = result?.commands ?? []; historySource = result?.source ?? ""
                if result == nil { historyFailure = model.text("无法读取 shell 历史", "Unable to read shell history") }
            } catch { if !Task.isCancelled { historyFailure = error.localizedDescription } }
        }, onCancel: { cancellation.cancel() })
        if !Task.isCancelled { historyLoading = false }
    }
    /// Like Android, the sheet closes at once; a refusal shows as the terminal's notice card.
    private func run(_ command: String) {
        dismiss()
        let runtime = runtime, model = model, target = connectionTarget
        Task { @MainActor in
            let cancellation = TransferCancellation()
            do {
                try model.validate(target)
                var fullScreen = runtime.terminalView.getTerminal().isCurrentBufferAlternate
                if runtime.record.mode == .tmux {
                    let ssh = try await model.connection(for: target)
                    let script = RemoteCommands.tmuxAlternateScreen(runtime.record.remoteName)
                    let result = try await ssh.run(script, timeout: 8, cancellation: cancellation)
                    fullScreen = result.status != 0 || result.trimmedText != "0"
                }
                try model.validate(target)
                guard !fullScreen else { runtime.message = model.text("请先退出全屏程序，再执行 shell 历史命令。", "Exit the full-screen program before running a shell history command."); return }
                let input = try ShellHistoryCommands.executionInput(command, bracketed: runtime.terminalView.getTerminal().bracketedPasteMode)
                runtime.terminalView.scrollToLiveOutput()
                guard runtime.send(input) else { runtime.message = model.text("未发送：连接未就绪或输入队列已满。", "Not sent: connection unavailable or input queue full."); return }
                runtime.recentCommands = ShellHistoryCommands.mergeRecent([command], saved: runtime.recentCommands)
            } catch { runtime.message = error.localizedDescription }
        }
    }
}
