import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

struct HomeHostsTab: View {
    @EnvironmentObject var model: AppModel
    let search: String
    /// Landscape: the header line lives on `HomeCompactBar`.
    var compact = false
    var filtered: [Host] { model.hosts.filter { search.isEmpty || "\($0.name) \($0.address) \($0.username)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                HomeListHeader(label: model.text("主机 · \(model.hosts.count)", "Hosts · \(model.hosts.count)"), addLabel: model.text("添加主机", "Add host"), id: "add-host") { model.sheet = .editor(nil) }
            }
            if model.hosts.isEmpty {
                HomeEmptyState(logo: true, title: model.text("从第一台主机开始", "Start with your first host"),
                               message: model.text("保存远端主机，运行 AI 编程工具。\n可直连，也可使用手机已有 VPN。", "Save remote hosts and run AI coding tools.\nConnect directly or use your phone’s VPN.")) {
                    AccentCapsuleButton(title: model.text("添加主机", "Add host"), id: "empty-add-host") { model.sheet = .editor(nil) }
                }
            } else if filtered.isEmpty {
                HomeEmptyState(title: model.text("没有匹配的主机", "No matching hosts"), message: model.text("试试其他名称或地址", "Try another name or address")) { EmptyView() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { host in
                            HostCard(host: host, desktops: model.desktops, thumbnails: model.desktopThumbnails)
                        }
                    }.padding(.horizontal, 18).padding(.top, compact ? 8 : 0).padding(.bottom, 18).reportsHomeScroll(.hosts)
                }.homeScrollSpace(.hosts).accessibilityIdentifier("host-grid")
            }
        }
    }
}

