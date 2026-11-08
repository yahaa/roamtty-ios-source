import SwiftUI
import WebKit
import RoamttyCore
import RoamttyTransport

/// The SSH login a port preview rides on. Each forwarded connection reads it afresh, so a retry after a dropped and
/// restored login carries on with the same tunnel.
final class PortPreviewLogin: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: SSHConnection?
    var current: SSHConnection? {
        get { lock.lock(); defer { lock.unlock() }; return connection }
        set { lock.lock(); connection = newValue; lock.unlock() }
    }
    /// Blocking; on the tunnel's threads.
    func openSocket(host: String, port: Int) throws -> TunnelStream {
        guard let ssh = current, ssh.isConnected else { throw PortTunnelError.unavailable }
        return try ssh.openSocket(host: host, port: port)
    }
}

/// A server page to show: the address the server reaches it at and how to log in to that server.
struct PortPreviewRequest: Identifiable {
    let url: LoopbackUrl
    let hostName: String
    /// The login to ride on: the terminal's own, or the host page's shared one.
    let connect: @MainActor () async throws -> SSHConnection
    let id = UUID()
}

/// Android's `PortPreviewPage` (roamtty #275): a page a server serves on its own loopback (a dev server's
/// `http://localhost:5173/`), shown on the phone through a tunnel over the server's SSH login, which connects to the
/// port for each request. The tunnel lives as long as the page. Only back, the address and refresh: back steps
/// through the page's history, then closes it.
struct PortPreviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PortPreviewRequest
    private enum Status { case checking, ready, notListening, offline, prohibited, failed }
    @State private var tunnel: PortTunnel?
    @State private var login = PortPreviewLogin()
    @State private var status = Status.checking
    /// Bumped by retry and refresh: log in again if need be and check the port, then reload the page (`reloads`).
    @State private var attempt = 0
    /// Bumped once the login and the port are back: only then does the page reload, so it never asks a dropped login.
    @State private var reloads = 0
    /// The one login under way: a check and a failed page that both find the login gone wait on the same one.
    @State private var reconnecting: Task<Void, Never>?
    /// Bumped when the page failed to load: check whether the server went away, without loading again.
    @State private var failures = 0
    @State private var page = WebPageState()
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                // Made only once the port answers, so an empty page does not flash first.
                if let tunnel, status == .ready || loaded {
                    PortWebView(start: URL(string: request.url.through(tunnel.localPort)), page: $page, reload: reloads) { failures += 1 }
                        .onAppear { loaded = true }.accessibilityIdentifier("port-preview-web")
                }
                if status != .ready { problem.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background) }
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .accessibilityElement(children: .contain).accessibilityIdentifier("port-preview")
        .task(id: attempt) { await check() }
        .task(id: failures) {
            guard failures > 0 else { return }
            let (found, reconnected) = await listening()
            // The page failed on a login that has since come back: load it again. Failing with the login up and the
            // port answering is the page's own failure, which it shows; reloading that would only repeat it.
            if found == .ready { if reconnected { reloads += 1 } } else { status = found }
        }
        .onDisappear {
            // Closing ends SSH channels, which may wait on the network.
            let open = tunnel
            DispatchQueue.global(qos: .utility).async { open?.close() }
        }
    }

    private var address: String {
        guard let tunnel, let current = page.url else { return request.url.display }
        return LoopbackUrl.fromTunnel(current, localPort: tunnel.localPort, port: request.url.port, host: request.url.host)?.display ?? current
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                AppIcon("ic_chevron_left", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(page.canGoBack && status == .ready ? model.text("上一页", "Previous page") : model.text("关闭预览", "Close preview"))
                .accessibilityIdentifier("port-preview-back")
            VStack(alignment: .leading, spacing: 1) {
                if !page.title.isEmpty { Text(page.title).font(.subheadline.weight(.semibold)).lineLimit(1).accessibilityIdentifier("port-preview-title") }
                Text("\(request.hostName) · \(address)").font(page.title.isEmpty ? .subheadline.weight(.semibold) : .caption)
                    .foregroundStyle(page.title.isEmpty ? Palette.foreground : Palette.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("port-preview-address")
            }.frame(maxWidth: .infinity, alignment: .leading)
            BarIconButton(icon: "ic_refresh", label: model.text("刷新", "Refresh"), id: "port-preview-refresh") { attempt += 1 }
        }.padding(.horizontal, 4).frame(minHeight: 52)
    }

    @ViewBuilder private var problem: some View {
        VStack(spacing: 12) {
            if status == .checking {
                ProgressView().accessibilityIdentifier("port-preview-checking")
            } else {
                Text(problemTitle).font(.headline).multilineTextAlignment(.center).accessibilityIdentifier("port-preview-problem")
                Text(problemDetail).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                Button(model.text("重试", "Retry")) { attempt += 1 }.buttonStyle(RoamButtonStyle(filled: true)).padding(.top, 8)
                    .accessibilityIdentifier("port-preview-retry")
            }
        }.padding(24)
    }
    private var problemTitle: String {
        switch status {
        case .notListening: return model.text("\(request.hostName) 上 :\(request.url.port) 没有在监听", "Nothing is listening on :\(request.url.port) on \(request.hostName)")
        case .failed: return model.text("无法在手机上打开预览", "Cannot open the preview on this phone")
        case .prohibited: return model.text("\(request.hostName) 不允许端口转发", "\(request.hostName) does not allow port forwarding")
        default: return model.text("SSH 连接未就绪", "SSH connection is not ready")
        }
    }
    private var problemDetail: String {
        switch status {
        case .notListening: return model.text("启动服务后点重试。", "Start the server, then tap Retry.")
        case .prohibited: return model.text("服务器的 sshd 关闭了 TCP 转发（AllowTcpForwarding），开启后点重试。",
                                            "The server's sshd turns TCP forwarding off (AllowTcpForwarding). Turn it on, then tap Retry.")
        default: return model.text("连接恢复后点重试。", "Tap Retry once the connection is back.")
        }
    }

    private func back() {
        if status == .ready && page.canGoBack { page.goBack() } else { dismiss() }
    }

    private func check() async {
        status = .checking
        if tunnel == nil {
            let login = self.login
            do {
                tunnel = try PortTunnel(target: request.url.target, port: request.url.port) { host, port in try login.openSocket(host: host, port: port) }
            } catch { status = .failed; return }
        }
        let found = await listening().status
        guard !Task.isCancelled else { return }
        status = found
        // A retry or refresh of a page already shown reloads it now the login and port are back; a page shown for
        // the first time loads itself.
        if found == .ready && loaded { reloads += 1 }
    }

    /// Logs in again when the login went (`reconnected`), then asks the server whether the port answers.
    private func listening() async -> (status: Status, reconnected: Bool) {
        let reconnected = await reconnect()
        guard let tunnel else { return (.failed, reconnected) }
        do {
            let answers = try await performInBackground { try tunnel.listening() }
            return (answers ? .ready : .notListening, reconnected)
        } catch PortTunnelError.prohibited {
            return (.prohibited, reconnected)
        } catch {
            return (.offline, reconnected)
        }
    }

    /// Whether the login had gone; if so, it is back once this returns, unless logging in failed.
    private func reconnect() async -> Bool {
        if login.current?.isConnected == true { return false }
        if let reconnecting { await reconnecting.value; return true }
        let login = self.login, connect = request.connect
        let task = Task { @MainActor in login.current = try? await connect() }
        reconnecting = task
        await task.value
        reconnecting = nil
        return true
    }
}

