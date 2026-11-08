import Foundation
import Combine
import Network
import UIKit
import RoamttyCore
import RoamttyTransport
import RoamttyDesktopCore

extension AppModel {
    /// The button state for a host's session / host card (Android `DesktopButton.derive`).
    func desktopButton(for host: Host, sessionConnected: Bool, preserveOffline: Bool = false) -> DesktopButton {
        guard let manifest = try? PluginManifest.bundled() else { return .hidden }
        let phase = desktops[host.id]?.phase ?? .idle
        let offline = reachability[host.id]?.isOffline == true
        return DesktopButton.derive(
            hostOnline: preserveOffline || !offline,
            sessionConnected: sessionConnected,
            os: DesktopSupport.buttonOS(host.system),
            osSupported: DesktopSupport.osSupported(host.system, manifest: manifest),
            probe: DesktopProbe.decode(host.desktop),
            probedAt: host.desktopProbedAt,
            now: Int64(Date().timeIntervalSince1970 * 1000),
            phase: phase)
    }

    func desktopSupported(_ host: Host) -> Bool {
        return (try? PluginManifest.bundled()).map { DesktopSupport.osSupported(host.system, manifest: $0) } ?? false
    }

    /// Whether the host page offers 桌面 (Android `ItermuxScreen`): a supported OS whose probe has not
    /// found it without a graphical desktop. A host never probed keeps the button; opening it checks.
    func desktopOnHostPage(_ host: Host) -> Bool {
        desktopSupported(host) && DesktopProbe.decode(host.desktop) != .no
    }

    /// Opens the host's desktop page, starting the connection if needed.
    func openDesktop(_ host: Host) { Task { await openDesktopAsync(host) } }

