import SwiftUI
import RoamttyCore

struct MetricsPanel: View {
    @EnvironmentObject var model: AppModel
    let metrics: HostMetrics
    let series: HostMetricSeries
    /// Portrait shows everything in one column; landscape's 进程 section shows only the processes beside the GPUs.
    var layout: Layout = .full
    enum Layout { case full, processes }
    var body: some View {
        switch layout {
        case .full: full
        case .processes: processColumns
        }
    }
    private var full: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                gauge("CPU", value: metrics.cpuPercent, detail: metrics.cpus.map { model.text("\($0) 核", "\($0) cores") }, history: series.cpuHistory, id: "host-gauge-cpu")
                gauge(model.text("内存", "Memory"), value: metrics.memPercent, detail: usage(metrics.memUsedBytes, metrics.memTotalBytes), history: series.memHistory, id: "host-gauge-memory")
                gauge(model.text("磁盘", "Disk"), value: metrics.disks.first?.percent,
                    detail: usage(metrics.disks.first?.usedBytes, metrics.disks.first?.totalBytes), history: nil, id: "host-gauge-disk")
            }
            Panel {
                InfoRow(title: model.text("负载", "Load"), value: metrics.load.isEmpty ? "—" : metrics.load.map {
                    String(format: "%.2f", $0)
                }.joined(separator: "  "), subtitle: model.text("1 / 5 / 15 分钟", "1 / 5 / 15 min")).panelDivider()
                InfoRow(title: model.text("网络", "Network"), value: series.netRate.map {
                    "↓ \(bytes($0.rxBytesPerSecond))/s   ↑ \(bytes($0.txBytesPerSecond))/s"
                } ?? "—").panelDivider().accessibilityIdentifier("host-network-rate")
                InfoRow(title: model.text("运行时间", "Uptime"), value: metrics.uptimeSeconds.map(uptime) ?? "—").panelDivider()
                if let total = metrics.swapTotalBytes, total > 0 {
                    InfoRow(title: model.text("交换分区", "Swap"), value: "\(bytes(Double(metrics.swapUsedBytes ?? 0))) / \(bytes(Double(total)))").panelDivider()
                }
                if let tasks = metrics.tasks { InfoRow(title: model.text("任务", "Tasks"), value: tasks, subtitle: model.text("运行中 / 总数", "running / total")).panelDivider() }
                if let users = metrics.users { InfoRow(title: model.text("登录会话", "Login sessions"), value: String(users)).panelDivider() }
                ForEach(Array(metrics.disks.dropFirst().enumerated()), id: \.offset) { _, disk in
                    InfoRow(title: disk.mount, value: "\(usage(disk.usedBytes, disk.totalBytes) ?? "—") · \(percent(disk.percent))").panelDivider()
                }
            }
            gpuPanels
            processPanel
        }
    }
    /// Landscape: processes on the left, the GPUs and their processes on the right, or the processes alone.
    private var processColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            if metrics.processes.isEmpty && metrics.gpus.isEmpty && metrics.gpuProcesses.isEmpty {
                Panel(title: model.text("进程", "Processes")) { InfoRow(title: model.text("暂无进程数据", "No process data yet")) }
            } else {
                if !metrics.processes.isEmpty { processPanel.frame(maxWidth: .infinity) }
                if !metrics.gpus.isEmpty || !metrics.gpuProcesses.isEmpty { VStack(spacing: 16) { gpuPanels }.frame(maxWidth: .infinity) }
            }
        }
    }
    @ViewBuilder private var gpuPanels: some View {
        if !metrics.gpus.isEmpty {
            Panel(title: "GPU") {
                ForEach(Array(metrics.gpus.enumerated()), id: \.offset) { _, gpu in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(gpu.index) · \(gpu.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                        if !extras(gpu).isEmpty { Text(extras(gpu)).font(.caption).foregroundStyle(Palette.secondary).monospacedDigit() }
                        usageBar(model.text("利用率", "Utilization"), value: gpu.utilPercent, detail: percent(gpu.utilPercent))
                        if gpu.memTotalBytes != nil { usageBar(model.text("显存", "VRAM"), value: gpu.memPercent, detail: usage(gpu.memUsedBytes, gpu.memTotalBytes)) }
                        if let history = series.gpuHistory[gpu.index], history.count >= 2 { sparkline(history, tone: levelColor(gpu.utilPercent)) }
                    }.padding(16).panelDivider().accessibilityIdentifier("host-gpu-\(gpu.index)")
                }
            }
        }
        if !metrics.gpuProcesses.isEmpty {
            Panel(title: model.text("GPU 进程（按显存排序）", "GPU processes (by VRAM)")) {
                ForEach(Array(metrics.gpuProcesses.prefix(5).enumerated()), id: \.offset) { _, process in
                    processRow(process.name, first: "PID \(process.pid)", second: "\(model.text("显存", "VRAM")) \(process.memBytes.map { bytes(Double($0)) } ?? "—")").panelDivider()
                }
            }
        }
    }
    @ViewBuilder private var processPanel: some View {
        if !metrics.processes.isEmpty {
            Panel(title: model.text("进程（按 CPU 排序）", "Processes (by CPU)")) {
                ForEach(Array(metrics.processes.enumerated()), id: \.offset) { _, process in
                    processRow(process.name, first: "CPU \(percent(process.cpuPercent))", second: "\(model.text("内存", "RAM")) \(percent(process.memPercent))").panelDivider()
                }
            }
        }
    }
    private func gauge(_ title: String, value: Double?, detail: String?, history: [Double]?, id: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Palette.foreground.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, value ?? 0))) / 100).stroke(levelColor(value), style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(percent(value)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            }.padding(4).frame(width: 72, height: 72)
            Text(title).font(.caption.weight(.medium))
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if let history { sparkline(history, tone: levelColor(value)).padding(.top, 6) } else { Color.clear.frame(height: 28) }
        }.padding(12).frame(maxWidth: .infinity).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(percent(value)), \(detail ?? "")").accessibilityIdentifier(id)
    }
    private func usageBar(_ title: String, value: Double?, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(minWidth: 52, alignment: .leading)
            ProgressView(value: min(100, max(0, value ?? 0)), total: 100).tint(levelColor(value))
            Text(detail ?? "—").monospacedDigit().lineLimit(1).frame(minWidth: 72, alignment: .trailing)
        }.font(.caption).foregroundStyle(Palette.secondary)
    }
    private func sparkline(_ values: [Double], tone: Color) -> some View { Sparkline(values: values, tone: tone) }
    private func processRow(_ name: String, first: String, second: String) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(.subheadline, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(first).frame(minWidth: 72, alignment: .trailing)
            Text(second).frame(minWidth: 72, alignment: .trailing)
        }.font(.caption).foregroundStyle(Palette.secondary).monospacedDigit().padding(16)
    }
    private func extras(_ gpu: HostMetrics.Gpu) -> String {
        var parts: [String] = []
        if let frequency = gpu.freqMHz { parts.append(String(format: "%.0f", frequency) + (gpu.freqMaxMHz.map { String(format: "/%.0f", $0) } ?? "") + " MHz") }
        if let used = gpu.memUsedBytes, gpu.memTotalBytes == nil { parts.append(model.text("内存 ", "Memory ") + bytes(Double(used))) }
        if let temperature = gpu.temperatureC { parts.append(String(format: "%.0f°C", temperature)) }
        if let power = gpu.powerWatts { parts.append(String(format: "%.0f", power) + (gpu.powerLimitWatts.map { String(format: "/%.0f", $0) } ?? "") + " W") }
        return parts.joined(separator: " · ")
    }
    private func levelColor(_ value: Double?) -> Color { MetricFormat.levelColor(value) }
    private func percent(_ value: Double?) -> String { MetricFormat.percent(value) }
    private func bytes(_ value: Double) -> String { MetricFormat.bytes(value) }
    private func usage(_ used: Int64?, _ total: Int64?) -> String? { MetricFormat.usage(used, total) }
    private func uptime(_ seconds: Int64) -> String { MetricFormat.uptime(seconds, model) }
}

