import SwiftUI
import Combine
import Network
import RoamttyCore
import RoamttyTransport

/// The app's state and the actions on it. The features live in extensions:
/// - `AppModel+Hosts`: saved hosts, their credentials and reachability
/// - `AppModel+Sessions`: terminal sessions, from launch to close, and their reconnects
/// - `AppModel+Connections`: logins, prompts and the host connections that tools share
/// - `AppModel+Monitor`: the host page's live metrics
/// - `AppModel+Desktop`: remote desktops, one `DesktopController` per host
/// - `AppModel+Notifications`: the agent notifications
/// Debug builds add the launch fixtures of the UI tests in `AppModel+Fixtures`.
@MainActor final class AppModel: ObservableObject {
    // MARK: State the screens show

    @Published var hosts: [Host] = []
    @Published var settings = AppSettings()
    @Published var records: [SessionRecord] = []
    @Published var path: [AppRoute] = [] {
        didSet {
            if let route = path.last, route != oldValue.last { recordHostUse(for: route) }
        }
    }
    @Published var homeTab: HomeTab = .sessions
    /// The session group the home list shows alone, nil for all of them.
    @Published var sessionFilter: SessionGroup?
    @Published var sheet: AppSheet?
    @Published var drawer = false
    @Published var error: String?
    @Published var notice: String?
    @Published var metrics: [String: HostMetrics] = [:]
    @Published var metricSeries: [String: HostMetricSeries] = [:]
    @Published var monitorStates: [String: HostMonitorState] = [:]
    @Published var reachability: [String: HostReachability] = [:]
    @Published var incomingFiles: [URL] = []
    @Published var childModalCount = 0
    /// Login questions waiting for the user; `authentication` is the one on screen.
    @Published var prompts = PromptQueue()
    var authentication: AuthenticationRequest? { prompts.active }
    let files = FileTransferModel()
    var runtimes: [String: SessionRuntime] = [:]

    // MARK: Bookkeeping shared by the feature extensions

    var store: AppStore?
    // Read by the model only, so not published: a change redraws nothing.
    /// When each host's shown reachability was measured.
    var reachabilityCheckedAt: [String: Date] = [:]
    /// Where each host's shared connection (files, plugins, metrics) stands.
    var hostPhases: [String: ConnectionPhase] = [:]
    let vault = SecretVault()
    var journal = SessionJournal()
    var foreground = true
    var generations = ConnectionGenerations()
    var credentialCache = CredentialCache()
    /// Host tools' shared connections, the attempts under way and the token of each host's latest attempt.
    var connections: [String: SSHConnection] = [:]
    var connectionTasks: [String: Task<SSHConnection, Error>] = [:]
    var connectionTokens: [String: UUID] = [:]
    var connectingSSH: [String: SSHConnection] = [:]
    var metadataJobs: [String: TrackedTask] = [:]
    var monitorJobs: [String: TrackedTask] = [:]
    var sessionLaunches: [String: TrackedTask] = [:]
    var sessionSubscriptions: [String: AnyCancellable] = [:]
    /// Session id → when it last reconnected by itself; see `SessionReconnect.interval`.
    var autoReconnectedAt: [String: Date] = [:]
    /// Sessions that already retried an unreachable host during this look at the session list.
    var retriedThisVisit = Set<String>()
    /// Session id → when the list began waiting for its host to answer again.
    var waitingForHostSince: [String: Date] = [:]
    /// Remote desktops' thumbnails, and their controllers once the first desktop opens.
    let desktopThumbnails = DesktopThumbnails()
    var desktopStore: DesktopStore?
    var desktopPathMonitor: NWPathMonitor?

