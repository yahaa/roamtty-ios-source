import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The remote desktop page (Android `DesktopPage`, design D1–D11): picture, rail / tab bar, 操作 / 键盘
/// panels, stats, status card. State lives in `DesktopController` / `DesktopPageModel`.
struct DesktopPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    @State private var showDisconnect = false
    @State private var keyboardOverlap: CGFloat = 0
    @State private var composingText = ""
    @State private var shortcutBar = false
    @State private var latchRevision = 0
    @State private var panel: DesktopPanel = .none
    @State private var keyboardPage: DesktopKeyboardPage = .ime
    @State private var virtualMouse = false
    @State private var showStats = false
    /// Closing the figures with their ✕ says once where to bring them back.
    @State private var statsHint = false
    @ObservedObject private var statsBox: DesktopStatsBox
    @State private var pointerMode: PointerMode = .touch
    @State private var imeFocused = false
    /// Landscape: the Dynamic Island (or notch) is on the leading edge, beside the picture.
    @State private var islandLeading = true
    @State private var railWidth: CGFloat = 0
    /// Portrait: how tall the bottom rail stands, from the screen's bottom edge.
    @State private var railHeight: CGFloat = 0
    /// How deep a rail button is across the rail, the same standing up or lying down.
    private let railDepth: CGFloat = 54

    private let panelColor = Color(red: 28/255, green: 28/255, blue: 30/255)
    private let railColor = Color(red: 20/255, green: 20/255, blue: 22/255)
    private let ink = Color(red: 242/255, green: 242/255, blue: 247/255)
    private let inkDim = Color(red: 154/255, green: 154/255, blue: 161/255)
    private let accent = Color(red: 1, green: 159/255, blue: 10/255)

    init(controller: DesktopController) {
        self.controller = controller
        _statsBox = ObservedObject(wrappedValue: controller.statsBox)
    }

    private var english: Bool { model.english }
    private var page: DesktopPageModel { controller.page }

    var body: some View {
        GeometryReader { geo in
            // Keyboard avoidance changes the proposed height, not the window's orientation.
            let windowSize = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }?.bounds.size ?? geo.size
            let landscape = windowSize.width > windowSize.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    // Only the island's side keeps its safe inset: the picture and the rail use the other.
                    let insets = geo.safeAreaInsets
                    HStack(spacing: 0) {
                        // The picture always runs to the bottom edge, so the keyboard is measured from there.
                        desktopWorkspace(landscape: true, bottomInset: keyboardPage == .ime ? keyboardOverlap : insets.bottom,
                                         bleed: islandLeading ? 0 : insets.leading)
                            .padding(.leading, islandLeading ? insets.leading : 0)
                        controlRail(landscape: true, edgeInset: insets.trailing, edgeClearance: islandLeading ? 0 : min(insets.trailing, 50))
                            .background(GeometryReader { rail in Color.clear.preference(key: RailWidthKey.self, value: rail.size.width) })
                    }
                    // The picture runs under the home indicator too; the keyboard panel floats clear of it.
                    // All regions: while the keyboard is up, the home indicator's inset counts as the keyboard's,
                    // and keeping it would shrink the picture. The panel places itself from keyboardOverlap.
                    .ignoresSafeArea(.all, edges: [.horizontal, .bottom])
                } else {
                    VStack(spacing: 0) {
                        desktopWorkspace(landscape: false, bottomInset: max(0, keyboardOverlap - geo.safeAreaInsets.bottom))
                        if panel != .keyboard {
                            controlRail(landscape: false, bottomInset: geo.safeAreaInsets.bottom)
                                .background(GeometryReader { rail in Color.clear.preference(key: RailHeightKey.self, value: rail.size.height) })
                        }
                    }
                    // The rail takes most of the home indicator's inset; the keyboard panel keeps it all.
                    .ignoresSafeArea(.container, edges: panel == .keyboard ? [] : .bottom)
                }
                #if DEBUG
                if !controller.inputProbe.isEmpty {
                    // Test only: what the gestures sent (ROAMTTY_DESKTOP_INPUT_PROBE=1).
                    Text(controller.inputProbe).font(.system(size: 6)).opacity(0.02).allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityIdentifier("desktop-input-probe")
                }
                if !controller.audioProbe.isEmpty {
                    // Test only: a near-invisible line the live UI test reads (ROAMTTY_DESKTOP_AUDIO_PROBE=1).
                    Text(controller.audioProbe).font(.system(size: 6)).opacity(0.02).allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .accessibilityIdentifier("desktop-audio-probe")
                }
                #endif
                if panel == .operations {
                    // The panel opens just beside the rail, which reaches past the safe area.
                    // Portrait: it stands on the bottom rail, which stays visible and live.
                    operationsPanel(size: geo.size, landscape: landscape,
                                    trailing: max(8, railWidth + 8 - geo.safeAreaInsets.trailing),
                                    bottom: landscape ? 0 : max(0, railHeight - geo.safeAreaInsets.bottom))
                        .transition(.move(edge: landscape ? .trailing : .bottom))
                }

            }
            .animation(.easeOut(duration: 0.2), value: panel)
            .onPreferenceChange(RailWidthKey.self) { railWidth = $0 }
            .onPreferenceChange(RailHeightKey.self) { railHeight = $0 }
        }
        // UIKit's hidden IME can include an input-assistant row that SwiftUI's automatic
        // avoidance misses after rotation. Reserve the entire keyboard frame explicitly.
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow }) else { return }
            let localFrame = window.convert(frame, from: nil)
            keyboardOverlap = localFrame.intersects(window.bounds) ? max(0, window.bounds.maxY - localFrame.minY) : 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardOverlap = 0 }
        // A half turn keeps the size, so nothing else re-lays the page out when the island changes sides.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateIslandSide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { updateIslandSide() }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        // Swipes from the screen's edges are the desktop's (edge swipes, drags to the Dock): the system's
        // own edge gestures need a second swipe, and the home indicator fades. Swiping back still works
        // from the black bars beside the picture (InteractivePopGesture), and 操作 › 返回 always does.
        .defersSystemGestures(on: .vertical)
        .persistentSystemOverlays(.hidden)
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            while !Task.isCancelled {
                saveThumbnail()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .onAppear {
            updateIslandSide()
            controller.resume()
            showStats = model.settings.desktopShowStats
            page.showStats = showStats
            statsBox.place(model.settings.desktopStatsX, model.settings.desktopStatsY)
            statsBox.shown = showStats
            let appModel = model
            statsBox.onMoved = { [weak appModel] x, y in
                appModel?.settings.desktopStatsX = Double(x); appModel?.settings.desktopStatsY = Double(y); appModel?.saveSettings()
            }
            pointerMode = page.pointerMode
            virtualMouse = page.virtualMouse
            keyboardPage = page.keyboardPage
        }
        .onDisappear {
            // Leaving pauses and keeps the link for the keep-alive window (phase 5).
            saveThumbnail()
            resetKeyboardState()
            controller.pause()
        }
        .confirmationDialog(model.text("断开连接？", "Disconnect?"), isPresented: $showDisconnect, titleVisibility: .visible) {
            Button(model.text("断开连接", "Disconnect"), role: .destructive) {
                model.closeDesktop(controller.host.id)
            }
            Button(model.text("取消", "Cancel"), role: .cancel) {}
        }
        .alert(model.text("提示", "Notice"), isPresented: Binding(
            get: { controller.notice != nil },
            set: { if !$0 { controller.notice = nil } })) {
            Button(model.text("好", "OK"), role: .cancel) { controller.notice = nil }
        } message: { Text(controller.notice ?? "") }
    }

    /// Portrait: keep the video and its gesture viewport in the same unobscured rectangle, so only this
    /// column resizes for input. Landscape: the picture is short already, so it keeps its full size and
    /// the keyboard panel floats over its lower part; the rail retains its full-height touch targets.
    /// `bleed`: how far the picture runs past the leading safe area, where the stats stay clear of the corner.
    @ViewBuilder
    private func desktopWorkspace(landscape: Bool, bottomInset: CGFloat, bleed: CGFloat = 0) -> some View {
        if landscape {
            ZStack(alignment: .bottom) {
                desktopPicture(landscape: true, bleed: bleed)
                if panel == .keyboard {
                    keyboardPanel.fixedSize(horizontal: false, vertical: true).padding(.bottom, bottomInset)
                }
            }
        } else {
            portraitWorkspace(bottomInset: bottomInset)
        }
    }

    private func portraitWorkspace(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            desktopPicture(landscape: false, bleed: 0)
            if panel == .keyboard {
                keyboardPanel.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, panel == .keyboard && keyboardPage == .ime ? bottomInset : 0)
    }

    private func desktopPicture(landscape: Bool, bleed: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack {
                DesktopVideoSurface(display: controller.display, content: contentFrame(in: geo.size))
                DesktopGestureOverlay(controller: controller, size: geo.size)
                statsOverlay(landscape: landscape).padding(.leading, landscape ? bleed : 0)
                DesktopStatusOverlay(host: controller.host.name, phase: controller.phase,
                                     hasPicture: controller.videoSize.0 > 0, windowsHost: controller.windowsHost,
                                     log: controller.log.last ?? "", failure: controller.session.failure, english: english) {
                    if let host = model.host(controller.host.id) { model.openDesktop(host) }
                } onClose: { model.closeDesktop(controller.host.id) }
                if virtualMouse { virtualMouseOverlay }
                if statsHint {
                    Text(model.text("网络状态已隐藏，可在「操作」中重新打开", "Network stats hidden; turn them back on in Ops"))
                        .font(.system(size: 13)).foregroundStyle(ink)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(panelColor, in: Capsule())
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("desktop-stats-hint")
                        .task { try? await Task.sleep(for: .milliseconds(2500)); statsHint = false }
                }
            }
            .coordinateSpace(name: Self.pictureSpace)
            .clipped()
        }
    }

    // MARK: Android desktop controls

    /// The rail is as thick in landscape as in portrait: one button deep, 4pt on the picture's side,
    /// and on the screen edge's side the gap the portrait rail leaves above the home indicator.
    /// Landscape: the rail reaches the screen edge (`edgeInset` past the safe area) and keeps
    /// `edgeClearance` of it free, for an island on that side.
    private func controlRail(landscape: Bool, edgeInset: CGFloat = 0, edgeClearance: CGFloat = 0, bottomInset: CGFloat = 0) -> some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let items: [(icon: String, title: String, selected: Bool, action: () -> Void)] = [
            ("ic_operations", model.text("操作", "Ops"), panel == .operations, { togglePanel(.operations) }),
            ("ic_keyboard", model.text("键盘", "Keys"), panel == .keyboard, {
                togglePanel(.keyboard); imeFocused = panel == .keyboard && keyboardPage == .ime
            }),
            // A tap is felt at once: from a Mac's full-screen app the host takes a moment to slide over.
            ("ic_show_desktop", model.text("显示桌面", "Desktop"), false, {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP))
            }),
            ("ic_windows_all", model.text("所有窗口", "Windows"), false, {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS))
            })
        ]
        // 操作 stays in the bottom corner: leftmost in portrait, lowest in landscape.
        let ordered = landscape ? Array(items.reversed()) : items
        return layout {
            ForEach(ordered, id: \.icon) { item in
                railItem(item.icon, item.title, selected: item.selected, landscape: landscape, action: item.action)
            }
        }
        .padding(landscape ? .leading : .top, 4)
        // The buttons sit just above the home indicator, or as close to a bare screen edge.
        .padding(landscape ? .trailing : .bottom, max(edgeClearance, railEdgeGap(landscape ? edgeInset : bottomInset)))
        .background(railColor.ignoresSafeArea(edges: landscape ? .trailing : .bottom))
    }

    private func railEdgeGap(_ inset: CGFloat) -> CGFloat { max(4, min(inset, 34) - 24) }

    private func railItem(_ icon: String, _ title: String, selected: Bool, landscape: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                AppIcon(icon, size: 22).foregroundStyle(selected ? accent : ink)
                Text(title).font(.system(size: 11)).foregroundStyle(selected ? accent : inkDim).lineLimit(1).fixedSize()
            }
            .frame(width: landscape ? railDepth : nil, height: landscape ? nil : railDepth)
            .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func operationsPanel(size: CGSize, landscape: Bool, trailing: CGFloat, bottom: CGFloat) -> some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea(edges: bottom > 0 ? [.top, .horizontal] : .all)
                .onTapGesture { dismissPanel() }
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.text("操作", "Operations")).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                        Text(controller.host.name).font(.system(size: 12)).foregroundStyle(inkDim).lineLimit(1)
                    }
                    Spacer()
                    Button { dismissPanel() } label: {
                        AppIcon("ic_close", size: 22).foregroundStyle(ink).frame(width: 48, height: 48)
                    }.buttonStyle(.plain).accessibilityLabel(model.text("关闭", "Close"))
                        .accessibilityIdentifier("desktop-op-close")
                }.padding(.leading, 16).padding(.trailing, 4).padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            panelButton("ic_exit", model.text("返回", "Back"), caption: model.text("连接保持", "Keep connected")) {
                                dismissPanel(); dismissDesktopKeepingLink()
                            }.accessibilityIdentifier("desktop-op-exit")
                            panelButton("ic_folder", model.text("文件", "Files"), caption: model.text("上传和下载", "Upload and download")) {
                                dismissPanel(); model.path.append(.files(controller.host.id))
                            }
                        }
                        section(model.text("剪贴板", "Clipboard")) {
                            HStack(spacing: 8) {
                                panelButton("ic_upload", model.text("发送手机剪贴板", "Send phone clipboard")) { sendClipboard() }
                                panelButton("ic_download", model.text("获取远程剪贴板", "Get remote clipboard")) { fetchClipboard() }
                            }
                            if let note = controller.clipNote ?? page.clipNote { Text(note).font(.system(size: 12)).foregroundStyle(inkDim) }
                        }
                        section(model.text("操作方式", "Pointer mode")) {
                            HStack(spacing: 8) {
                                choice(model.text("屏幕触控", "Touch"), selected: pointerMode == .touch) { setPointerMode(.touch) }
                                choice(model.text("鼠标指针", "Trackpad"), selected: pointerMode == .mouse) { setPointerMode(.mouse) }
                            }
                        }
                        toggleRow(model.text("声音", "Sound"), controller.audioAvailable == false
                                  ? model.text("这台电脑暂时无法传回声音", "This computer cannot send its sound right now")
                                  : model.text("在手机上播放电脑的声音", "Play the computer's sound on the phone"),
                                  value: Binding(get: { controller.audioOn }, set: { controller.setAudio($0) }))
                            .accessibilityIdentifier("desktop-audio")
                        toggleRow(model.text("仅观看", "View only"), model.text("不向电脑发送任何操作", "Do not send input to the computer"),
                            value: Binding(get: { controller.viewOnly }, set: { controller.setViewOnly($0) }))
                        toggleRow(model.text("虚拟鼠标", "Virtual mouse"), model.text("悬浮的左键、右键和滚轮", "Floating left, right buttons and scroll wheel"), value: Binding(get: { virtualMouse }, set: {
                            virtualMouse = $0
                            page.virtualMouse = $0
                        }))
                        VStack(alignment: .leading, spacing: 2) {
                            toggleRow(model.text("显示网络状态", "Show network stats"),
                                      model.text("画面上显示延迟、帧率和码率，长按可拖动", "Latency, frame rate and bitrate; long press to move"),
                                      value: Binding(get: { showStats }, set: { setShowStats($0) }))
                            if statsBox.moved {
                                Button(model.text("恢复默认位置（左上角）", "Back to the top left")) {
                                    statsBox.reset()
                                    model.settings.desktopStatsX = 0; model.settings.desktopStatsY = 0
                                    setShowStats(true)
                                }
                                .font(.system(size: 13)).foregroundStyle(accent).padding(.vertical, 6)
                                .accessibilityIdentifier("desktop-stats-reset")
                            }
                        }
                        section(model.text("帧率", "Frame rate")) {
                            HStack(spacing: 8) {
                                ForEach(DesktopPreferences.fpsOptions.filter { $0 <= max(60, UIScreen.main.maximumFramesPerSecond) }, id: \.self) { fps in
                                    choice("\(fps)", selected: controller.fps == fps) { controller.setFps(fps) }
                                }
                            }
                        }
                        section(model.text("画质", "Quality")) {
                            HStack(spacing: 8) {
                                ForEach(DesktopPreferences.qualities, id: \.self) { quality in
                                    choice(page.qualityLabel(quality), selected: controller.quality == quality) { controller.setQuality(quality) }
                                }
                            }
                        }
                        if let displays = controller.hello?.displays, displays.count > 1 {
                            section(model.text("显示器", "Display")) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(displays, id: \.id) { d in
                                            choice(d.name.isEmpty ? model.text("显示器 \(d.id)", "Display \(d.id)") : d.name, selected: controller.displayIndex == d.id) { controller.setDisplay(d.id) }
                                        }
                                    }
                                }
                            }
                        }
                        toggleRow(model.text("断开后锁定电脑", "Lock after disconnect"), model.text("断开连接时锁屏，返回不算", "Lock on disconnect, not when going back"),
                            value: Binding(get: { controller.lockOnClose }, set: { controller.setLockOnClose($0) }))
                        Button(role: .destructive) { showDisconnect = true } label: {
                            HStack(spacing: 8) {
                                AppIcon("ic_power", size: 20)
                                Text(model.text("断开连接", "Disconnect")).font(.system(size: 15, weight: .medium))
                            }.foregroundStyle(Palette.danger).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.danger.opacity(0.6), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
                }.accessibilityIdentifier("desktop-operations-scroll")
            }
            .frame(width: landscape ? min(340, max(0, size.width - 80)) : size.width,
                   height: landscape ? size.height * 0.92 : min(size.height * 0.7, size.height - bottom))
            .background(panelColor, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.trailing, landscape ? trailing : 0)
        }
        .padding(.bottom, bottom)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(inkDim)
            content()
        }
    }

    /// Sized to match the toggle rows below: 15pt titles, 26pt icons, at least 72pt tall (84 with a caption).
    private func panelButton(_ icon: String, _ title: String, caption: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AppIcon(icon, size: 26)
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(2).minimumScaleFactor(0.85)
                if let caption { Text(caption).font(.system(size: 12)).foregroundStyle(inkDim).lineLimit(1) }
            }.foregroundStyle(ink).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: caption == nil ? 72 : 84).padding(.horizontal, 8).padding(.vertical, 12)
                .background(Color.white.opacity(20/255), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(selected ? accent : ink).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? accent.opacity(0.22) : Color.white.opacity(20/255), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleRow(_ title: String, _ subtitle: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(ink)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(inkDim)
            }
        }.tint(accent)
    }

    // MARK: Keyboard shortcut bar and PC keys

    private var keyboardPanel: some View {
        VStack(spacing: 0) {
            if !composingText.isEmpty && keyboardPage == .ime {
                HStack {
                    Text(composingText).font(.system(size: 14)).foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(panelColor, in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
                    Spacer()
                }.padding(.leading, 12).padding(.bottom, 6)
            }
            if !shortcutBar && keyboardPage == .ime {
                HStack {
                    Spacer()
                    Button { shortcutBar = true } label: {
                        HStack(spacing: 6) {
                            AppIcon("ic_keyboard", size: 16)
                            Text(model.text("快捷键 ▴", "Shortcuts ▴")).font(.system(size: 12))
                        }.foregroundStyle(ink).padding(.horizontal, 12).padding(.vertical, 6).background(panelColor, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("desktop-kb-toggle")
                    Button { dismissPanel() } label: {
                        AppIcon("ic_close", size: 16).foregroundStyle(ink).frame(width: 36, height: 32)
                            .background(panelColor, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(model.text("关闭键盘", "Close keyboard"))
                }.padding(.trailing, 8).padding(.bottom, 6)
            } else {
                shortcutKeys
            }
            if keyboardPage == .more { pcKeysPage }
            DesktopIMEInput(focused: imeFocused, onText: { text in
                if case .frames(let frames) = page.commitIME(text, composing: false) { frames.forEach(controller.input) }
                latchRevision += 1
            }, onControl: { hid in sendKey(hid) }, onComposing: { composingText = $0 })
                .frame(height: 1).opacity(0.01).accessibilityIdentifier("desktop-ime-field")
        }
    }

    private var shortcutKeys: some View {
        _ = latchRevision
        return HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    barKey("Esc") { sendKey(HidUsage.ESCAPE) }
                    barKey("Tab") { sendKey(HidUsage.TAB) }
                    ForEach(DesktopPageModel.modifierKeys(os: controller.hello?.os ?? controller.host.system), id: \.hid) { key in
                        barKey(key.label, state: page.latch.state(key.hid), hold: { page.holdModifier(key.hid); latchRevision += 1 }) {
                            page.tapModifier(key.hid); latchRevision += 1
                        }
                    }
                    ForEach(Array(zip(["←", "↑", "↓", "→"], [HidUsage.LEFT, HidUsage.UP, HidUsage.DOWN, HidUsage.RIGHT])), id: \.1) { label, hid in
                        barKey(label, narrow: true) { sendKey(hid) }
                    }
                }
            }
            barKey(keyboardPage == .more ? "ABC" : "⋯", state: keyboardPage == .more ? .locked : .off) {
                keyboardPage = keyboardPage == .more ? .ime : .more
                page.keyboardPage = keyboardPage; imeFocused = keyboardPage == .ime
            }.accessibilityIdentifier("desktop-kb-more")
            if keyboardPage == .ime {
                barKey("▾", narrow: true) { shortcutBar = false }.accessibilityIdentifier("desktop-kb-hide-bar")
            }
            // iOS has no Android system Back key; keep a dedicated dismissal affordance.
            barKey("×", narrow: true) { dismissPanel() }.accessibilityLabel(model.text("关闭键盘", "Close keyboard"))
        }.frame(height: 36).padding(6).background(panelColor)
    }

    private func barKey(_ title: String, state: ModifierLatch.State = .off, narrow: Bool = false,
                        hold: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Text(title).font(.system(size: 13, weight: state == .locked ? .semibold : .regular))
            .foregroundStyle(state == .locked ? panelColor : state == .once ? accent : ink)
            .padding(.horizontal, 10).frame(minWidth: narrow ? 32 : 42).frame(height: 36)
            .background(state == .locked ? accent : state == .once ? accent.opacity(0.25) : Color.white.opacity(26/255), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(state == .once ? accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture()).onEnded { value in
                switch value {
                case .first: hold?()
                case .second: action()
                }
            })
            .accessibilityAddTraits(.isButton).accessibilityAction { action() }
            .accessibilityValue(state == .locked ? model.text("已锁定", "Locked") : state == .once ? model.text("单次生效", "Once") : "")
    }

    private var pcKeysPage: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(DesktopPageModel.moreKeys(), id: \.hid) { key in
                    Button {
                        if key.hid == HidUsage.LEFT_SHIFT { page.tapModifier(key.hid); latchRevision += 1 } else { sendKey(key.hid) }
                    } label: {
                        Text(key.label).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(ink)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(key.hid == HidUsage.LEFT_SHIFT && page.latch.state(key.hid) != .off ? accent.opacity(0.4) : Color.white.opacity(31/255), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(DesktopPageModel.comboKeys(os: controller.hello?.os ?? controller.host.system), id: \.label) { key in
                    Button {
                        page.combo(key.keys).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }; latchRevision += 1
                    } label: {
                        Text(key.label).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(ink)
                            .frame(maxWidth: .infinity).frame(height: 42).background(Color.white.opacity(41/255), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 8).padding(.bottom, 10).background(panelColor)
    }

    private func sendKey(_ hid: Int) {
        page.pressKey(hid).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }
        latchRevision += 1
    }

    // MARK: Overlays

    private static let pictureSpace = "desktop-picture"

    private func setShowStats(_ on: Bool) {
        showStats = on; statsBox.shown = on; controller.setShowStats(on); model.settings.desktopShowStats = on; model.saveSettings()
    }

    /// The figures over the picture, top left until a long press moves them (Android NetworkStats). Only their
    /// ✕ takes a touch: anything else on them reaches the picture under them (`DesktopGestureView`, `OverlayTouch`).
    /// Portrait keeps its plain lines, landscape Android's compact translucent panel.
    private func statsOverlay(landscape: Bool) -> some View {
        let poor: Bool = { if case .connected(let p, _) = controller.phase { return p }; return false }()
        let recovering: Bool = { if case .recovering = controller.phase { return true }; return false }()
        return Group {
            if controller.videoSize.0 > 0 {
                if showStats {
                    DesktopStatsPlacement(fx: statsBox.fx, fy: statsBox.fy, margin: landscape ? 8 : 12, box: statsBox) {
                        statsPanel(landscape: landscape, poor: poor, recovering: recovering)
                    }
                } else if let warn = DesktopStatsText.warning(poor: poor, recovering: recovering, english: english) {
                    Group {
                        if landscape {
                            HStack(spacing: 5) {
                                Circle().fill(toneColor(warn.tone, android: true)).frame(width: 6, height: 6)
                                Text(warn.text).font(.system(size: 11)).foregroundStyle(ink)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.black.opacity(0.6), in: Capsule())
                        } else {
                            Text(warn.text).font(.system(size: 12, weight: .medium)).foregroundStyle(toneColor(warn.tone))
                                .padding(6).background(Color.black.opacity(0.45), in: Capsule())
                        }
                    }
                    .accessibilityIdentifier("desktop-network-warning")
                    .padding(landscape ? 8 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func statsPanel(landscape: Bool, poor: Bool, recovering: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let lines = DesktopStatsText.lines(stats: controller.stats, poor: poor, recovering: recovering, transport: .unknown, english: english)
        let dragging = statsBox.dragging
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: landscape ? 0 : 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if landscape {
                        Text(line.text).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(toneColor(line.tone, android: true)).lineLimit(1)
                            .frame(height: 14, alignment: .leading)
                    } else {
                        Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(toneColor(line.tone)).lineLimit(1)
                    }
                }
            }
            .padding(.leading, landscape ? 7 : 0).padding(.trailing, landscape ? 26 : 22).padding(.vertical, landscape ? 4 : 0)
            .allowsHitTesting(false)
            Button {
                setShowStats(false)
                statsHint = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(inkDim)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: landscape ? 0 : 6, y: landscape ? 0 : -6)
            .accessibilityLabel(model.text("关闭", "Close"))
            .accessibilityIdentifier("desktop-stats-close")
        }
        .background {
            if landscape || dragging {
                shape.fill(Color.black.opacity(dragging ? 0.7 : 140 / 255.0)).padding(landscape ? 0 : -4).allowsHitTesting(false)
            }
        }
        .overlay { if dragging { shape.stroke(Color.white.opacity(0.6), lineWidth: 1.5).padding(landscape ? 0 : -4).allowsHitTesting(false) } }
        .scaleEffect(dragging ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .background(GeometryReader { g in
            Color.clear.preference(key: DesktopStatsFrameKey.self, value: g.frame(in: .named(Self.pictureSpace))).allowsHitTesting(false)
        })
        .onPreferenceChange(DesktopStatsFrameKey.self) { statsBox.frame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-stats")
    }

    /// The gesture view's viewport while it matches this picture, else the unzoomed fit.
    private func viewport(in size: CGSize) -> Viewport {
        let remote = controller.remoteSize
        if let vp = controller.viewport, vp.viewWidth == Float(size.width), vp.viewHeight == Float(size.height),
           vp.remoteWidth == max(1, remote.0), vp.remoteHeight == max(1, remote.1) { return vp }
        return Viewport(viewWidth: Float(size.width), viewHeight: Float(size.height),
                        remoteWidth: max(1, remote.0), remoteHeight: max(1, remote.1))
    }

    /// Where the zoomed and panned picture sits, as on Android; nil before the first frame.
    private func contentFrame(in size: CGSize) -> CGRect? {
        guard controller.remoteSize.0 > 0, size.width > 0 else { return nil }
        let vp = viewport(in: size)
        return CGRect(x: CGFloat(vp.left), y: CGFloat(vp.top), width: CGFloat(vp.contentWidth), height: CGFloat(vp.contentHeight))
    }

    private var virtualMouseOverlay: some View {
        VirtualMousePad { button, down in
            controller.input(DesktopProtocol.button(button, down: down))
        } wheel: { dx, dy in
            controller.input(DesktopProtocol.wheel(dx: dx, dy: dy))
        }
        .frame(width: 140, height: 160)
        .position(x: 100, y: 280)
    }

    // MARK: Helpers

    private func updateIslandSide() {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.interfaceOrientation
        // Landscape left: the home button's side, so the top of the phone, is on the right.
        islandLeading = orientation != .landscapeLeft
    }

    private func setPointerMode(_ mode: PointerMode) {
        if mode != pointerMode { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        pointerMode = mode
        controller.setPointerMode(mode)
    }

    private func togglePanel(_ p: DesktopPanel) {
        panel = panel == p ? .none : p
        page.panel = panel
        if panel != .keyboard { resetKeyboardState() }
    }
    private func dismissPanel() { panel = .none; page.dismissPanel(); resetKeyboardState() }

    private func resetKeyboardState() {
        imeFocused = false
        composingText = ""
        shortcutBar = false
        keyboardPage = .ime
        page.keyboardPage = .ime
        for hid in [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT, HidUsage.LEFT_GUI, HidUsage.LEFT_SHIFT] where page.latch.state(hid) != .off {
            page.tapModifier(hid)
        }
        latchRevision += 1
    }

    private func toneColor(_ tone: DesktopStatsText.Tone, android: Bool = false) -> Color {
        switch tone {
        case .ink: return android ? ink : .white
        case .dim: return android ? inkDim : .white.opacity(0.65)
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }

    private func sendClipboard() {
        let text = UIPasteboard.general.string ?? ""
        controller.clipNote = page.clipSentNote(empty: text.isEmpty)
        if !text.isEmpty { controller.send(DesktopProtocol.clipSet(text)) }
    }

    private func fetchClipboard() {
        controller.send(DesktopProtocol.req(DesktopProtocol.REQ_CLIP_GET))
    }

    private func saveThumbnail() {
        let hostID = controller.host.id
        controller.display.snapshot { image in
            guard let image, model.host(hostID) != nil else { return }
            model.desktopThumbnails.save(image, for: hostID)
        }
    }

    private func dismissDesktopKeepingLink() {
        if model.path.last == .desktop(controller.host.id) { _ = model.path.popLast() } else { model.path.removeAll { $0 == .desktop(controller.host.id) } }
    }
}

private struct RailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct RailWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