/// How the host page writes its readings, shared by the portrait panel and the landscape tabs.
enum MetricFormat {
    static func levelColor(_ value: Double?) -> Color {
        guard let value else { return Palette.outline }
        return value >= 90 ? Palette.danger : value >= 70 ? Palette.warning : Palette.accent
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: $0 < 10 ? "%.1f%%" : "%.0f%%", $0) } ?? "—" }
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = max(0, value), unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        return String(format: unit == 0 || size >= 100 ? "%.0f %@" : "%.1f %@", size, units[unit])
    }
    static func usage(_ used: Int64?, _ total: Int64?) -> String? {
        guard let used, let total else { return nil }
        var scale = 1.0, scaledTotal = Double(max(0, total)), unit = 0
        while scaledTotal >= 1024 && unit < 5 { scaledTotal /= 1024; scale *= 1024; unit += 1 }
        let scaledUsed = Double(max(0, used)) / scale
        return String(format: unit == 0 || scaledUsed >= 100 ? "%.0f/" : "%.1f/", scaledUsed) + bytes(Double(total))
    }
    @MainActor static func uptime(_ seconds: Int64, _ model: AppModel) -> String {
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return model.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        if hours > 0 { return model.text("\(hours) 小时 \(minutes) 分钟", "\(hours)h \(minutes)m") }
        return model.text("\(minutes) 分钟", "\(minutes)m")
    }
}

/// A reading's recent history, newest on the right, filled beneath its line.
struct Sparkline: View {
    let values: [Double]
    let tone: Color
    var height: CGFloat = 22
    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let step = size.width / CGFloat(HostMetricSeries.historyLimit - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index), y: size.height * CGFloat(1 - min(100, max(0, value)) / 100))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line; fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: start, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .color(tone.opacity(0.14)))
            context.stroke(line, with: .color(tone), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }.frame(height: height).accessibilityHidden(true)
    }
}