    func openDesktopAsync(_ host: Host) async {
        if let existing = desktops[host.id],
           existing.host.hasSameLoginIdentity(as: host), existing.active {
            if !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            return
        }
        desktops.remove(host.id)
        do {
            let credentials = try await credentials(for: host)
            let prefs = settings.desktopHosts[host.id] ?? DesktopHostSettings()
            var config = desktopConfig(for: host)
            config.fps = prefs.fps
            config.quality = prefs.quality
            config.lockOnClose = prefs.lockOnClose
            config.audio = prefs.audio
            config.keepAliveMinutes = settings.desktopKeepAliveMinutes
            let manifest = try desktopManifest()
            let hostID = host.id
            let session = DesktopSession(config: config, manifest: manifest, login: { [weak self] in
                guard let self else { return .failed(message: nil, connecting: false) }
                return self.syncDesktopLogin(hostID: hostID, credentials: credentials)
            })
            session.onProbe = { [weak self, weak session] probe in
                Task { @MainActor in
                    guard let self, let session, self.desktops[hostID]?.session === session else { return }
                    self.saveDesktopProbe(host, probe)
                }
            }
            let controller = DesktopController(
                host: host, session: session, prefs: prefs,
                showStats: settings.desktopShowStats, english: english,
                onPrefs: { [weak self] p in self?.saveDesktopPrefs(hostID, p) },
                onEnded: { [weak self] ended in
                    guard let self, self.desktops[ended.host.id] === ended, !ended.active else { return }
                    if case .failed = ended.session.phase {
                        // Keep the failure page until an explicit retry or close, including its error text.
                        if ended.session.failure == .noDesktop {
                            self.saveDesktopProbe(ended.host, HostDesktop(desktop: "no", uname: "", pluginVersion: nil))
                        }
                    } else {
                        self.desktops.remove(ended.host.id)
                    }
                    self.objectWillChange.send()
                })
            desktops.put(controller)
            controller.start()
            startDesktopPathMonitor()
            if !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            objectWillChange.send()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A desktop session's settings for `host`, at this screen's size and in the app's language.
    func desktopConfig(for host: Host) -> DesktopSession.Config {
        let scale = UIScreen.main.scale, bounds = UIScreen.main.bounds
        var config = DesktopSession.Config(hostName: host.name, address: host.hostname, clientWidth: Int(bounds.width * scale),
                                           clientHeight: Int(bounds.height * scale), clientDpi: Int(160 * scale))
        config.english = english
        return config
    }

    func desktopManifest() throws -> PluginManifest {
        let pinned = try PluginManifest.bundled()
        let base = settings.desktopPluginBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? pinned : pinned.withBaseUrl(base)
    }

    /// Blocking login for the desktop worker thread: a fresh SSH connection of its own (Android's pageLogin).
    nonisolated private func syncDesktopLogin(hostID: String, credentials: Credentials) -> DesktopLogin {
        let host: Host? = DispatchQueue.main.sync { self.host(hostID) }
        guard let host else { return .failed(message: nil, connecting: false) }
        do {
            let ssh = try DispatchQueue.main.sync { try self.makeConnection(host, credentials: credentials, owner: "desktop-\(hostID)") }
            try ssh.connect()
            return .host(SSHDesktopHost(connection: ssh))
        } catch let error as RoamError {
            if case .authentication = error {
                return .failed(message: DispatchQueue.main.sync { self.text("认证失败", "Authentication failed") }, connecting: false)
            }
            return .failed(message: error.localizedDescription, connecting: true)
        } catch {
            return .failed(message: error.localizedDescription, connecting: true)
        }
    }

    func closeDesktop(_ hostID: String) {
        desktops.remove(hostID)
        path.removeAll { $0 == .desktop(hostID) }
        objectWillChange.send()
    }

    func saveDesktopPrefs(_ hostID: String, _ prefs: DesktopHostSettings) {
        settings.desktopHosts[hostID] = prefs
        saveSettings()
    }

    func saveDesktopProbe(_ host: Host, _ probe: HostDesktop) {
        guard var current = self.host(host.id), current.hasSameLoginIdentity(as: host) else { return }
        current.desktop = probe.desktop
        current.desktopProbedAt = Int64(Date().timeIntervalSince1970 * 1000)
        do { try store?.saveHost(current); hosts = try store?.hosts() ?? hosts } catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }

    /// Read-only desktop probe over the host's shared connection (host page / session connect).
    func refreshDesktopProbe(_ host: Host) async {
        // Best-effort: never ask for a password just to look. The monitor runs it again once the user logs in.
        guard connections[host.id]?.isConnected == true || canLoginSilently(host) else { return }
        do {
            let ssh = try await connection(for: host.id)
            let found = try await performInBackground { DesktopProbeScript.probe(SSHDesktopHost(connection: ssh)) }
            if let found { saveDesktopProbe(host, found) }
        } catch { /* probe is best-effort */ }
    }

    func startDesktopPathMonitor() {
        // Already running.
        if desktopPathMonitor != nil { return }
        let monitor = NWPathMonitor()
        desktopPathMonitor = monitor
        // Updates come one at a time on this serial queue, the only place `last` is touched.
        let queue = DispatchQueue(label: "roamtty.desktop.path", qos: .utility)
        final class Last: @unchecked Sendable { var interface: String?? }
        let last = Last()
        monitor.pathUpdateHandler = { [weak self] path in
            let current = Self.defaultInterface(path)
            let change = NetworkChange.between(last.interface, current)
            last.interface = .some(current)
            guard let change else { return }
            DispatchQueue.main.async { self?.desktopStore?.networkChanged(change) }
        }
        monitor.start(queue: queue)
    }

    /// The interface the traffic goes out on ("cellular:pdp_ip0"), nil without one. A VPN's tunnel
    /// (Tailscale's utun, type other) is not it: its updates leave the network the same.
    nonisolated static func defaultInterface(_ path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        guard let i = path.availableInterfaces.first(where: { kinds.contains($0.type) }) else { return nil }
        return "\(i.type):\(i.name)"
    }
}
