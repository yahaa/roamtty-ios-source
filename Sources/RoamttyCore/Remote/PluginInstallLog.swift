import Foundation

/// A bounded line tail for package-manager output arriving in arbitrary SSH chunks.
/// Keep UTF-8 bytes together until a line ends, and hide the installer's control markers.
public struct PluginInstallLog {
    public private(set) var lines: [String] = []
    private var pending: [UInt8] = []
    private var truncated = false

    public init() {}
    public var text: String { lines.suffix(14).joined(separator: "\n") }

    public mutating func append(_ data: Data) {
        for byte in data {
            if byte == 10 || byte == 13 { finishLine() } else if pending.count < 4_096 { pending.append(byte) } else { truncated = true }
        }
    }

    public mutating func finish() { finishLine() }

    private mutating func finishLine() {
        guard !pending.isEmpty || truncated else { return }
        let line = String(decoding: pending, as: UTF8.self) + (truncated ? "…" : "")
        pending.removeAll(keepingCapacity: true); truncated = false
        guard let shown = HostPluginInstaller.displayLine(line) else { return }
        lines.append(shown)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }
}
