// Behavioral port of Roamtty Android's app/session/HostMetrics.kt.
import Foundation

public struct HostMetrics: Equatable, Sendable {
    public struct Disk: Equatable, Sendable {
        public var mount: String
        public var totalBytes: Int64
        public var usedBytes: Int64
        public var availableBytes: Int64
        public var percent: Double { let total = Double(usedBytes) + Double(availableBytes); return total > 0 ? 100 * Double(usedBytes) / total : 0 }
        public init(mount: String, totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
            self.mount = mount
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
            self.availableBytes = availableBytes
        }
    }
    public struct Process: Equatable, Sendable {
        public var name: String
        public var cpuPercent: Double
        public var memPercent: Double
        public init(name: String, cpuPercent: Double, memPercent: Double) { self.name = name; self.cpuPercent = cpuPercent; self.memPercent = memPercent }
    }
    public struct Gpu: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var utilPercent: Double?
        public var memUsedBytes: Int64?
        public var memTotalBytes: Int64?
        public var temperatureC: Double?
        public var powerWatts: Double?
        public var powerLimitWatts: Double?
        public var freqMHz: Double?
        public var freqMaxMHz: Double?
        public var memPercent: Double? { guard let used = memUsedBytes, let total = memTotalBytes, total > 0 else { return nil }; return 100 * Double(used) / Double(total) }
        public init(index: Int, name: String, utilPercent: Double? = nil, memUsedBytes: Int64? = nil, memTotalBytes: Int64? = nil,
                    temperatureC: Double? = nil, powerWatts: Double? = nil, powerLimitWatts: Double? = nil, freqMHz: Double? = nil, freqMaxMHz: Double? = nil) {
            self.index = index; self.name = name; self.utilPercent = utilPercent; self.memUsedBytes = memUsedBytes; self.memTotalBytes = memTotalBytes
            self.temperatureC = temperatureC; self.powerWatts = powerWatts; self.powerLimitWatts = powerLimitWatts; self.freqMHz = freqMHz; self.freqMaxMHz = freqMaxMHz
        }
    }
    public struct GpuProcess: Equatable, Sendable {
        public var pid: Int64
        public var name: String
        public var memBytes: Int64?
        public init(pid: Int64, name: String, memBytes: Int64?) { self.pid = pid; self.name = name; self.memBytes = memBytes }
    }

    public var hostname: String?
    public var os: String?
    public var kernel: String?
    public var arch: String?
    public var cpuModel: String?
    public var cpus: Int?
    public var cpuPercent: Double?
    public var load: [Double] = []
    public var tasks: String?
    public var uptimeSeconds: Int64?
    public var memTotalBytes: Int64?
    public var memAvailableBytes: Int64?
    public var swapTotalBytes: Int64?
    public var swapFreeBytes: Int64?
    public var disks: [Disk] = []
    public var netRxBytes: Int64?
    public var netTxBytes: Int64?
    public var users: Int?
    public var processes: [Process] = []
    public var gpus: [Gpu] = []
    public var gpuProcesses: [GpuProcess] = []
    public init() {}
    public var memUsedBytes: Int64? { Self.used(total: memTotalBytes, available: memAvailableBytes) }
    public var swapUsedBytes: Int64? { Self.used(total: swapTotalBytes, available: swapFreeBytes) }
    public var memPercent: Double? { guard let used = memUsedBytes, let total = memTotalBytes, total > 0 else { return nil }; return 100 * Double(used) / Double(total) }

    /// Exact POSIX script from the Android source. Missing tools leave their readings unknown.
    public static var script: String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "HostMetrics", withExtension: "sh"), let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("HostMetrics.sh is missing from the app resources")
        }
        return source
    }

    public static func parse(_ text: String) -> HostMetrics {
        var values: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let at = line.firstIndex(of: "="), at != line.startIndex else { continue }
            values[String(line[..<at]).trimmingCharacters(in: .whitespaces), default: []].append(String(line[line.index(after: at)...]).trimmingCharacters(in: .whitespaces))
        }
        func one(_ key: String) -> String? { values[key]?.first.flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> Int64? { one(key).flatMap(Int64.init) }
        func bytes(_ kb: String, _ fallback: String? = nil) -> Int64? {
            if let value = number(kb), let scaled = multiply(value, 1024) { return scaled }
            return fallback.flatMap(number)
        }
        var m = HostMetrics()
        m.hostname = one("hostname"); m.os = one("os"); m.kernel = one("kernel"); m.arch = one("arch")
        m.cpuModel = one("model")?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        m.cpus = number("cpus").flatMap { $0 > 0 ? Int(exactly: $0) : nil }
        m.cpuPercent = cpuPercent(one("cpu1"), one("cpu2")) ?? reading(one("idle")).map { min(100, max(0, 100 - $0)) }
        let load = fields(one("load") ?? "")
        m.load = load.prefix(3).compactMap(reading)
        if load.count > 3, load[3].contains("/") { m.tasks = load[3] }
        m.uptimeSeconds = reading(one("uptime")).flatMap(integer)
        m.memTotalBytes = bytes("kb_MemTotal", "bytes_MemTotal"); m.memAvailableBytes = bytes("kb_MemAvailable", "bytes_MemAvailable")
        m.swapTotalBytes = bytes("kb_SwapTotal"); m.swapFreeBytes = bytes("kb_SwapFree")
        m.disks = (values["disk"] ?? []).compactMap { row in
            let parts = fields(row, limit: 4)
            guard parts.count == 4, let total = Int64(parts[0]).flatMap({
                multiply($0, 1024)
            }), let used = Int64(parts[1]).flatMap({
                multiply($0, 1024)
            }), let available = Int64(parts[2]).flatMap({
                multiply($0, 1024)
            }) else { return nil }
            return Disk(mount: parts[3], totalBytes: total, usedBytes: used, availableBytes: available)
        }
        let net = fields(one("net") ?? "").compactMap(Int64.init)
        m.netRxBytes = net.first; if net.count > 1 { m.netTxBytes = net[1] }
        m.users = number("users").flatMap(Int.init(exactly:))
        m.processes = (values["proc"] ?? []).compactMap { row in
            let parts = fields(row, limit: 3)
            guard parts.count == 3, let cpu = reading(parts[0]), let mem = reading(parts[1]) else { return nil }
            let name = basename(parts[2]); guard !name.isEmpty else { return nil }
            return Process(name: name, cpuPercent: cpu, memPercent: mem)
        }
        m.gpus = (values["gpu"] ?? []).compactMap(nvidiaGpu)
        var others = (values["amdgpu"] ?? []).compactMap(amdGpu)
        others += (values["igpu"] ?? []).compactMap { intelGpu($0, before: values["rc6a"] ?? [], after: values["rc6b"] ?? []) }
        others += (values["macgpu"] ?? []).compactMap(macGpu)
        let firstOther = (m.gpus.map(\.index).max() ?? -1) + 1
        for (offset, var gpu) in others.enumerated() { gpu.index = firstOther + offset; m.gpus.append(gpu) }
        m.gpuProcesses = (values["gpuproc"] ?? []).compactMap { row in
            let parts = csv(row)
            guard parts.count >= 3, let pid = Int64(parts[0]) else { return nil }
            let name = basename(parts.dropFirst().dropLast().joined(separator: ", ")); guard !name.isEmpty else { return nil }
            return GpuProcess(pid: pid, name: name, memBytes: mib(parts.last))
        }.sorted { ($0.memBytes ?? -1) > ($1.memBytes ?? -1) }
        return m
    }

    static func cpuPercent(_ first: String?, _ second: String?) -> Double? {
        func ticks(_ line: String?) -> [Double]? {
            guard let line else { return nil }
            let values = fields(line).dropFirst().prefix(8).compactMap { Int64($0).map(Double.init) }
            return values.count >= 5 ? values : nil
        }
        guard let a = ticks(first), let b = ticks(second) else { return nil }
        let total = b.reduce(0, +) - a.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, 100 * (total - ((b[3] + b[4]) - (a[3] + a[4]))) / total))
    }

    private static func nvidiaGpu(_ row: String) -> Gpu? {
        let parts = csv(row)
        guard parts.count >= 8, let rawIndex = Int32(parts[0]) else { return nil }
        let index = Int(rawIndex)
        let tail = Array(parts.suffix(6)), name = parts.dropFirst().dropLast(6).joined(separator: ", ")
        return Gpu(index: index, name: name.isEmpty ? "GPU \(index)" : name, utilPercent: reading(tail[0]), memUsedBytes: mib(tail[1]),
            memTotalBytes: mib(tail[2]), temperatureC: reading(tail[3]), powerWatts: reading(tail[4]), powerLimitWatts: reading(tail[5]))
    }
    private static func amdGpu(_ row: String) -> Gpu? {
        let parts = fields(row, limit: 7); guard parts.count >= 6 else { return nil }
        return Gpu(index: 0, name: parts.count > 6 ? parts[6] : "AMD GPU", utilPercent: reading(parts[0]),
                   memUsedBytes: reading(parts[1]).flatMap(integer), memTotalBytes: reading(parts[2]).flatMap(integer),
                   temperatureC: reading(parts[3]).map { $0 / 1000 }, powerWatts: reading(parts[4]).map { $0 / 1_000_000 },
                   powerLimitWatts: reading(parts[5]).flatMap { $0 > 0 ? $0 / 1_000_000 : nil })
    }
    private static func intelGpu(_ row: String, before: [String], after: [String]) -> Gpu? {
        let parts = fields(row, limit: 4); guard parts.count >= 3 else { return nil }
        func rc6(_ lines: [String]) -> (Double, Double)? {
            guard let row = lines.map({ fields($0) }).first(where: { $0.count == 3 && $0[0] == parts[0] }), let uptime = reading(row[1]), let idle = reading(row[2]) else { return nil }
            return (uptime * 1000, idle)
        }
        var busy: Double?
        if let a = rc6(before), let b = rc6(after), b.0 > a.0 { busy = min(100, max(0, 100 * (1 - (b.1 - a.1) / (b.0 - a.0)))) }
        let name = parts.count > 3 ? (parts[3].hasPrefix("Intel") ? parts[3] : "Intel " + parts[3]) : "Intel GPU"
        return Gpu(index: 0, name: name, utilPercent: busy, freqMHz: reading(parts[1]), freqMaxMHz: reading(parts[2]))
    }
    private static func macGpu(_ row: String) -> Gpu? {
        let parts = fields(row, limit: 3); guard parts.count >= 2 else { return nil }
        return Gpu(index: 0, name: parts.count > 2 ? parts[2] : "GPU", utilPercent: reading(parts[0]), memUsedBytes: Int64(parts[1]))
    }
    private static func fields(_ value: String, limit: Int = Int.max) -> [String] { value.split(maxSplits: limit - 1, whereSeparator: \.isWhitespace).map(String.init) }
    private static func csv(_ value: String) -> [String] { value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
    private static func basename(_ value: String) -> String { value.split(separator: "/").last.map(String.init) ?? "" }
    private static func reading(_ value: String?) -> Double? { guard let value, let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }; return number }
    private static func integer(_ value: Double) -> Int64? { value.isFinite && value >= Double(Int64.min) && value < Double(Int64.max) ? Int64(value) : nil }
    private static func mib(_ value: String?) -> Int64? { reading(value).flatMap { integer($0 * 1_048_576) } }
    private static func multiply(_ value: Int64, _ factor: Int64) -> Int64? { let result = value.multipliedReportingOverflow(by: factor); return result.overflow ? nil : result.partialValue }
    private static func used(total: Int64?, available: Int64?) -> Int64? {
        guard let total, let available else { return nil }
        let difference = total.subtractingReportingOverflow(available)
        return difference.overflow ? nil : max(0, difference.partialValue)
    }
}
