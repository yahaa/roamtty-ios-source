import SwiftUI
import RoamttyCore

struct HostDetailScreen: View {
    @EnvironmentObject var model: AppModel
    let hostID: String
    @State var deleteConfirm = false
    var host: Host? { model.host(hostID) }
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The landscape page's tab, following its scroll.
    @State var landscapeTab: HostDetailTab = .overview
    /// A tab was tapped and the page is scrolling to it, so the scroll does not move the tab meanwhile.
    @State var tabScrolling = false
    var body: some View {
        Group {
            if let host {
                Group {
                    if verticalSizeClass == .compact { landscape(host) } else { portrait(host) }
                }
                    .onAppear { model.startMonitor(host); Task { await model.refreshDesktopProbe(host) } }
                    .task(id: host.address + ":" + String(host.port)) { while !Task.isCancelled { await model.probeHosts([host]); do { try await Task.sleep(for: .seconds(15)) } catch { break } } }
                    .onDisappear { model.stopMonitor(hostID) }
                    .confirmationDialog(model.text("删除 \(host.name)？", "Delete \(host.name)?"), isPresented: $deleteConfirm, titleVisibility: .visible) {
                        Button(model.text("删除主机", "Delete host"), role: .destructive) { model.deleteHost(host) }.accessibilityIdentifier("host-delete-confirm")
                    } message: { Text(model.text("此设备上保存的凭据和会话卡片也会移除。", "Saved credentials and session cards on this device will also be removed.")) }
            }
        }
    }
    private func portrait(_ host: Host) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 16) {
                    HostSystemMark(system: host.system).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(host.username)@\(host.address):\(String(host.port))").font(.subheadline).textSelection(.enabled)
                        Text(model.metrics[hostID]?.os ?? host.system).font(.subheadline).foregroundStyle(Palette.secondary)
                        ReachabilityLabel(state: model.reachability[hostID] ?? .checking)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                // A full row on a narrow phone: the icons step aside before a label would be cut short.
                ViewThatFits(in: .horizontal) {
                    actions(host, icons: true)
                    actions(host, icons: false)
                }
                monitorStatus(host)
                if let metrics = model.metrics[hostID] { MetricsPanel(metrics: metrics, series: model.metricSeries[hostID] ?? HostMetricSeries()) }
                Panel(title: model.text("主机信息", "Host information")) {
                    connectionRows(host)
                    if let metrics = model.metrics[hostID] { systemRows(metrics) }
                }
                // Last on the page: the ports list can run long.
                HostPortsSection(host: host)
            }.padding(16).frame(maxWidth: 720)
        }.frame(maxWidth: .infinity).pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Plugins, edit and delete all live behind the one overflow button, keeping the bar to a single icon.
                ToolbarItem(placement: .navigationBarTrailing) { moreMenu(host) { AppIcon("ic_more", size: 24) } }
            }
    }
    func moreMenu<Icon: View>(_ host: Host, @ViewBuilder label: () -> Icon) -> some View {
        Menu {
            Button { model.sheet = .plugins(host) } label: { Label { Text(model.text("安装插件", "Install plugins")) } icon: { Image("ic_plugin") } }.accessibilityIdentifier("host-detail-plugins")
            Button { model.sheet = .editor(host) } label: { Label { Text(model.text("编辑主机", "Edit host")) } icon: { Image("ic_edit") } }.accessibilityIdentifier("host-detail-edit")
            Divider()
            Button(role: .destructive) { deleteConfirm = true } label: { Label { Text(model.text("删除主机", "Delete host")) } icon: { Image("ic_delete") } }.accessibilityIdentifier("host-delete")
        } label: { label() }
            .accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("host-detail-menu")
    }
    /// How the app reaches the host: address, sign-in and what new sessions run in.
    @ViewBuilder func connectionRows(_ host: Host) -> some View {
        InfoRow(title: model.text("地址", "Address"), value: host.address).panelDivider()
        InfoRow(title: model.text("端口", "Port"), value: String(host.port)).panelDivider()
        InfoRow(title: model.text("用户名", "Username"), value: host.username).panelDivider()
        InfoRow(title: model.text("认证方式", "Authentication"), value: authenticationLabel(host.auth)).panelDivider()
        InfoRow(title: model.text("新会话", "New sessions"), value: host.mode == .tmux ? model.text("tmux · 可恢复", "tmux · resumable") : model.text("普通 SSH", "Plain SSH")).panelDivider()
        InfoRow(title: model.text("插件", "Plugins"), value: host.plugins.map { $0.isEmpty ? model.text("未安装", "None installed") : $0.joined(separator: " · ") } ?? model.text("未检测", "Not detected"))
    }
    /// What the monitor read about the machine itself.
    @ViewBuilder func systemRows(_ metrics: HostMetrics) -> some View {
        if let hostname = metrics.hostname { InfoRow(title: model.text("主机名", "Hostname"), value: hostname).panelDivider() }
        InfoRow(title: model.text("内核", "Kernel"), value: metrics.kernel).panelDivider()
        InfoRow(title: model.text("架构", "Architecture"), value: metrics.arch).panelDivider()
        if let processor = metrics.cpuModel { InfoRow(title: model.text("处理器", "Processor"), value: processor) }
    }
    func authenticationLabel(_ method: AuthMethod) -> String {
        switch method {
        case .password: return model.text("密码", "Password")
        case .key: return model.text("私钥", "Private key")
        case .interactive: return model.text("交互式认证", "Interactive")
        }
    }
    private func actions(_ host: Host, icons: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.sheet = .launch(host, true) } label: { actionLabel("Agent", "ic_agent", icons) }.buttonStyle(RoamButtonStyle(filled: true)).accessibilityIdentifier("host-detail-agent")
            Button {
                model.sheet = .launch(host, false)
            } label: {
                actionLabel(model.text("终端", "Terminal"), "ic_sessions", icons)
            }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("host-detail-terminal")
            Button {
                model.path.append(.files(hostID))
            } label: {
                actionLabel(model.text("文件", "Files"), "ic_folder", icons)
            }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("host-detail-files")
            if model.desktopOnHostPage(host) {
                Button { model.openDesktop(host) } label: { actionLabel(model.text("桌面", "Desktop"), "ic_desktop", icons) }
                    .buttonStyle(RoamButtonStyle()).accessibilityIdentifier("host-detail-desktop")
            }
        }
    }
    /// The label at its full width, so the row that would cut it short does not fit and the one without icons is used.
    private func actionLabel(_ title: String, _ icon: String, _ withIcon: Bool) -> some View {
        HStack(spacing: 8) { if withIcon { AppIcon(icon, size: 18) }; Text(title).lineLimit(1).fixedSize() }.padding(.horizontal, 8)
    }
    /// The monitor is connected and reading, so its numbers are current.
    var monitorLive: Bool { model.monitorStates[hostID].map { $0.phase == .connected && $0.sampled && !$0.reconnecting && !$0.samplingFailed } ?? false }
    private func monitorStatus(_ host: Host) -> some View {
        let live = monitorLive
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.text("实时监控", "Live monitor")).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
                Spacer()
                if live {
                    Circle().fill(Palette.success).frame(width: 6, height: 6)
                    Text(model.text("每 3 秒刷新", "Refreshes every 3 seconds")).font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("host-monitor-status")
                }
            }.padding(.horizontal, 16)
            if !live { monitorPanel(host) }
        }
    }
    func monitorPanel(_ host: Host) -> some View {
        Panel {
            if let state = model.monitorStates[hostID], state.samplingFailed {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.text("无法读取监控数据，请检查远端系统查询权限后重试。", "Couldn't read monitoring data. Check remote system query permissions and try again."))
                        .font(.subheadline).foregroundStyle(Palette.danger).accessibilityIdentifier("host-monitor-error")
                    Button(model.text("重试", "Retry")) { model.stopMonitor(hostID); model.startMonitor(host, interactive: true) }.accessibilityIdentifier("host-monitor-retry")
                }.padding(16)
            } else if let state = model.monitorStates[hostID] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if state.phase.active && !(state.phase == .connected && state.sampled) {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Circle().fill(state.phase == .connected ? Palette.success : Palette.danger).frame(width: 6, height: 6)
                        }
                        Text(state.reconnecting ? model.text("连接中断，正在自动重连…", "Connection interrupted. Reconnecting…")
                             : state.phase != .connected ? model.phaseText(state.phase)
                             : state.sampled ? model.text("每 3 秒刷新", "Refreshes every 3 seconds") : model.text("正在读取…", "Reading…"))
                            .font(.subheadline).accessibilityIdentifier("host-monitor-status")
                        Spacer()
                    }
                    if let detail = state.detail {
                        Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.secondary).textSelection(.enabled).accessibilityIdentifier("host-monitor-detail")
                    }
                    if !state.phase.active {
                        if model.metrics[hostID] != nil { Text(model.text("下方保留上次读取结果。", "The last readings are shown below.")).font(.caption).foregroundStyle(Palette.secondary) }
                        Button(model.text("重新连接", "Reconnect")) { model.startMonitor(host, interactive: true) }.accessibilityIdentifier("host-monitor-retry")
                    }
                }.padding(16)
            } else {
                Button { model.startMonitor(host, interactive: true) } label: {
                    InfoRow(title: model.text("连接以查看 CPU、内存和磁盘", "Connect to view CPU, memory and disks"), icon: "waveform.path.ecg")
                }.accessibilityIdentifier("host-monitor-login")
            }
        }
    }
}
