import SwiftUI
import RoamttyDesktopCore
import UIKit
import PhotosUI
import RoamttyCore
import RoamttyTransport

/// Android `TerminalPane`: the terminal fills the page with no bars. Controls live in the toolbox ghost, its
/// shortcut ring and the dock it opens; notices float on the upper golden section over the preserved grid.
struct TerminalScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.colorScheme) private var scheme
    @StateObject private var draft = DraftController()
    @State private var toolbox = TerminalToolboxState()
    @State private var keyboardVisible = false
    @State private var commandSheet = false
    @State private var fileAction: TerminalFileAction?
    /// A file a tapped path names, shown in the preview at its line.
    @State private var tappedFile: TappedTerminalFile?
    /// A page on the server's loopback that a tapped link names.
    @State private var portPreview: PortPreviewRequest?
    @State private var launchAfterFiles: AppSheet?
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    /// Photos inserting into this terminal; their dialog follows them until each one has an outcome.
    @State private var imageJobs: [UUID] = []
    @State private var restartConfirm = false
    @State private var reverifySheet = false
    @State private var editor = false
    /// Until when a double tap's Up/Down/Left keys stay around the pet; each press restarts it.
    @State private var petArrowsUntil: TimeInterval = 0
    private var connected: Bool { runtime.phase == .connected }
    private var dockAvailable: Bool { connected && !editor && !commandSheet }
    /// A double tap or a line starting with `/` brings arrow keys around the pet, while its ring is closed.
    private var petArrowsShown: Bool { dockAvailable && !toolbox.dockVisible && !toolbox.ringOpen && (petArrowsUntil > now || runtime.slashCommandLine) }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// The terminal view sits inside these insets of its viewport, as on Android (10 / 6 / 6 dp).
    private static let inset = EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 6)

    var body: some View {
        GeometryReader { page in
            // Keyboard avoidance shrinks page height on portrait iPads. Keep the
            // editor's layout stable so its UITextView retains keyboard focus.
            let windowSize = runtime.terminalView.window?.bounds.size ?? page.size
            let landscape = windowSize.width > windowSize.height
            let twoColumns = TerminalDockGeometry.twoColumns(landscape: landscape, keyboardVisible: keyboardVisible, height: page.size.height)
            let reserved = dockAvailable && toolbox.pinned
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            NativeTerminal(runtime: runtime, settings: model.settings).clipped()
                                .overlay {
                                    CursorRowReader(cursor: runtime.cursorRow) {
                                        if connected && !editor {
                                            CursorRowButtons(runtime: runtime, trailingInset: Self.inset.trailing,
                                                bottomInset: keyboardVisible ? 0 : (runtime.terminalView.window?.safeAreaInsets.bottom ?? page.safeAreaInsets.bottom),
                                                avoid: petArrowsShown ? petArrowBounds(in: page.size).offsetBy(dx: -Self.inset.leading, dy: -Self.inset.top) : nil,
                                                keyboardVisible: keyboardVisible)
                                        }
                                    }
                                }
                                .padding(Self.inset)
                            notice.padding(.top, page.safeAreaInsets.top)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The bar's controls keep clear of the camera housing that the landscape grid runs under.
                        if editor {
                            editorBar(landscape: landscape).padding(.leading, page.safeAreaInsets.leading)
                                .padding(.trailing, page.safeAreaInsets.trailing).padding(.bottom, keyboardVisible ? 0 : page.safeAreaInsets.bottom)
                        }
                    }
                    if reserved {
                        dock(in: CGSize(width: twoColumns ? 96 : 48, height: page.size.height), twoColumns: twoColumns, reserved: true)
                            .frame(width: twoColumns ? 96 : 48, height: page.size.height)
                    }
                }
                // The dock and the pet step aside from the cursor row, so they follow it without the page.
                CursorRowReader(cursor: runtime.cursorRow) {
                    if dockAvailable && !reserved {
                        if toolbox.dockVisible { dock(in: page.size, twoColumns: twoColumns, reserved: false) } else if toolbox.ghostVisible || petArrowsShown {
                            let center = petCenter(in: page.size)
                            ZStack(alignment: .topLeading) {
                                GhostShortcuts(runtime: runtime, toolbox: $toolbox, center: center, viewport: page.size) {
                                    withAnimation(.easeOut(duration: 0.18)) { toolbox.openDock(at: now) }
                                }
                                if petArrowsShown { petArrows(center: center).transition(.opacity) }
                            }.transition(.opacity.combined(with: .offset(x: 24)))
                        }
                    }
                }
                ImageInsertStatus(transfers: model.files, jobs: $imageJobs, topInset: page.safeAreaInsets.top).frame(width: page.size.width, height: page.size.height)
            }
        }
        // As on Android, the terminal draws under the transparent status bar, down to the bottom edge and, in
        // landscape, out to both sides instead of leaving the notch bands empty; only the keyboard still pushes it up.
        .ignoresSafeArea(.container)
        .persistentSystemOverlays(.hidden)
        // No visible status bar: expose the phase for VoiceOver and UI tests.
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityIdentifier("terminal-phase")
                .accessibilityLabel(model.phaseText(runtime.phase))
                .accessibilityValue((runtime.record.mode == .tmux ? "tmux" : "SSH") + " " + runtime.transportName)
        }
        // The terminal colour runs under the status bar and home indicator, like Android's edge-to-edge pane.
        .background(Color(uiColor: SessionRuntime.background(scheme)).ignoresSafeArea())
        .foregroundStyle(Palette.foreground)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            toolbox.setPinned(model.settings.toolboxPinned, at: now)
            runtime.onFontScaled = { size in model.settings.fontSize = size; model.saveSettings() }
            runtime.onOpenLoopback = { [weak runtime] url in
                guard let runtime else { return }
                _ = runtime.terminalView.resignFirstResponder()
                portPreview = PortPreviewRequest(url: url, hostName: runtime.host.name) { [weak runtime] in
                    guard let ssh = await runtime?.sideConnection() else { throw PortTunnelError.unavailable }
                    return ssh
                }
            }
            runtime.onOpenPath = { [weak runtime] path, line in
                _ = runtime?.terminalView.resignFirstResponder(); tappedFile = TappedTerminalFile(path: path, line: line)
            }
        }
        .onDisappear { toolbox.closeRing(); runtime.pendingPaste = nil; _ = runtime.terminalView.resignFirstResponder() }
        .onChange(of: runtime.workspaceTouches) { _ in if dockAvailable { toolbox.workspaceTouch(at: now) } }
        .onChange(of: runtime.phase) { phase in
            if phase == .connected { toolbox.wake(at: now) } else { toolbox.closeRing(); runtime.pendingPaste = nil }
        }
        .onChange(of: model.settings.toolboxPinned) { pinned in if pinned != toolbox.pinned { toolbox.setPinned(pinned, at: now) } }
        .onChange(of: commandSheet) { _ in toolbox.closeRing() }
        .onChange(of: runtime.petArrowTouches) { _ in withAnimation(.easeOut(duration: 0.12)) { petArrowsUntil = now + 4 }; toolbox.wake(at: now) }
        .task(id: petArrowsUntil) {
            let wait = petArrowsUntil - now
            guard wait > 0 else { return }
            do { try await Task.sleep(for: .seconds(wait)); withAnimation(.easeOut(duration: 0.2)) { petArrowsUntil = 0 } } catch { }
        }
        // A terminal whose connection dropped, or that came back from the journal, reconnects as soon as it is shown.
        .task(id: runtime.end) { await model.reconnectOnOpen(runtime.record) }
        .onChange(of: editor) { _ in toolbox.closeRing() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardVisible = frame.height > 0 && frame.minY < UIScreen.main.bounds.maxY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .task(id: toolbox.deadline) {
            guard let deadline = toolbox.deadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - now))); withAnimation(.easeOut(duration: 0.4)) { toolbox.expire(at: now) } } catch { }
        }
        .alert(model.text("重启当前会话？", "Restart this session?"), isPresented: $restartConfirm) {
            Button(model.text("取消", "Cancel"), role: .cancel) { }
            Button(model.text("重启", "Restart")) { model.restartSession(runtime.record) }.accessibilityIdentifier("restart-session-confirm")
        } message: {
            Text(runtime.record.mode == .tmux ? model.text("正在运行的程序会被结束，然后在同一目录重新启动。", "The running program is ended, then started again in the same folder.")
                 : model.text("当前 shell 会结束并重新连接。", "The current shell ends and reconnects."))
        }
        .modifier(TerminalPasteConfirmation(runtime: runtime, enabled: !commandSheet))
        .sheet(isPresented: $commandSheet) { CommandSheet(runtime: runtime).environmentObject(model) }
        .sheet(item: $fileAction, onDismiss: {
            // The root launch sheet must wait until its child picker has gone.
            if let launchAfterFiles { self.launchAfterFiles = nil; model.sheet = launchAfterFiles }
        }) { action in
            TerminalFileActions(runtime: runtime, action: action) { agent, directory in
                launchAfterFiles = .launch(runtime.host, agent, directory: directory)
                fileAction = nil
            }.environmentObject(model)
        }
        // Insert image opens the system picker straight from the dock; the photos upload in the background.
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 9, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoPicker) { presented in model.childModalCount = max(0, model.childModalCount + (presented ? 1 : -1)) }
        .onChange(of: photos) { selected in
            guard !selected.isEmpty else { return }
            imageJobs += model.files.uploadImages(selected, runtime: runtime, model: model); photos = []
        }
        .sheet(item: $tappedFile) { file in
            FilePreviewScreen(host: runtime.host, entry: RemoteEntry(name: file.path.split(separator: "/").last.map(String.init) ?? file.path, path: file.path, isDirectory: false),
                              connectionTarget: .session(runtime), line: file.line).environmentObject(model)
        }
        .fullScreenCover(item: $portPreview) { PortPreviewScreen(request: $0).environmentObject(model) }
        .sheet(isPresented: $reverifySheet) { FingerprintReview(host: runtime.host) { model.reconnect(runtime.record) }.environmentObject(model) }
    }

    @ViewBuilder private var notice: some View {
        if runtime.phase != .connected {
            GoldenSectionLayout {
                // A dropped terminal reconnects by itself, so it shows that instead of the failure.
                if runtime.phase.active || SessionReconnect.onOpen(runtime.end) {
                    TerminalConnectionProgress(phase: runtime.phase, reconnecting: !runtime.phase.active) { runtime.close() }
                } else {
                    TerminalConnectionNotice(phase: runtime.phase, message: runtime.message,
                                             onReconnect: { model.reconnect(runtime.record) },
                                             onShell: { model.reconnect(runtime.record, shell: true) },
                                             onReverify: { reverifySheet = true },
                                             onLeave: { if !model.path.isEmpty { model.path.removeLast() } })
                }
            }
        } else if let message = runtime.message {
            GoldenSectionLayout { TerminalInputNotice(message: message) { runtime.message = nil } }
        }
    }

    // MARK: Editor

    @ViewBuilder private func editorBar(landscape: Bool) -> some View {
        let field = DraftEditor(controller: draft, placeholder: model.text("输入文本后，在这里确认", "Type text, then confirm here"), maxLines: keyboardVisible ? 2 : (landscape ? 3 : 4))
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.secondary.opacity(0.7), lineWidth: 1))
        let collapse = Button(model.text("收起", "Hide")) { editor = false; _ = runtime.terminalView.resignFirstResponder(); hideKeyboard() }.buttonStyle(TextActionStyle())
        let enter = Button { _ = runtime.send("\r") } label: { Text(landscape ? model.text("回车 ↵", "Enter ↵") : "↵").font(landscape ? .subheadline.weight(.medium) : .system(size: 22)) }
            .buttonStyle(TextActionStyle()).disabled(!connected).accessibilityLabel(model.text("回车", "Enter")).accessibilityIdentifier("prompt-enter")
        let send = Button(model.text("发送文本", "Send text")) { _ = runtime.pasteText(draft.text) }
            .buttonStyle(FilledButtonStyle()).disabled(draft.text.isEmpty || !connected).accessibilityIdentifier("prompt-send")
        if landscape {
            HStack(spacing: 4) { field; DraftInputControls(controller: draft); collapse; enter; send }.padding(.horizontal, 4).padding(.vertical, 2)
        } else {
            VStack(spacing: 0) {
                field
                HStack(spacing: 0) { DraftInputControls(controller: draft); Spacer(); collapse.frame(minWidth: 48); enter.frame(minWidth: 48); send.frame(minWidth: 88) }
            }.padding(4)
        }
    }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    /// Android stages clipboard text in the editor instead of typing it straight into the program.
    private func pasteIntoEditor() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        draft.insert(text); editor = true; _ = runtime.terminalView.resignFirstResponder()
    }

    // MARK: Dock

    private func cursorFrame() -> CGRect? {
        guard let row = runtime.cursorRowBounds else { return nil }
        let height: CGFloat = 32, width: CGFloat = keyboardVisible ? 80 : 40
        let y = Self.inset.top + row.midY
        return CGRect(x: runtime.terminalView.bounds.width + Self.inset.leading + Self.inset.trailing - width, y: y - height / 2, width: width, height: height)
    }
    private func petCenter(in viewport: CGSize) -> CGPoint {
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: 48, height: 48), avoiding: cursorFrame())
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    /// Up above the pet, Down below it and Left to its left; the pet stays put between them.
    private func petArrowBounds(in viewport: CGSize) -> CGRect {
        let center = petCenter(in: viewport)
        return CGRect(x: center.x - 64, y: center.y - 56, width: 88, height: 112)
    }
    private func petArrows(center: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            CursorKeyButton(icon: "ic_expand_up", label: model.text("发送上方向键", "Send Up arrow"), id: "pet-arrow-up") { runtime.sendPetArrow("A") }
                .position(x: center.x, y: center.y - 40)
            CursorKeyButton(icon: "ic_expand_down", label: model.text("发送下方向键", "Send Down arrow"), id: "pet-arrow-down") { runtime.sendPetArrow("B") }
                .position(x: center.x, y: center.y + 40)
            CursorKeyButton(icon: "ic_expand_left", label: model.text("发送左方向键", "Send Left arrow"), id: "pet-arrow-left") { runtime.sendPetArrow("D") }
                .position(x: center.x - 44, y: center.y)
        }
    }
    private func collapseIfFloating() { if !toolbox.pinned { toolbox.collapseDock(at: now) } }
    private func dock(in viewport: CGSize, twoColumns: Bool, reserved: Bool) -> some View {
        let rows = twoColumns ? 1 + (dockControlCount + 1) / 2 : 2 + dockControlCount
        let width: CGFloat = twoColumns ? 96 : 48, height = CGFloat(rows) * 48
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: width, height: height + 12), endInset: reserved ? 0 : 8, avoiding: reserved ? nil : cursorFrame())
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if twoColumns {
                    HStack(spacing: 0) { collapseButton; sessionMenu }
                    LazyVGrid(columns: [GridItem(.fixed(48), spacing: 0), GridItem(.fixed(48), spacing: 0)], spacing: 0) { dockControls }
                } else {
                    collapseButton; sessionMenu
                    dockControls
                }
            }.padding(.vertical, 6)
        }.frame(width: frame.width, height: frame.height)
            .background(reserved ? Color.clear : Palette.surfaceVariant.opacity(0.78), in: RoundedRectangle(cornerRadius: twoColumns ? 24 : 24))
            .shadow(color: .black.opacity(reserved ? 0 : 0.25), radius: reserved ? 0 : 4, y: 2)
            .position(x: frame.midX, y: frame.midY).accessibilityIdentifier("terminal-dock")
    }
    /// The keys below the dock's collapse and session keys; `dockControlCount` sizes the dock for them.
    /// Android `TerminalPane` primaryControls: desktop (when probe YES) before files, then commands and settings.
    @ViewBuilder private var dockControls: some View {
        if showDesktopDock {
            dockButton("ic_desktop", model.text("打开桌面", "Open desktop"), id: "terminal-desktop") {
                // Android: sticky.clear(); hideKeyboard(); onDesktop()
                runtime.controlArmed = false
                runtime.shiftArmed = false
                hideKeyboard()
                _ = runtime.terminalView.resignFirstResponder()
                if let host = model.host(runtime.record.hostID) { model.openDesktop(host) }
            }
        }
        dockButton("ic_cloud_upload", model.text("上传文件", "Upload files"), id: "upload-file", enabled: connected) { fileAction = .upload }
        dockButton("ic_cloud_download", model.text("下载文件", "Download files"), id: "download-file", enabled: connected) { fileAction = .download }
        dockButton("ic_image", model.text("插入图片", "Insert image"), id: "select-image", enabled: connected) { photoPicker = true }
        dockButton("ic_commands", model.text("常用命令", "Common commands"), id: "common-commands", enabled: connected) { _ = runtime.terminalView.resignFirstResponder(); commandSheet = true }
        settingsMenu
    }
    private var dockControlCount: Int { 5 + (showDesktopDock ? 1 : 0) }
    /// Android: only when desktopSupported && probe == YES.
    private var showDesktopDock: Bool {
        guard let host = model.host(runtime.record.hostID), model.desktopSupported(host) else { return false }
        return DesktopProbe.decode(host.desktop) == .yes
    }
    private var collapseButton: some View {
        Button {
            runtime.controlArmed = false; runtime.shiftArmed = false
            toolbox.collapseDock(at: now); model.settings.toolboxPinned = false; model.saveSettings()
        } label: {
            // Android: countdown ring on ✕ while a floating dock's quiet spell runs.
            ZStack {
                if toolbox.floatingDock, TerminalToolboxState.dockHideSeconds > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
                        let p = toolbox.dockHideProgress(at: ProcessInfo.processInfo.systemUptime)
                        ZStack {
                            Circle().stroke(Palette.foreground.opacity(0.12), lineWidth: 2)
                            Circle().trim(from: 0, to: p)
                                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }.frame(width: 32, height: 32)
                    }
                }
                AppIcon("ic_close", size: 20)
            }.frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(model.text("收起操作栏", "Hide toolbar")).accessibilityIdentifier("collapse-dock")
    }
    private func dockButton(_ icon: String, _ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button { toolbox.touchDock(at: now); action(); collapseIfFloating() } label: { AppIcon(icon).frame(width: 48, height: 48).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Palette.foreground.opacity(enabled ? 1 : 0.38)).disabled(!enabled)
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private var openSessions: [SessionRecord] { model.records.filter { model.runtimes[$0.id] != nil } }
    private var sessionMenu: some View {
        Menu {
            Button(model.text("返回主机详情", "Back to host details")) { afterMenuSelection { model.path = model.host(runtime.host.id) == nil ? [] : [.host(runtime.host.id)] } }
            // Closing ends the session on the server, without asking, and returns to the session list.
            Button(runtime.record.external ? model.text("断开当前会话", "Detach session") : model.text("关闭当前会话", "Close session")) {
                afterMenuSelection { model.closeSession(runtime.record) }
            }.accessibilityIdentifier("close-session")
            // A tmux pane restarts over the live connection; a plain shell restarts by reconnecting.
            Button(model.text("重启当前会话", "Restart session")) { restartConfirm = true }
                .disabled(runtime.record.mode == .tmux && !connected).accessibilityIdentifier("restart-session")
            Divider()
            ForEach(openSessions) { other in
                let phase = model.runtimes[other.id]?.phase ?? .disconnected
                Button((other.id == runtime.record.id ? "✓ " : "") + model.sessionTitle(other) + " · " + model.phaseText(phase)) {
                    if other.id != runtime.record.id { afterMenuSelection { model.openSession(other) } }
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon("ic_sessions")
                Circle().fill(connected ? Palette.accent : Palette.danger).frame(width: 8, height: 8).offset(x: 3, y: -3)
            }.foregroundStyle(Palette.accent).frame(width: 48, height: 48).contentShape(Rectangle())
        }.onTapGesture { _ = runtime.terminalView.resignFirstResponder(); toolbox.touchDock(at: now) }
            .accessibilityLabel(model.text("切换会话：", "Switch session: ") + model.sessionTitle(runtime.record)).accessibilityIdentifier("session-switcher")
    }
    /// For a menu item that can take the dock off the screen. UIKit asks the menu's button for its dismissal preview
    /// as soon as the item's action returns, and aborts if the button has left the window. SwiftUI normally removes it
    /// later, but putting the keyboard away lays the page out on the spot, so such work waits for the next turn.
    private func afterMenuSelection(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) }
    private var settingsMenu: some View {
        let size = Int(model.settings.fontSize.rounded())
        return Menu {
            Button(model.text("编辑文本", "Edit text")) { afterMenuSelection { editor = true; _ = runtime.terminalView.resignFirstResponder() } }.accessibilityIdentifier("menu-edit-text")
            Button(toolbox.pinned ? model.text("取消固定操作栏", "Unpin toolbar") : model.text("固定操作栏", "Pin toolbar")) {
                let pinned = !toolbox.pinned; toolbox.setPinned(pinned, at: now); if !pinned { toolbox.openDock(at: now) }
                model.settings.toolboxPinned = pinned; model.saveSettings()
            }.accessibilityIdentifier("terminal-pin-tools")
            Button(model.text("隐藏操作栏", "Hide toolbar")) {
                afterMenuSelection {
                    toolbox.collapseDock(at: now); editor = false; _ = runtime.terminalView.resignFirstResponder()
                    model.settings.toolboxPinned = false; model.saveSettings()
                }
            }
            Button(model.text("粘贴", "Paste")) { afterMenuSelection { pasteIntoEditor(); collapseIfFloating() } }.accessibilityIdentifier("menu-paste")
            Divider()
            Button(model.text("增大字号 · \(size) pt", "Larger text · \(size) pt")) { setFontSize(model.settings.fontSize + 1) }
            Button(model.text("减小字号 · \(size) pt", "Smaller text · \(size) pt")) { setFontSize(model.settings.fontSize - 1) }
        } label: { AppIcon("ic_settings").frame(width: 48, height: 48).contentShape(Rectangle()) }
            .onTapGesture { toolbox.touchDock(at: now) }
            .accessibilityLabel(model.text("终端设置", "Terminal settings")).accessibilityIdentifier("terminal-menu")
    }
    private func setFontSize(_ size: Double) {
        model.settings.fontSize = min(28, max(8, size.rounded())); model.saveSettings(); collapseIfFloating()
    }
}

