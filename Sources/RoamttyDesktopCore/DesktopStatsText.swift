import Foundation

/// The lines the stats overlay shows over the picture (Android `NetworkStats`), without UIKit.
/// Colours are named so the page can map them; thresholds match Android.
public enum DesktopStatsText {
    public enum Tone: Equatable, Sendable { case ink, dim, warn, bad }

    public struct Line: Equatable, Sendable {
        public let text: String
        public let tone: Tone
        public init(_ text: String, _ tone: Tone = .ink) { self.text = text; self.tone = tone }
    }

    /// Wi-Fi / 移动数据 / 以太网 / —, as Android's `transportName`.
    public enum Transport: String, Sendable { case wifi = "Wi-Fi", cellular, ethernet, unknown = "—"
        public func label(english: Bool) -> String {
            switch self {
            case .wifi, .ethernet, .unknown: return rawValue
            case .cellular: return english ? "Cellular" : "移动数据"
            }
        }
    }

    private static func msTone(_ v: Int?, slow: Int, verySlow: Int) -> Tone {
        guard let v else { return .ink }
        if v >= verySlow { return .bad }
        if v >= slow { return .warn }
        return .ink
    }

    private static func sum(_ parts: Double?...) -> Int? {
        let xs = parts.compactMap { $0 }
        return xs.isEmpty ? nil : Int(xs.reduce(0, +).rounded())
    }

    /// The badge when 显示网络状态 is off: only a poor or recovering link still says so.
    public static func warning(poor: Bool, recovering: Bool, english: Bool) -> Line? {
        if recovering { return Line(english ? "Recovering" : "恢复中", .dim) }
        if poor { return Line(english ? "Poor network" : "网络较差", .warn) }
        return nil
    }

    /// The full overlay when 显示网络状态 is on.
    public static func lines(stats: DesktopStats, poor: Bool, recovering: Bool, transport: Transport,
                             english: Bool) -> [Line] {
        let e2e = english ? "End-to-end" : "端到端"
        let host = english ? "Host" : "主机端"
        let net = english ? "Network" : "网络"
        let phone = english ? "Phone" : "手机端"
        let loss = english ? "Loss" : "丢包"
        let recoveringLabel = english ? "Recovering" : "恢复中"
        let l = stats.latency
        let total = l.flatMap { $0.totalMs.map { Int($0.rounded()) } }
        var out: [Line] = []
        let link = recovering ? recoveringLabel : stats.link
        let rtt = stats.rttMs.map { "\($0) ms" } ?? "—"
        out.append(Line("\(link) \(rtt)", poor ? .warn : msTone(stats.rttMs, slow: 80, verySlow: 150)))
        let mbps = String(format: "%.1f", Double(stats.kbps) / 1000.0)
        out.append(Line("\(stats.fps) fps  \(mbps) Mbps"))
        out.append(Line("\(e2e) \(total.map { "\($0) ms" } ?? "—")", msTone(total, slow: 100, verySlow: 200)))
        if let l {
            let h = sum(l.captureMs, l.convertMs, l.encodeMs).map(String.init) ?? "—"
            let n = l.networkMs.map { "\(Int($0.rounded()))" } ?? "—"
            let p = sum(l.decodeMs, l.renderMs).map(String.init) ?? "—"
            out.append(Line("\(host) \(h) · \(net) \(n) · \(phone) \(p)", .dim))
        }
        if let pct = stats.lossPercent {
            var t = "\(loss) \(String(format: "%.1f", pct))%"
            if stats.fecRecovered > 0 { t += "  FEC \(stats.fecRecovered)" }
            out.append(Line(t, pct >= 5 ? .warn : .ink))
        }
        var size = stats.width > 0 ? "\(stats.width)×\(stats.height)" : "—"
        if !stats.encoder.isEmpty { size += " \(stats.encoder)" }
        out.append(Line(size, .dim))
        if let ms = stats.audioMs { out.append(Line(english ? "Sound buffered \(ms) ms" : "声音 缓冲 \(ms) ms", .dim)) }
        out.append(Line(transport.label(english: english), .dim))
        return out
    }
}