    init() {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let name = ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] ?? "Roamtty"
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try AppStore(url: folder.appendingPathComponent("roamtty.sqlite"))
            self.store = store
            hosts = try store.hosts(); journal = try store.loadJournal(); settings = try store.loadSettings(); records = journal.records
            let restoredFont = FontCatalog.shared.restore(selection: settings.font)
            if settings.font != restoredFont { settings.font = restoredFont; try store.saveSettings(settings) }
            #if DEBUG
            try installUITestFixture(store)
            try installDesktopControlsFixture()
            try installDesktopGestureFixture()
            #endif
        } catch { self.error = error.localizedDescription }
        installAgentNotifications()
    }

    // MARK: Language and appearance

    var english: Bool { settings.language.hasPrefix("en") }
    func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
    var colorScheme: ColorScheme? { settings.theme == .system ? nil : settings.theme == .dark ? .dark : .light }
    func phaseText(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .connecting: return text("连接中", "Connecting")
        case .verifying: return text("验证指纹", "Verifying host")
        case .authenticating: return text("认证中", "Authenticating")
        case .connected: return text("已连接", "Connected")
        case .disconnected: return text("已断开", "Disconnected")
        case .authFailed: return text("认证失败", "Authentication failed")
        case .hostKeyChanged: return text("指纹已变化", "Host key changed")
        case .failed: return text("连接失败", "Connection failed")
        case .tmuxMissing: return text("未安装 tmux", "tmux missing")
        }
    }
    func saveSettings() {
        AgentNotifier.shared.apply(settings.agentNotifications)
        do { try store?.saveSettings(settings) } catch { self.error = error.localizedDescription }
    }

    /// Remote desktops for every host; created on first use.
    var desktops: DesktopStore {
        if let desktopStore { return desktopStore }
        let store = DesktopStore(); desktopStore = store; return store
    }

    // MARK: Presentation

    /// Presents `next` once the sheet on screen has gone.
    func replaceSheet(with next: AppSheet) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.sheet = next }
    }

    // MARK: App lifecycle

    func resume() {
        foreground = true
        AgentNotifier.shared.keepWatching(false)
        Diagnostics.shared.log("foreground", "sessions=\(runtimes.count) terminals=\(TerminalCensus.live)")
        for runtime in runtimes.values { runtime.probe() }
        // A terminal on screen that dropped while the app was away found the app in the background and did not
        // reconnect then; it does now.
        if case .terminal(let id)? = path.last, let record = records.first(where: { $0.id == id }) { Task { await reconnectOnOpen(record) } }
        restartVisibleMonitor()
        // Cold launch never creates the store or NWPathMonitor: both wait for the first desktop opened.
        if desktopStore != nil {
            desktopStore?.live.forEach { $0.resume() }
            startDesktopPathMonitor()
        }
        #if DEBUG
        // Fixture diagnostics use separate stores and must not consume the user's shared inbox.
        let diagnostics = ["--device-validation", "--memory-validation", "--desktop-memory-validation"]
        if ProcessInfo.processInfo.arguments.contains(where: { diagnostics.contains($0) }) { return }
        #endif
        SharedInbox.consume { [weak self] result in
            guard let self else { return }
            // Use current presentation/upload state, not the state at the foreground request.
            self.appendIncoming(result.urls)
            if let error = result.errors.first { self.error = error.localizedDescription }
        }
    }
    func importIncoming(_ url: URL) {
        SharedInbox.copyIncoming(url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let imported): self.appendIncoming([imported])
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    private func appendIncoming(_ urls: [URL]) {
        var existing = Set(incomingFiles + files.pendingUploadURLs).union(files.activeUploadURLs)
        incomingFiles.append(contentsOf: urls.filter { existing.insert($0).inserted })
    }
    /// In the background no login stays in memory and nothing waits for the user.
    func suspend() {
        foreground = false
        Diagnostics.shared.log("background", "sessions=\(runtimes.count) terminals=\(TerminalCensus.live)")
        for id in Array(monitorJobs.keys) { stopMonitor(id) }
        credentialCache.forgetAll()
        for runtime in runtimes.values { runtime.clearLoginCredentials() }
        desktopStore?.live.forEach { $0.pause() }
        prompts.removeAll().forEach { $0.answer(nil) }
        // An agent at work may still need the user or finish before iOS suspends the app.
        AgentNotifier.shared.keepWatching(runtimes.values.contains { $0.phase == .connected && ($0.agentStatus.map { $0.state != .idle } ?? false) })
    }
}
