import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import RoamttyCore

struct SettingsScreen: View {
    private enum ImportKind { case font, downloadFolder }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var fonts = FontCatalog.shared
    @State private var importKind = ImportKind.font
    @State private var showImporter = false
    @State private var fontError: String?
    @State private var downloadFolderError: String?
    /// The user said no to notifications in iOS: only Settings can turn them on again.
    @State private var notificationsDenied = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact { landscape } else { portrait }
            }.pageBackground().navigationTitle(model.text("设置", "Settings"))
                .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { doneButton } }
        }
        .onChange(of: model.settings) { _ in model.saveSettings() }
        .fileImporter(isPresented: $showImporter,
            allowedContentTypes: importKind == .downloadFolder ? [.folder] : [UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]) { result in
            // Keep the purpose separate from isPresented: SwiftUI clears that
            // binding before delivering the selected document's completion.
            do {
                let url = try result.get()
                switch importKind {
                case .font:
                    model.settings.font = try fonts.install(url); fontError = nil
                case .downloadFolder:
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    model.settings.downloadBookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    downloadFolderError = nil
                }
                model.saveSettings()
            } catch let error as CocoaError where error.code == .userCancelled {
                // Dismissing the native picker leaves the existing selection intact.
            } catch {
                if importKind == .font { fontError = error.localizedDescription } else { downloadFolderError = error.localizedDescription }
            }
        }
    }
    private var doneButton: some View { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("settings-done") }
    private var portrait: some View {
        ScrollView {
            VStack(spacing: 24) { appearancePanel; languagePanel; terminalPanel; notificationsPanel; desktopPanel; filesPanel }
                .padding(16).frame(maxWidth: 720)
        }.accessibilityIdentifier("settings-scroll").frame(maxWidth: .infinity)
    }
    /// Landscape, where height is short: the flat bar, and the panels as two columns in the same reading order, the
    /// look and the terminal on the left, what happens in the background on the right.
    private var landscape: some View {
        VStack(spacing: 0) {
            LandscapeBar(title: model.text("设置", "Settings")) { EmptyView() } trailing: { doneButton.buttonStyle(TextActionStyle()) }
            ScrollView {
                LandscapeColumns(spacing: 20) { appearancePanel; languagePanel; terminalPanel } right: { notificationsPanel; desktopPanel; filesPanel }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }.accessibilityIdentifier("settings-scroll")
        }
    }
    private var appearancePanel: some View {
        Panel(title: model.text("外观", "Appearance")) {
            themeRow(.system, model.text("跟随系统", "System")).panelDivider()
            themeRow(.dark, model.text("深色", "Dark")).panelDivider()
            themeRow(.light, model.text("浅色", "Light"))
        }
    }
    private var languagePanel: some View {
        Panel(title: model.text("语言", "Language")) {
            checkRow("简体中文", selected: !model.english, id: "language-zh") { model.settings.language = "zh-Hans"; model.saveSettings() }.panelDivider()
            checkRow("English", selected: model.english, id: "language-en") { model.settings.language = "en"; model.saveSettings() }
        }
    }
    private var terminalPanel: some View {
        Panel(title: model.text("终端", "Terminal")) {
            Picker(model.text("字体", "Font"), selection: $model.settings.font) {
                Text(model.text("系统等宽", "System monospace")).tag(TerminalFontSelection.system).accessibilityIdentifier("settings-font-system")
                ForEach(TerminalFontSelection.bundled, id: \.self) { name in Text(name.replacingOccurrences(of: "-Regular", with: "")).tag(name) }
                if let custom = fonts.custom { Text(custom.displayName).tag(TerminalFontSelection.custom).accessibilityIdentifier("settings-font-custom") }
            }.padding(16).panelDivider().accessibilityIdentifier("settings-font").accessibilityValue(fonts.valueLabel(model.settings.font, english: model.english))
            Button {
                fontError = nil
                importKind = .font
                showImporter = true
            } label: {
                InfoRow(title: model.text("导入字体", "Import font"), value: "TTF / OTF · ≤16 MiB", icon: "textformat")
            }.panelDivider().accessibilityIdentifier("settings-font-import")
            if fonts.custom != nil {
                Button(model.text("清除自定义字体", "Clear custom font"), role: .destructive) {
                    do { model.settings.font = try fonts.clear(selection: model.settings.font); fontError = nil; model.saveSettings() } catch { fontError = error.localizedDescription }
                }.padding(16).panelDivider().accessibilityIdentifier("settings-font-clear-custom")
            }
            if let fontError { Text(fontError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-font-error") }
            VStack(spacing: 10) {
                let preview = fonts.font(selection: model.settings.font, size: model.settings.fontSize)
                HStack {
                    Text(model.text("字号", "Font size"))
                    Spacer()
                    Text("\(Int(model.settings.fontSize)) pt").foregroundStyle(Palette.secondary).accessibilityIdentifier("settings-font-size-value")
                }
                Slider(value: $model.settings.fontSize, in: 8...28, step: 1).accessibilityLabel(model.text("字号", "Font size")).accessibilityIdentifier("settings-font-size")
                Text("❯ ssh developer@roamtty\n你好，世界  echo 'Hello, world'\nλ → 0123456789 {} []").font(Font(preview))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("settings-font-preview")
                    .accessibilityValue(preview.fontName)
            }.padding(16).panelDivider()
            Toggle(model.text("固定工具箱", "Keep toolbox open"), isOn: $model.settings.toolboxPinned).padding(16).accessibilityIdentifier("settings-toolbox-pinned")
        }
    }
    private var notificationsPanel: some View {
        Panel(title: model.text("通知", "Notifications"), footer: model.text(
            "Agent 等你确认或做完一轮（超过 1 分钟）时提醒，点通知进入该会话。App 离开屏幕后，iOS 只让它再运行约半分钟，之后的变化回到 App 时提醒。",
            // swiftlint:disable:next line_length - one English paragraph
            "Tells you when an agent needs you or finishes a turn of over a minute; tap it to open the session. iOS lets the app run only about half a minute after it leaves the screen; later changes are told once you are back.")) {
            ForEach(AgentNotifications.allCases, id: \.self) { option in
                checkRow(option.label(english: model.english), selected: model.settings.agentNotifications == option, id: "settings-notify-\(option.rawValue)") {
                    model.settings.agentNotifications = option; model.saveSettings()
                }.panelDivider(option != .off || notificationsDenied)
            }
            if notificationsDenied {
                Button { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) } } label: {
                    InfoRow(title: model.text("在系统设置中允许通知", "Allow notifications in Settings"), icon: "bell.slash")
                }.accessibilityIdentifier("settings-notify-system")
            }
        }
        .task(id: scenePhase) { notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
    }
    private var desktopPanel: some View {
        Panel(title: model.text("远程桌面", "Remote desktop")) {
            HStack {
                Text(model.text("离开后保持", "Keep link after leaving"))
                Spacer()
                Picker(model.text("离开后保持", "Keep link after leaving"), selection: $model.settings.desktopKeepAliveMinutes) {
                    Text(model.text("5 分钟", "5 minutes")).tag(5)
                    Text(model.text("10 分钟", "10 minutes")).tag(10)
                    Text(model.text("30 分钟", "30 minutes")).tag(30)
                }.labelsHidden().accessibilityIdentifier("settings-desktop-keepalive")
            }.padding(16).panelDivider()
            Toggle(model.text("显示网络状态", "Show network stats"), isOn: $model.settings.desktopShowStats)
                .padding(16).panelDivider().accessibilityIdentifier("settings-desktop-stats")
            Text(model.text("能开桌面的主机会在会话卡片和主机页显示桌面入口。首次打开会在主机上安装桌面插件。",
                "Hosts with a desktop show a desktop entry on their session cards and host page. The first open installs the desktop plugin on the host."))
                .font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
    private var filesPanel: some View {
        Panel(title: model.text("文件", "Files")) {
            Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).padding(16).panelDivider().accessibilityIdentifier("settings-hidden-files")
            Button {
                downloadFolderError = nil
                importKind = .downloadFolder
                showImporter = true
            } label: {
                InfoRow(title: model.text("下载目录", "Download folder"), value: model.settings.downloadBookmark == nil ? "Roamtty/Downloads" : model.text("自定义目录", "Custom folder"), icon: "folder")
            }.panelDivider().accessibilityIdentifier("settings-download-folder")
            if let downloadFolderError { Text(downloadFolderError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-download-folder-error") }
            if model.settings.downloadBookmark != nil {
                Button(model.text("恢复默认下载目录", "Use default download folder")) { model.settings.downloadBookmark = nil; downloadFolderError = nil; model.saveSettings() }.padding(16)
            }
        }
    }
    private func themeRow(_ theme: AppTheme, _ title: String) -> some View {
        checkRow(title, selected: model.settings.theme == theme, id: "theme-\(theme.rawValue)") { model.settings.theme = theme; model.saveSettings() }
    }
    /// Android `CheckRow`: a single-choice row with a trailing check on the selection.
    private func checkRow(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Palette.foreground)
                Spacer()
                AppIcon("ic_check", size: 20).foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
            }.font(.body).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