/// What the page in the web view is showing, for the bar.
struct WebPageState {
    var title = ""
    var url: String?
    var canGoBack = false
    fileprivate weak var view: WKWebView?
    func goBack() { view?.goBack() }
}

private struct PortWebView: UIViewRepresentable {
    let start: URL?
    @Binding var page: WebPageState
    /// A change reloads the page.
    let reload: Int
    let onFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Each preview keeps its cookies and storage to itself and leaves nothing behind.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        context.coordinator.observe(view)
        context.coordinator.reload = reload
        if let start { view.load(URLRequest(url: start)) }
        DispatchQueue.main.async { page.view = view }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reload != reload {
            context.coordinator.reload = reload
            if view.url == nil, let start { view.load(URLRequest(url: start)) } else { view.reload() }
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.observations = []
        view.stopLoading()
        view.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PortWebView
        var reload = 0
        var observations: [NSKeyValueObservation] = []
        init(_ parent: PortWebView) { self.parent = parent }

        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in self?.publish(view) },
                view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in self?.publish(view) },
                view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in self?.publish(view) }
            ]
        }
        private func publish(_ view: WKWebView) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Pages without a <title> report their address, which the second line already shows.
                let title = view.title ?? ""
                let shown = title.hasPrefix("http://") || title.hasPrefix("localhost:") || title.hasPrefix("127.") ? "" : title
                let url = view.url?.absoluteString
                self.parent.page = WebPageState(title: shown, url: url == "about:blank" ? self.parent.page.url : url, canGoBack: view.canGoBack, view: view)
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onFailure() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onFailure() }
        }
    }
}