private struct TerminalPasteConfirmation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    var enabled = true
    var onSent: () -> Void = { }
    func body(content: Content) -> some View {
        content.alert(model.text("发送多行文本？", "Send multiple lines?"),
            isPresented: Binding(get: { enabled && runtime.pendingPaste != nil }, set: { if !$0 { runtime.pendingPaste = nil } }),
            presenting: runtime.pendingPaste) { text in
            Button(model.text("发送", "Send")) {
                runtime.pendingPaste = nil
                if runtime.pasteText(text, confirmed: true) { onSent() }
            }.disabled(runtime.phase != .connected).accessibilityIdentifier("terminal-paste-send")
            Button(model.text("取消", "Cancel"), role: .cancel) { runtime.pendingPaste = nil }.accessibilityIdentifier("terminal-paste-cancel")
        } message: { _ in
            Text(model.text("远端尚未启用 bracketed paste。文本中的换行可能立即执行命令，请确认当前程序能安全接收多行输入。",
                "The remote program has not enabled bracketed paste. Newlines may run commands immediately. Confirm that it can safely receive multiple lines."))
        }
    }
}

/// A file a path tapped in the terminal names, and the line it points at (0 for none).
struct TappedTerminalFile: Identifiable {
    let path: String
    let line: Int
    var id: String { "\(path):\(line)" }
}
