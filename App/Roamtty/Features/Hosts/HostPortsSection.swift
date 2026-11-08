import SwiftUI
import RoamttyCore
import RoamttyTransport

/// Android's `HostPortsSection` (roamtty #275): the host's listening ports, read over the page's login, each by the
/// command line and folder of the process behind it, not a guess at the service. Whether it serves a web page shows
/// once tapped, which opens it in `PortPreviewScreen`. Hidden until the list is read; read again when the page comes
/// back, as from a preview.
struct HostPortsSection: View {
    @EnvironmentObject private var model: AppModel
    let host: Host
    @State private var ports: [ListeningPort]?
    @State private var reads = 0
    @State private var preview: PortPreviewRequest?
    /// The page's monitor holds the host's login: the list is read once it is up.
    private var ready: Bool { model.monitorStates[host.id]?.phase == .connected }

    var body: some View {
        Group {
            if let ports {
                Panel(title: model.text("端口", "Ports")) {
                    if ports.isEmpty { InfoRow(title: model.text("没有在监听的端口", "No listening ports")) }
                    ForEach(Array(ports.enumerated()), id: \.element.port) { index, port in
                        Button { open(port) } label: { row(port) }.buttonStyle(.plain).panelDivider(index < ports.count - 1)
                            .accessibilityIdentifier("host-port-\(port.port)")
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("host-ports")
            } else {
                // A modifier on an empty group never runs: this keeps the read below alive until there is a list.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .task(id: "\(ready)-\(reads)") { await read() }
        .fullScreenCover(item: $preview, onDismiss: { reads += 1 }) { PortPreviewScreen(request: $0).environmentObject(model) }
    }

    private func row(_ port: ListeningPort) -> some View {
        HStack(spacing: 12) {
            Text(String(port.port)).font(.system(.subheadline, design: .monospaced).weight(.semibold)).frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if port.pid == nil {
                    Text(model.text("其他用户的进程（root / Docker）", "Another user's process (root / Docker)")).foregroundStyle(Palette.secondary).lineLimit(1)
                } else {
                    Text(port.shortCommand.isEmpty ? "PID \(port.pid ?? 0)" : port.shortCommand).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                    if !port.directory.isEmpty { Text(port.directory).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            AppIcon("ic_chevron_right", size: 18).foregroundStyle(Palette.secondary)
        }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52).contentShape(Rectangle())
    }

    private func open(_ port: ListeningPort) {
        let id = host.id, model = self.model
        preview = PortPreviewRequest(url: port.url, hostName: host.name) { try await model.connection(for: id) }
    }

    /// The ports the host listens on; nothing changes when the login is not up or the host cannot tell (Windows, or
    /// neither `ss` nor `lsof`).
    private func read() async {
        guard ready, HostSystem(rawValue: host.system) != .WINDOWS else { return }
        do {
            let ssh = try await model.connection(for: host.id)
            let result = try await ssh.runScript(ListeningPort.script, timeout: 10)
            guard !Task.isCancelled, result.status == 0 else { return }
            ports = ListeningPort.parse(result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        } catch { }
    }
}
