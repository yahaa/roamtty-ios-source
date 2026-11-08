import SwiftUI
import RoamttyCore
import RoamttyTransport

struct LaunchScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let host: Host
    let forAgent: Bool
    var initialDirectory = "~"
    /// The agent already picked (the new-session sheet asks for it first); otherwise the last one used.
    var initialAgent: CodingAgent?
    /// Replaces the heading when the sheet is a step of a longer flow.
    var title: String?
    @State private var agent = CodingAgent.codex
    @State private var agentMode = AgentMode.yolo
    @State private var sessionMode = SessionMode.tmux
    @State private var sessionModeExplicit = false
    @State private var directory = "~"
    @State private var pathDraft = "~"
    @State private var entries: [RemoteEntry] = []
    @State private var busy = false
    @State private var error: String?
    @State private var filter = ""
    @State private var mosh = false
    @State private var moshExplicit = false
    @State private var recent: [String] = []
    @State private var homeDirectory: String?
    @State private var loadRevision = 0
    @State private var loadTask: Task<Void, Never>?
    @State private var loadCancellation: TransferCancellation?
    private var launchReady: Bool { !busy && error == nil && StartDirectory.isSupported(pathDraft) && StartDirectory.normalize(pathDraft) == directory }
    private var segments: [(name: String, path: String)] { StartDirectory.segments(directory) }
    private var parent: String? {
        if segments.count >= 2 { return segments[segments.count - 2].path }
        if directory == "~", let homeDirectory, homeDirectory != "/" { return parentRemotePath(homeDirectory) }
        return nil
    }
    private var folders: [RemoteEntry] { entries.filter { $0.isDirectory && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter.trimmingCharacters(in: .whitespaces))) } }
    private var folderName: String { StartDirectory.isHome(directory) ? model.text("主目录", "home") : (directory.split(separator: "/").last.map(String.init) ?? "/") }
    private var launchTitle: String {
        let home = StartDirectory.isHome(directory)
        if forAgent {
            return home ? model.text("在主目录启动 \(agent.shortLabel)",
                "Start \(agent.shortLabel) in home") : model.text("在 \(folderName) 启动 \(agent.shortLabel)",
                "Start \(agent.shortLabel) in \(folderName)")
        }
        return home ? model.text("在主目录打开终端", "Open terminal in home") : model.text("在 \(folderName) 打开终端", "Open terminal in \(folderName)")
    }
    private var heading: String { title ?? (forAgent ? model.text("用 Agent 打开", "Open with Agent") : model.text("打开终端", "Open terminal")) }
    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass == .compact { landscape } else {
                HStack {
                    Text(heading).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("launch-cancel")
                }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 12)
                folderPanel
            }
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
        .task {
            let currentHost = model.host(host.id) ?? host
            sessionMode = currentHost.newSessionMode; mosh = currentHost.plugins?.contains("mosh") == true
            recent = LaunchPreferences.recentFolders(host.id)
            agent = initialAgent ?? LaunchPreferences.agent
            agentMode = LaunchPreferences.agentMode
            navigate(initialDirectory)
        }.onChange(of: model.host(host.id)?.plugins) { plugins in
            if !moshExplicit { mosh = plugins?.contains("mosh") == true }
            if !sessionModeExplicit { sessionMode = (model.host(host.id) ?? host).newSessionMode }
        }
        .onDisappear { loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1 }
    }
    @ViewBuilder private var folderPanel: some View {
        if !recent.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(recent, id: \.self) { path in recentChip(path) } }.padding(.horizontal, 16)
            }.padding(.bottom, 8)
        }
        folderBox.padding(.horizontal, 16)
        if forAgent { HStack(spacing: 8) { agentPickers }.padding(.horizontal, 16).padding(.top, 12) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { testControls }
        #endif
        launchButton.padding(.horizontal, 16).padding(.vertical, 12)
    }
    /// The path bar over the folders.
    private var folderBox: some View {
        VStack(spacing: 0) {
            if filtering { filterBar } else { pathBar }
            Divider().overlay(Palette.outline)
            ZStack(alignment: .top) {
                if let error {
                    centerNote(error, id: "launch-error", action: StartDirectory.isHome(directory) ? model.text("重试", "Retry") : model.text("回到主目录", "Back to home")) { navigate("~") }
                } else if entries.isEmpty && busy {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { folderList }
                if busy && !entries.isEmpty { ProgressView().progressViewStyle(.linear).tint(Palette.accent) }
            }.frame(maxHeight: .infinity)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private var launchButton: some View {
        Button {
            guard launchReady else { return }
            let normalized = StartDirectory.normalize(directory)
            recent = StartDirectory.remember(recent: recent, directory: normalized); persistRecent()
            if forAgent { LaunchPreferences.rememberAgent(agent, mode: agentMode) }
            let launch = forAgent ? AgentLaunch(agent: agent, directory: normalized, mode: agentMode) : nil
            model.launch(host, mode: sessionMode, directory: normalized, agent: launch, mosh: moshExplicit ? mosh : nil)
        } label: {
            HStack(spacing: 8) {
                if forAgent { AppIcon(agent.iconName, size: 18) }
                Text(launchTitle).lineLimit(1)
            }.font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(launchReady ? (yolo ? Palette.adaptive(0xFFFFFF, 0x5E1C17) : Palette.onAccent) : Palette.foreground.opacity(0.38))
                .background(launchReady ? (yolo ? Palette.danger : Palette.accent) : Palette.foreground.opacity(0.12), in: Capsule())
                .animation(.easeInOut(duration: 0.2), value: yolo)
        }.buttonStyle(.plain).disabled(!launchReady).accessibilityIdentifier("launch-session")
    }
    private var yolo: Bool { forAgent && agentMode == .yolo }
    @State private var filtering = false
    /// Tappable crumbs (`~ › work › app`); the arrow steps up past home, the magnifier filters long lists.
    private var pathBar: some View {
        HStack(spacing: 0) {
            Button { if let parent { navigate(parent) } } label: { AppIcon("ic_arrow_up", size: 20).frame(width: 40, height: 40) }
                .disabled(parent == nil).foregroundStyle(Palette.foreground.opacity(parent == nil ? 0.38 : 1))
                .accessibilityLabel(model.text("上一级", "Up one level")).accessibilityIdentifier("launch-parent")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            let last = index == segments.count - 1
                            if index > 0 { AppIcon("ic_chevron_right", size: 14).foregroundStyle(Palette.adaptive(0x827A70, 0x9A9890)) }
                            Button { if !last { navigate(segment.path) } } label: {
                                Text(segment.name).font(last ? .subheadline.weight(.semibold) : .subheadline).foregroundStyle(last ? Palette.foreground : Palette.accent)
                                    .lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 10)
                            }.buttonStyle(.plain).id(index).accessibilityIdentifier("launch-crumb-\(index)")
                        }
                    }
                }.onChange(of: directory) { _ in withAnimation { proxy.scrollTo(segments.count - 1, anchor: .trailing) } }
            }.accessibilityIdentifier("launch-path")
            if entries.filter(\.isDirectory).count > 8 {
                Button { filtering = true } label: { AppIcon("ic_search", size: 20).foregroundStyle(Palette.secondary).frame(width: 40, height: 40) }
                    .accessibilityLabel(model.text("筛选当前目录", "Filter this folder")).accessibilityIdentifier("launch-filter-toggle")
            }
        }.padding(.horizontal, 4).frame(minHeight: 48)
    }
    @FocusState private var filterFocused: Bool
    private var filterBar: some View {
        HStack(spacing: 0) {
            Button { filtering = false; filter = "" } label: { AppIcon("ic_chevron_left", size: 20).frame(width: 40, height: 40) }
                .accessibilityLabel(model.text("关闭筛选", "Close filter")).accessibilityIdentifier("launch-filter-close")
            TextField(model.text("筛选当前目录", "Filter this folder"), text: $filter).focused($filterFocused).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go).onSubmit { if let first = folders.first { navigate(first.path) } }.padding(.horizontal, 6).accessibilityIdentifier("launch-filter")
            if !filter.isEmpty { Button { filter = "" } label: { AppIcon("ic_clear", size: 18).foregroundStyle(Palette.secondary).frame(width: 40, height: 40) } }
        }.padding(.horizontal, 4).frame(minHeight: 48).onAppear { filterFocused = true }
    }
    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if folders.isEmpty {
                    Text(entries.contains(where: \.isDirectory) ? model.text("没有匹配的文件夹", "No matching folders") : model.text("这里没有子文件夹", "No subfolders here"))
                        .font(.subheadline).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                ForEach(folders) { entry in
                    Button { navigate(entry.path) } label: {
                        HStack(spacing: 12) {
                            RemoteFileIcon(name: entry.name, directory: true, size: 22)
                            Text(entry.name).font(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            AppIcon("ic_chevron_right", size: 18).foregroundStyle(Palette.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 50) }
                        .accessibilityIdentifier("launch-folder-\(entry.name)")
                }
            }.opacity(busy ? 0.5 : 1)
        }.accessibilityIdentifier("launch-folders")
    }
    private func centerNote(_ message: String, id: String = "launch-note", action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).accessibilityIdentifier(id)
            Button(action, action: perform).buttonStyle(TextActionStyle()).accessibilityIdentifier("launch-note-action")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func recentChip(_ path: String) -> some View {
        let selected = StartDirectory.normalize(path) == directory
        let name = StartDirectory.isHome(path) ? model.text("主目录", "home") : (path.split(separator: "/").last.map(String.init) ?? "/")
        return HStack(spacing: 8) {
            AppIcon("ic_history", size: 16)
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Button { recent.removeAll { $0 == path }; persistRecent() } label: { AppIcon("ic_clear", size: 16) }.buttonStyle(.plain)
                .accessibilityLabel(model.text("移除 \(path)", "Remove \(path)"))
        }.padding(.horizontal, 8).frame(height: 32).foregroundStyle(selected ? Palette.adaptive(0x3D332D, 0xECE2D8) : Palette.secondary)
            .background(selected ? Palette.adaptive(0xECE4DB, 0x47413B) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { if !selected { RoundedRectangle(cornerRadius: 8).stroke(Palette.outline, lineWidth: 1) } }
            .contentShape(Rectangle()).onTapGesture { navigate(path) }
    }
    /// Agent and permission as two pickers, side by side in portrait and stacked in landscape; YOLO is red, and its "!"
    /// says what it allows.
    @ViewBuilder private var agentPickers: some View {
            Menu {
                Picker("", selection: $agent) {
                    ForEach(CodingAgent.allCases) { option in Label { Text(option.shortLabel + "  ·  " + option.command) } icon: { Image(option.iconName) }.tag(option) }
                }
            } label: { pickerField { AgentIcon(agent: agent, size: 28); Text(agent.shortLabel).font(.subheadline.weight(.medium)).lineLimit(1) } }
                .accessibilityIdentifier("launch-agent")
            Menu {
                Picker("", selection: $agentMode) {
                    ForEach(AgentMode.allCases) { option in Text(modeLabel(option) + " — " + modeHint(option)).tag(option) }
                }
            } label: {
                pickerField(border: yolo ? Palette.danger : nil) {
                    Text(modeLabel(agentMode)).font(.subheadline.weight(.medium)).foregroundStyle(yolo ? Palette.danger : Palette.foreground).lineLimit(1)
                    if yolo { AppIcon("ic_alert", size: 18).foregroundStyle(Palette.danger).accessibilityLabel(modeHint(.yolo)).accessibilityIdentifier("launch-yolo-warning") }
                }
            }.accessibilityIdentifier("launch-agent-mode")
    }
    private func pickerField<Content: View>(border: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content(); Spacer(minLength: 0); AppIcon("ic_expand_down", size: 18).foregroundStyle(Palette.secondary) }
            .padding(.leading, 12).padding(.trailing, 6).frame(minHeight: 44).foregroundStyle(Palette.foreground)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(border ?? Palette.outline, lineWidth: border == nil ? 0.5 : 1) }
    }

    // MARK: Landscape

    /// Landscape, like the host page there: one flat bar with close and the heading; the folders take the whole height
    /// on the left, and a side column holds the recent folders, the agent pickers and the launch button.
    @ViewBuilder private var landscape: some View {
        LandscapeBar(title: heading) {
            BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "launch-cancel") { dismiss() }
        } trailing: { EmptyView() }
        HStack(alignment: .top, spacing: 10) {
            folderBox
            // The pickers and the button keep their place at the bottom; the recent folders scroll in what is left.
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !recent.isEmpty { sideLabel(model.text("最近", "Recent")); recentList }
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { testControls }
                        #endif
                    }
                }.frame(maxHeight: .infinity)
                if forAgent {
                    sideLabel("Agent")
                    agentPickers
                }
                launchButton
            }.frame(width: 250)
        }.padding(.horizontal, 6).padding(.bottom, 8)
    }
    private func sideLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 4)
    }
    /// The recent folders as a list.
    private var recentList: some View {
        VStack(spacing: 0) {
            ForEach(recent, id: \.self) { path in
                let selected = StartDirectory.normalize(path) == directory
                HStack(spacing: 9) {
                    AppIcon("ic_history", size: 16).foregroundStyle(Palette.secondary)
                    Text(StartDirectory.isHome(path) ? model.text("主目录", "home") : (path.split(separator: "/").last.map(String.init) ?? "/"))
                        .font(.subheadline).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button { recent.removeAll { $0 == path }; persistRecent() } label: { AppIcon("ic_clear", size: 16).foregroundStyle(Palette.secondary).frame(width: 32, height: 38) }
                        .buttonStyle(.plain).accessibilityLabel(model.text("移除 \(path)", "Remove \(path)"))
                }.padding(.leading, 12).padding(.trailing, 4).frame(height: 38)
                    .background(selected ? Palette.foreground.opacity(0.08) : Color.clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5) }
                    .contentShape(Rectangle()).onTapGesture { navigate(path) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("launch-recent-\(path)")
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private func modeLabel(_ mode: AgentMode) -> String {
        switch mode {
        case .readOnly: return agent == .claude ? model.text("计划", "Plan") : model.text("只读", "Read only")
        case .standard: return model.text("普通", "Standard")
        case .yolo: return "YOLO"
        }
    }
    private func modeHint(_ mode: AgentMode) -> String {
        switch mode {
        case .yolo: return model.text("跳过所有确认，直接执行", "Skip all confirmations and execute directly")
        case .standard: return model.text("改文件或运行命令前先问你", "Ask before editing files or running commands")
        case .readOnly:
            switch agent {
            case .claude: return model.text("先分析并制定计划，批准后开始修改", "Analyze and plan first; make changes after approval")
            case .codex: return model.text("以只读沙箱启动，可在 Agent 中调整权限", "Start in a read-only sandbox; permissions can be adjusted in the agent")
            case .grok: return model.text("只读沙箱；状态与临时目录仍可写", "Read-only sandbox; state and temporary directories remain writable")
            }
        }
    }
    #if DEBUG
    /// UI tests only: Android has no per-launch mode, mosh or typed path, but the suite needs them deterministically.
    private var testControls: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { sessionMode }, set: { sessionMode = $0; sessionModeExplicit = true })) {
                Text("tmux").tag(SessionMode.tmux)
                Text("SSH").tag(SessionMode.shell)
            }.pickerStyle(.segmented).accessibilityIdentifier("launch-mode")
            HStack {
                TextField("", text: $pathDraft).font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit {
                    navigate(pathDraft)
                }.accessibilityIdentifier("launch-directory")
                Toggle("mosh", isOn: Binding(get: { mosh }, set: { mosh = $0; moshExplicit = true })).font(.caption).fixedSize().accessibilityIdentifier("launch-mosh")
            }
            if forAgent {
                Text(AgentLaunch(agent: agent, directory: directory, mode: agentMode).agentCommand).font(.caption2.monospaced()).accessibilityIdentifier("launch-command-preview")
                Text(modeHint(agentMode)).font(.caption2).accessibilityIdentifier("launch-permission-hint")
            }
        }.padding(.horizontal, 16).padding(.top, 8).opacity(0.6)
    }
    #endif
    private func navigate(_ path: String) {
        loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1
        let revision = loadRevision, cancellation = TransferCancellation()
        loadCancellation = cancellation
        pathDraft = path; busy = false; error = nil
        guard StartDirectory.isSupported(path) else { error = model.text("文件夹路径含有不支持的控制字符", "The folder path contains unsupported control characters"); return }
        let normalized = StartDirectory.normalize(path)
        directory = normalized; pathDraft = normalized; busy = true
        loadTask = Task { await load(normalized, revision: revision, cancellation: cancellation) }
    }
    private func load(_ path: String, revision: Int, cancellation: TransferCancellation) async {
        defer { if revision == loadRevision { busy = false } }
        do {
            let ssh = try await model.connection(for: host.id)
            try Task.checkCancellation()
            let script = try RemoteFolders.script(path)
            let result = try await ssh.runScript(script, cancellation: cancellation)
            try Task.checkCancellation()
            guard revision == loadRevision else { return }
            guard result.status == 0, let folders = RemoteFolders.parse(result.text) else {
                throw RoamError.invalid(model.text("无法读取文件夹，请检查路径与访问权限", "Cannot read this folder. Check its path and access permissions."))
            }
            homeDirectory = folders.home
            directory = StartDirectory.normalize(folders.display)
            pathDraft = directory; entries = folders.directory.entries; filter = ""
        } catch { if !Task.isCancelled, revision == loadRevision { self.error = error.localizedDescription } }
    }
    private func persistRecent() { recent = LaunchPreferences.setRecentFolders(recent, for: host.id) }
}
