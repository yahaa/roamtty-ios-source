import Foundation
import RoamttyCore
import RoamttyTransport

/// The host page's live metrics: sampled every few seconds over the host's shared connection while the page shows.
extension AppModel {
    func startMonitor(_ host: Host, interactive: Bool = false) {
        guard foreground, monitorJobs[host.id] == nil else { return }
        let hasSecret = connections[host.id]?.isConnected == true || host.auth != .password || (try? vault.read(hostID: host.id, purpose: .password)) != nil || credentialCache[host.id] != nil
        guard interactive || hasSecret else { return }
        let token = UUID(), cancellation = TransferCancellation()
        monitorStates[host.id] = HostMonitorState(phase: .connecting)
        let task = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && !cancellation.isCancelled && self.foreground && self.monitorJobs[host.id]?.token == token }
            defer { if self.monitorJobs[host.id]?.token == token { self.monitorJobs.removeValue(forKey: host.id) } }
            var retry = 0, probedDesktop = false
            while current() {
                var samplingConnection: SSHConnection?
                do {
                    let ssh = try await self.connection(for: host.id)
                    guard current() else { return }
                    samplingConnection = ssh
                    self.monitorStates[host.id] = HostMonitorState(phase: .connected)
                    // The page's own probe skips logins that need typing; this one rides the login just made.
                    if !probedDesktop { probedDesktop = true; Task { await self.refreshDesktopProbe(host) } }
                    var series = self.metricSeries[host.id] ?? HostMetricSeries()
                    series.resetNetworkBaseline()
                    while current() {
                        let result = try await ssh.run(RemoteCommands.shell(HostMetrics.script), timeout: 10, cancellation: cancellation)
                        guard current() else { return }
                        let value = HostMetrics.parse(result.text)
                        // The collectors ran but returned nothing usable: the host refused the queries. A lost login
                        // (timeout, dropped connection) throws instead and reconnects, keeping the last sample.
                        guard result.status == 0, value.cpuPercent != nil || value.memPercent != nil || !value.disks.isEmpty else {
                            self.metrics.removeValue(forKey: host.id); series.resetNetworkBaseline(); self.metricSeries[host.id] = series
                            self.monitorStates[host.id] = HostMonitorState(phase: .connected, samplingFailed: true)
                            return
                        }
                        series.observe(value, timestamp: ProcessInfo.processInfo.systemUptime)
                        self.metrics[host.id] = value
                        self.metricSeries[host.id] = series
                        self.monitorStates[host.id] = HostMonitorState(phase: .connected, sampled: true)
                        retry = 0
                        try await Task.sleep(for: .seconds(3))
                    }
                } catch {
                    guard current() else { return }
                    // A channel can observe cancellation after another channel detected a dead socket.
                    // Only that established, dead connection is retryable; cancelling authentication is not.
                    let failure: Error = (error as? RoamError) == .cancelled && samplingConnection?.isConnected == false
                        ? RoamError.transport(self.text("监控连接已关闭", "Monitor connection closed")) : error
                    retry += 1
                    guard let delay = HostMonitorRetry.delay(after: failure, attempt: retry, interactive: host.auth == .interactive) else {
                        self.monitorStates[host.id] = HostMonitorState(phase: ConnectionPhase(failure: failure), detail: failure.localizedDescription)
                        return
                    }
                    self.monitorStates[host.id] = HostMonitorState(phase: .connecting, reconnecting: true, detail: failure.localizedDescription)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
        monitorJobs[host.id] = TrackedTask(token: token, task: task, cancellation: cancellation)
    }
    func stopMonitor(_ id: String) {
        monitorJobs.removeValue(forKey: id)?.cancel()
        if monitorStates[id]?.phase.active == true { monitorStates[id] = HostMonitorState(phase: .disconnected) }
    }
    /// Restarts the monitor of the host page on screen, after a login change stopped it.
    func restartVisibleMonitor() {
        guard foreground, case .host(let id) = path.last, let host = host(id) else { return }
        startMonitor(host)
    }
}
