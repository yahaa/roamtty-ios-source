import Foundation

/// Android's monitor retries only network/sample failures, never rejected or typed logins.
public enum HostMonitorRetry {
    public static func delay(after error: Error, attempt: Int, interactive: Bool) -> TimeInterval? {
        guard !interactive, (1...5).contains(attempt), let error = error as? RoamError else { return nil }
        switch error {
        case .transport, .timeout: return [2.0, 4, 8, 16, 30][attempt - 1]
        default: return nil
        }
    }
}

/// The rolling charts and network throughput used by Android's HostMonitor.
/// Keep one value per host and observe it on the monitor's owning actor or queue.
public struct HostMetricSeries: Equatable, Sendable {
    public static let historyLimit = 40

    public struct NetworkRate: Equatable, Sendable {
        public let rxBytesPerSecond: Double
        public let txBytesPerSecond: Double

        public init(rxBytesPerSecond: Double, txBytesPerSecond: Double) {
            self.rxBytesPerSecond = rxBytesPerSecond
            self.txBytesPerSecond = txBytesPerSecond
        }
    }

    public private(set) var cpuHistory: [Double] = []
    public private(set) var memHistory: [Double] = []
    public private(set) var gpuHistory: [Int: [Double]] = [:]
    public private(set) var netRate: NetworkRate?

    private struct NetworkSample: Equatable, Sendable {
        let rx: Int64?
        let tx: Int64?
        let timestamp: TimeInterval
    }
    private var previousNetwork: NetworkSample?

    public init() {}

    /// `timestamp` is elapsed monotonic seconds, such as ProcessInfo.systemUptime.
    /// Unknown readings do not add chart points; absent GPUs lose their histories.
    public mutating func observe(_ metrics: HostMetrics, timestamp: TimeInterval) {
        updateNetworkRate(metrics, timestamp: timestamp)
        Self.append(metrics.cpuPercent, to: &cpuHistory)
        Self.append(metrics.memPercent, to: &memHistory)
        var currentGPUHistory: [Int: [Double]] = [:]
        for gpu in metrics.gpus {
            var history = gpuHistory[gpu.index] ?? []
            Self.append(gpu.utilPercent, to: &history)
            currentGPUHistory[gpu.index] = history
        }
        gpuHistory = currentGPUHistory
    }

    /// Call when a new monitor connection starts. Android retains the displayed
    /// histories and rate while waiting for two samples from the new connection.
    public mutating func resetNetworkBaseline() {
        previousNetwork = nil
    }

    private mutating func updateNetworkRate(_ metrics: HostMetrics, timestamp: TimeInterval) {
        let current = NetworkSample(rx: metrics.netRxBytes, tx: metrics.netTxBytes, timestamp: timestamp)
        // Every sample replaces the baseline, even when its counters are absent
        // or reset. This avoids silently averaging across unavailable samples.
        defer { previousNetwork = current }
        guard let previous = previousNetwork,
              timestamp.isFinite, previous.timestamp.isFinite,
              timestamp >= 0, previous.timestamp >= 0,
              let rx = current.rx, let tx = current.tx, let lastRx = previous.rx, let lastTx = previous.tx,
              lastRx >= 0, lastTx >= 0, rx >= lastRx, tx >= lastTx else { return }
        let seconds = timestamp - previous.timestamp
        guard seconds.isFinite, seconds > 0 else { return }
        // Subtract integers first so a small delta in a large counter is not
        // rounded away. Ordered nonnegative Int64 values cannot overflow here.
        let received = Double(rx - lastRx) / seconds
        let sent = Double(tx - lastTx) / seconds
        guard received.isFinite, sent.isFinite else { return }
        netRate = NetworkRate(rxBytesPerSecond: received, txBytesPerSecond: sent)
    }

    private static func append(_ value: Double?, to history: inout [Double]) {
        guard let value, value.isFinite else { return }
        history.append(value)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }
}