/// Android PR 218 screen card: image opens desktop, reachability and desktop state sit above the 70-point information strip.
struct HostCard: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    @ObservedObject var desktops: DesktopStore
    @ObservedObject var thumbnails: DesktopThumbnails
    @State private var deleteConfirm = false
    private var state: DesktopButton { model.desktopButton(for: host, sessionConnected: true, preserveOffline: true) }
    private var hasDesktop: Bool { state != .hidden }
    private var offline: Bool { model.reachability[host.id]?.isOffline == true }
    private var live: Bool { [.connected, .poor, .recovering, .connecting].contains(state) }
    private var green: Color { Color(uiColor: UIColor(hex: 0x7FD19B)) }
    private var warning: Color { Color(uiColor: UIColor(hex: 0xF2C46D)) }
    private let stripHeight: CGFloat = 70
    private var pillTint: Color { state == .connected ? green : state == .connecting ? .white.opacity(0.7) : warning }
    private var plugins: [String] {
        if let plugins = host.plugins { return ["tmux", "psmux", "mosh"].filter(plugins.contains) }
        return host.mode == .tmux ? ["tmux"] : []
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Button {
                    if hasDesktop && !offline { model.openDesktop(host) } else { model.path.append(.host(host.id)) }
                } label: { backdrop(size: geo.size).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(host.name + " · " + (hasDesktop && !offline ? model.text("打开桌面", "Open desktop") : model.text("主机详情", "Host details")))
                .accessibilityIdentifier("host-screen-\(host.id)")
                .accessibilityValue(thumbnails.images[host.id] == nil ? model.text("尚无桌面预览", "No desktop preview yet") : model.text("已保存桌面预览", "Saved desktop preview"))
                strip
                VStack {
                    HStack(spacing: 6) {
                        ReachabilityLabel(state: model.reachability[host.id] ?? .checking, onImage: hasDesktop, fontSize: 13)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(hasDesktop ? Color(uiColor: UIColor(hex: 0x141416)).opacity(0.6) : Palette.foreground.opacity(0.07), in: Capsule())
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("host-status-\(host.id)")
                        if hasDesktop { pill }
                        Spacer(minLength: 0)
                    }
                    Spacer()
                }.padding(12).allowsHitTesting(false)
            }
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(live ? (state == .connected ? green : warning) : .clear, lineWidth: 2).allowsHitTesting(false))
            .contextMenu { actions }
        }
        .aspectRatio(16 / 9.6, contentMode: .fit)
        .task(id: host.id) { thumbnails.load(host.id) }
        .confirmationDialog(model.text("删除 \(host.name)？", "Delete \(host.name)?"), isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button(model.text("删除主机", "Delete host"), role: .destructive) { model.deleteHost(host) }
        }
    }
    @ViewBuilder private func backdrop(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            if hasDesktop, let picture = thumbnails.images[host.id] {
                Image(uiImage: picture.image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                    .saturation(offline ? 0 : 1).overlay(Color.black.opacity(offline ? 0.45 : 0))
                Image(uiImage: picture.frosted).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                    .saturation(offline ? 0 : 1)
                    .overlay(Color(uiColor: UIColor(hex: 0x161618)).opacity(offline ? 0.62 : 94 / 255))
                    .mask(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().frame(height: stripHeight) })
                Color.white.opacity(0.08).frame(height: 1).padding(.bottom, stripHeight)
            } else if hasDesktop {
                let brand = offline ? Color(uiColor: UIColor(hex: 0x6A6A6E)) : Color(uiColor: UIColor(hex: HostSystemMark(system: host.system).info?.brand ?? 0xB65F42))
                Color(uiColor: UIColor(hex: 0x1C1C1E))
                RadialGradient(colors: [brand.opacity(0.3), Color(uiColor: UIColor(hex: 0x151517))], center: .center, startRadius: 0, endRadius: 300)
                HostSystemLogo(system: host.system, monochrome: offline).frame(width: 44, height: 44).foregroundStyle(.white.opacity(0.7))
                    .opacity(offline ? 0.5 : 1).frame(width: size.width, height: max(0, size.height - stripHeight)).padding(.bottom, stripHeight)
                Color.black.opacity(0.28).frame(height: stripHeight)
            } else {
                RadialGradient(colors: [Palette.foreground.opacity(0.05), .clear], center: .center, startRadius: 0, endRadius: 300)
                VStack(spacing: 0) {
                    AppIcon("ic_desktop_off", size: 44).foregroundStyle(Palette.secondary.opacity(0.55)).frame(height: 44)
                    // A host never probed is not a host without a desktop: it is checked once a login reaches it.
                    let probe = DesktopProbe.decode(host.desktop)
                    Text(probe == nil ? model.text("桌面尚未检测", "Desktop not checked yet") : probe == .no ? model.text("没有图形桌面", "No graphical desktop")
                         : probe == .yes ? model.text("暂不支持这台主机的桌面", "This desktop is not supported yet") : model.text("桌面暂不可用", "Desktop unavailable"))
                        .font(.system(size: 16)).foregroundStyle(Palette.secondary).padding(.top, 6)
                    if probe == nil || probe == .no {
                        Text(probe == nil ? model.text("连接主机后自动检测桌面", "Connect to check the desktop automatically") : model.text("这台主机只能用终端", "This host only has a terminal"))
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary.opacity(0.7))
                    }
                }.frame(width: size.width, height: max(0, size.height - stripHeight)).padding(.bottom, stripHeight)
                Palette.foreground.opacity(0.035).frame(height: stripHeight)
                Palette.foreground.opacity(0.07).frame(height: 1).padding(.bottom, stripHeight)
            }
        }.frame(width: size.width, height: size.height).clipped()
    }
    private var strip: some View {
        HStack(spacing: 0) {
            Button { model.path.append(.host(host.id)) } label: {
                HStack(spacing: 10) {
                    HostSystemLogo(system: host.system).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name).font(.system(size: 18, weight: .regular)).lineLimit(1)
                            .foregroundStyle(hasDesktop ? .white.opacity(offline ? 0.6 : 1) : Palette.foreground)
                        Text("\(host.username)@\(host.address):\(host.port)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(hasDesktop ? .white.opacity(0.62) : Palette.secondary.opacity(0.75))
                            .accessibilityIdentifier("host-login-\(host.id)")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
                    HStack(spacing: 6) {
                        ForEach(plugins, id: \.self) { plugin in
                            Text(plugin).font(.system(size: 13, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
                                .foregroundStyle(hasDesktop ? .white.opacity(0.85) : Palette.secondary)
                                .background((hasDesktop ? Color.white : Palette.foreground).opacity(hasDesktop ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.fixedSize()
                }.padding(.leading, 14).frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("host-\(host.name)")
            Menu { actions } label: {
                AppIcon("ic_more_vert").foregroundStyle(hasDesktop ? .white.opacity(0.85) : Palette.secondary)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.accessibilityIdentifier("host-menu-\(host.id)").accessibilityLabel(model.text("主机选项：", "Host options: ") + host.name)
        }.padding(.trailing, 2).frame(height: stripHeight)
            .background {
                Button { model.path.append(.host(host.id)) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityHidden(true)
            }
    }
    @ViewBuilder private var pill: some View {
        if let label = pillLabel {
            HStack(spacing: 6) {
                AppIcon("ic_desktop", size: 13).foregroundStyle(pillTint)
                    .accessibilityLabel(model.text("桌面", "Desktop"))
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(pillTint).lineLimit(1)
            }.padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(uiColor: UIColor(hex: 0x141416)).opacity(0.6), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("host-desktop-\(host.id)")
        }
    }
    private var pillLabel: String? {
        switch state {
        case .connected: return model.text("已连接", "Connected")
        case .connecting: return model.text("连接中", "Connecting")
        case .poor: return model.text("网络较差", "Poor network")
        case .recovering: return model.text("重新连接中", "Reconnecting")
        case .needsAction: return model.text("需要登录", "Sign-in required")
        default: return nil
        }
    }
    @ViewBuilder private var actions: some View {
        Button { model.sheet = .launch(host, false) } label: { Label(model.text("打开终端", "Open terminal"), image: "ic_sessions") }
        Button { model.sheet = .launch(host, true) } label: { Label("Agent", image: "ic_agent") }
        Button { model.path = [.host(host.id), .files(host.id)] } label: { Label(model.text("查看文件", "Browse files"), image: "ic_folder") }
        if live {
            Divider()
            Button { model.closeDesktop(host.id) } label: { Label(model.text("断开桌面", "Disconnect desktop"), image: "ic_desktop_off") }
        }
        Divider()
        Button { model.sheet = .editor(host) } label: { Label(model.text("编辑主机", "Edit host"), image: "ic_edit") }
        Button { model.sheet = .plugins(host) } label: { Label(model.text("安装插件", "Install plugins"), image: "ic_plugin") }
        Button(role: .destructive) { deleteConfirm = true } label: { Label(model.text("删除主机", "Delete host"), image: "ic_delete") }
    }
}
