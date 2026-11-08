import SwiftUI
import RoamttyCore

/// The landscape host page's sections, each with its tab.
enum HostDetailTab: Hashable { case overview, processes, info }

/// Where each landscape section sits in the page's scroll.
struct HostSectionFrames: PreferenceKey {
    static let defaultValue: [HostDetailTab: CGRect] = [:]
    static func reduce(value: inout [HostDetailTab: CGRect], nextValue: () -> [HostDetailTab: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The host page in landscape, built like the home page there: one flat 48-point bar with back, the 概览 · 进程 · 信息
/// tabs and the four actions, and below it the whole page in one scroll. The tabs follow the scroll: the one whose
/// section is under the bar is selected, and tapping one scrolls to its section.
extension HostDetailScreen {
    func landscape(_ host: Host) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                landscapeBar(host, proxy)
                GeometryReader { viewport in
                    ScrollView {
                        VStack(spacing: 24) {
                            section(.overview) { overview(host) }
                            section(.processes) { processes }
                            section(.info) {
                                VStack(spacing: 24) {
                                    information(host)
                                    // Last on the page: the ports list can run long.
                                    HostPortsSection(host: host)
                                }
                            }
                        }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 16)
                    }.coordinateSpace(name: Self.scrollSpace).accessibilityIdentifier("host-detail-scroll")
                        .onPreferenceChange(HostSectionFrames.self) { frames in follow(frames, height: viewport.size.height) }
                }
            }
        }.pageBackground().toolbar(.hidden, for: .navigationBar)
    }
    private static var scrollSpace: String { "host-detail-scroll" }
    private func section<Content: View>(_ tab: HostDetailTab, @ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity).id(tab)
            .background(GeometryReader { geo in Color.clear.preference(key: HostSectionFrames.self, value: [tab: geo.frame(in: .named(Self.scrollSpace))]) })
    }
    /// Selects the last section whose top has passed the upper third of the screen, or 信息 once the page is scrolled
    /// to its end, since the last section may be too short to ever reach the top.
    private func follow(_ frames: [HostDetailTab: CGRect], height: CGFloat) {
        guard !tabScrolling, let overview = frames[.overview] else { return }
        let scrolled = overview.minY < -1
        let atEnd = frames[.info].map { $0.maxY <= height + 1 } ?? false
        let current: HostDetailTab = scrolled && atEnd ? .info
            : [HostDetailTab.info, .processes].first { (frames[$0]?.minY ?? .infinity) <= height / 3 } ?? .overview
        if current != landscapeTab { withAnimation(.easeInOut(duration: 0.2)) { landscapeTab = current } }
    }

    // MARK: Bar

    private func landscapeBar(_ host: Host, _ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Button { if !model.path.isEmpty { model.path.removeLast() } } label: {
                AppIcon("ic_chevron_left", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel(model.text("返回", "Back")).accessibilityIdentifier("host-detail-back")
            HStack(spacing: 0) {
                tab(model.text("概览", "Overview"), count: nil, .overview, proxy, id: "host-tab-overview")
                tab(model.text("进程", "Processes"), count: model.metrics[hostID].map { $0.processes.count }, .processes, proxy, id: "host-tab-processes")
                tab(model.text("信息", "Info"), count: nil, .info, proxy, id: "host-tab-info")
            }.padding(3).background(Palette.foreground.opacity(0.07), in: Capsule()).fixedSize()
            Spacer(minLength: 8)
            // Every action carries its name when the bar has room (Chinese always does); otherwise only Agent keeps it.
            ViewThatFits(in: .horizontal) {
                actions(host, titled: true)
                actions(host, titled: false)
            }
            moreMenu(host) { AppIcon("ic_more", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle()) }
        }.buttonStyle(.plain).padding(.horizontal, 6).frame(height: 48)
    }
    private func tab(_ title: String, count: Int?, _ value: HostDetailTab, _ proxy: ScrollViewProxy, id: String) -> some View {
        let active = landscapeTab == value
        return Button {
            // The scroll passes the sections in between; the tab stays on the one tapped until it has arrived.
            tabScrolling = true
            withAnimation(.easeInOut(duration: 0.25)) { landscapeTab = value }
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(value, anchor: .top) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tabScrolling = false }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: active ? .semibold : .regular))
                if let count, count > 0 { Text("\(count)").font(.system(size: 15, weight: .semibold)).opacity(0.7) }
            }.foregroundStyle(active ? Palette.foreground : Palette.secondary).lineLimit(1).padding(.horizontal, 14).frame(height: 32)
                .background(active ? Palette.foreground.opacity(0.14) : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected, .isHeader] : []).accessibilityIdentifier(id)
    }
    private func actions(_ host: Host, titled: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.sheet = .launch(host, true) } label: { pill("Agent", "ic_agent", filled: true) }.accessibilityIdentifier("host-detail-agent")
            Button { model.sheet = .launch(host, false) } label: { pill(titled ? model.text("终端", "Terminal") : nil, "ic_sessions") }
                .accessibilityLabel(model.text("终端", "Terminal")).accessibilityIdentifier("host-detail-terminal")
            Button { model.path.append(.files(hostID)) } label: { pill(titled ? model.text("文件", "Files") : nil, "ic_folder") }
                .accessibilityLabel(model.text("文件", "Files")).accessibilityIdentifier("host-detail-files")
            if model.desktopOnHostPage(host) {
                Button { model.openDesktop(host) } label: { pill(titled ? model.text("桌面", "Desktop") : nil, "ic_desktop") }
                    .accessibilityLabel(model.text("桌面", "Desktop")).accessibilityIdentifier("host-detail-desktop")
            }
        }.fixedSize()
    }
    /// A 34-point capsule inside a 44-point target; without a title it is a circle around the icon.
    private func pill(_ title: String?, _ icon: String, filled: Bool = false) -> some View {
        HStack(spacing: 6) {
            AppIcon(icon, size: 17)
            if let title { Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1) }
        }.foregroundStyle(filled ? Palette.onAccent : Palette.foreground)
            .padding(.leading, title == nil ? 0 : 11).padding(.trailing, title == nil ? 0 : 13)
            .frame(minWidth: 34).frame(height: 34)
            .background(filled ? Palette.accent : Palette.raised, in: Capsule())
            .frame(height: 44).contentShape(Rectangle())
    }

    // MARK: 概览

    private func overview(_ host: Host) -> some View {
        let metrics = model.metrics[hostID]
        let live = monitorLive
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                HostSystemMark(system: host.system).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(host.name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                        ReachabilityLabel(state: model.reachability[hostID] ?? .checking, fontSize: 13)
                    }
                    Text(identityLine(host, metrics)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if live {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.success).frame(width: 6, height: 6)
                        Text(model.text("每 3 秒刷新", "Refreshes every 3 seconds")).font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("host-monitor-status")
                    }
                }
            }.padding(.horizontal, 4)
            if !live { monitorPanel(host) }
            if let metrics {
                let series = model.metricSeries[hostID] ?? HostMetricSeries()
                HStack(spacing: 10) {
                    tile("CPU", trailing: metrics.cpus.map { model.text("\($0) 核", "\($0) cores") }, value: metrics.cpuPercent, id: "host-gauge-cpu") {
                        Sparkline(values: series.cpuHistory, tone: MetricFormat.levelColor(metrics.cpuPercent), height: 26)
                    }
                    tile(model.text("内存", "Memory"), trailing: MetricFormat.usage(metrics.memUsedBytes, metrics.memTotalBytes), value: metrics.memPercent, id: "host-gauge-memory") {
                        Sparkline(values: series.memHistory, tone: MetricFormat.levelColor(metrics.memPercent), height: 26)
                    }
                    let disk = metrics.disks.first
                    tile(model.text("磁盘", "Disk"), trailing: MetricFormat.usage(disk?.usedBytes, disk?.totalBytes), value: disk?.percent, id: "host-gauge-disk") {
                        meter(disk?.percent)
                    }
                    networkTile(series.netRate)
                }
                summary(metrics)
            }
        }
    }
    private func identityLine(_ host: Host, _ metrics: HostMetrics?) -> String {
        var parts = ["\(host.username)@\(host.address):\(host.port)", metrics?.os ?? host.system]
        if let seconds = metrics?.uptimeSeconds { parts.append(model.text("已运行 ", "up ") + MetricFormat.uptime(seconds, model)) }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
    /// One reading: its name and context on top, the number large, and its history or fill along the bottom.
    private func tile<Bottom: View>(_ title: String, trailing: String?, value: Double?, id: String, @ViewBuilder bottom: () -> Bottom) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).lineLimit(1).minimumScaleFactor(0.75) }
            }.font(.caption).foregroundStyle(Palette.secondary)
            Text(MetricFormat.percent(value)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value.map { $0 >= 70 } == true ? MetricFormat.levelColor(value) : Palette.foreground)
            Spacer(minLength: 6)
            bottom()
        }.padding(.horizontal, 13).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).frame(height: 116)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(MetricFormat.percent(value)), \(trailing ?? "")").accessibilityIdentifier(id)
    }
    private func meter(_ value: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.foreground.opacity(0.08))
                Capsule().fill(MetricFormat.levelColor(value)).frame(width: geo.size.width * CGFloat(min(100, max(0, value ?? 0))) / 100)
            }
        }.frame(height: 5).padding(.bottom, 4)
    }
    private func networkTile(_ rate: HostMetricSeries.NetworkRate?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.text("网络", "Network")).font(.caption).foregroundStyle(Palette.secondary)
            Text(rate.map { "↓ " + MetricFormat.bytes($0.rxBytesPerSecond) + "/s" } ?? "—").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
            Text(rate.map { "↑ " + MetricFormat.bytes($0.txBytesPerSecond) + "/s" } ?? " ").font(.subheadline).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 13).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).frame(height: 116)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine).accessibilityIdentifier("host-network-rate")
    }
    /// The smaller numbers side by side: load, tasks, swap and login sessions, whichever the host reports.
    private func summary(_ metrics: HostMetrics) -> some View {
        var cells: [(String, String)] = [(model.text("负载 1/5/15", "Load 1/5/15"), metrics.load.isEmpty ? "—" : metrics.load.map { String(format: "%.2f", $0) }.joined(separator: " · "))]
        if let tasks = metrics.tasks { cells.append((model.text("任务", "Tasks"), tasks)) }
        if let total = metrics.swapTotalBytes, total > 0 {
            cells.append((model.text("交换分区", "Swap"), "\(MetricFormat.bytes(Double(metrics.swapUsedBytes ?? 0))) / \(MetricFormat.bytes(Double(total)))"))
        }
        if let users = metrics.users { cells.append((model.text("登录会话", "Login sessions"), String(users))) }
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 { Rectangle().fill(Palette.outline.opacity(0.6)).frame(width: 1).padding(.vertical, 2) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.0).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                    Text(cell.1).font(.subheadline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }.padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.vertical, 10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 进程

    @ViewBuilder private var processes: some View {
        if let metrics = model.metrics[hostID] {
            MetricsPanel(metrics: metrics, series: model.metricSeries[hostID] ?? HostMetricSeries(), layout: .processes)
        } else {
            Panel(title: model.text("进程", "Processes")) {
                InfoRow(title: model.text("连接后可查看进程", "Connect to see processes"))
            }
        }
    }

    // MARK: 信息

    private func information(_ host: Host) -> some View {
        let metrics = model.metrics[hostID]
        return HStack(alignment: .top, spacing: 12) {
            Panel(title: model.text("连接", "Connection")) { connectionRows(host) }.frame(maxWidth: .infinity)
            VStack(spacing: 16) {
                if let metrics {
                    Panel(title: model.text("系统", "System")) {
                        if let os = metrics.os { InfoRow(title: model.text("系统", "System"), value: os).panelDivider() }
                        systemRows(metrics)
                    }
                    if !metrics.disks.isEmpty {
                        Panel(title: model.text("磁盘", "Disks")) {
                            ForEach(Array(metrics.disks.enumerated()), id: \.offset) { _, disk in
                                InfoRow(title: disk.mount, value: "\(MetricFormat.usage(disk.usedBytes, disk.totalBytes) ?? "—") · \(MetricFormat.percent(disk.percent))").panelDivider()
                            }
                        }
                    }
                } else {
                    Panel(title: model.text("系统", "System")) {
                        InfoRow(title: model.text("系统", "System"), value: host.system.isEmpty ? "—" : host.system)
                    }
                }
            }.frame(maxWidth: .infinity)
        }
    }
}
