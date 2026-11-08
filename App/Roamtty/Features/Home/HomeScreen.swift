import SwiftUI
import RoamttyCore

/// Android's home page: 会话 and 主机 tabs in the toolbar, each with a count and a + above its list. Swiping moves
/// between them; search filters the tab in view. In landscape, where height is short, one `HomeCompactBar` holds it
/// all and slides away as a list scrolls on, coming back as soon as it scrolls back.
struct HomeScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// How much of the landscape bar has slid away, 0 to `HomeCompactBar.height`.
    @State private var barHidden: CGFloat = 0
    @State private var lastScroll: [HomeTab: CGFloat] = [:]
    @State private var barSnap: Task<Void, Never>?
    private var compact: Bool { verticalSizeClass == .compact }
    var body: some View {
        VStack(spacing: 0) {
            if compact {
                HomeCompactBar(groups: model.sessionGroups(model.searchedSessions(model.sessionsByActivity, search)),
                               searching: searching, toggleSearch: toggleSearch)
                    .frame(height: HomeCompactBar.height).offset(y: -barHidden)
                    .frame(height: max(0, HomeCompactBar.height - barHidden), alignment: .top).clipped()
            } else { header }
            if searching {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField(model.homeTab == .sessions ? model.text("标题、主机、地址或用户名", "Title, host, address or username") : model.text("名称、地址或用户名", "Name, address or username"), text: $search)
                        .focused($searchFocused).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("host-search")
                    Button {
                        search = ""
                        searching = false
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary)
                    }.accessibilityLabel(model.text("关闭搜索", "Close search")).accessibilityIdentifier("host-search-close")
                }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            TabView(selection: $model.homeTab) {
                HomeSessionsTab(search: search, compact: compact).tag(HomeTab.sessions)
                HomeHostsTab(search: search, compact: compact).tag(HomeTab.hosts)
            }.tabViewStyle(.page(indexDisplayMode: .never)).accessibilityIdentifier("home-pager")
                .environment(\.homeScrolled, scrolled)
        }.pageBackground().toolbar(.hidden, for: .navigationBar)
            .onChange(of: compact) { _ in barHidden = 0 }
            .onChange(of: searching) { _ in barHidden = 0 }
            .task(id: model.hosts) {
                while !Task.isCancelled { await model.probeHosts(model.hosts); do { try await Task.sleep(for: .seconds(30)) } catch { break } }
            }

    }
    private func toggleSearch() { withAnimation { searching.toggle() }; searchFocused = searching; if !searching { search = "" } }
    /// A list in `tab` has its top at `offset`: the bar slides by as much as it moved, all the way back at the top, and
    /// once the list rests it settles on whichever end is nearer. It stays while the search is open.
    private func scrolled(_ tab: HomeTab, _ offset: CGFloat) {
        let moved = offset - (lastScroll[tab] ?? offset)
        lastScroll[tab] = offset
        guard compact, !searching, tab == model.homeTab, moved != 0 else { return }
        barHidden = offset >= 0 ? 0 : min(HomeCompactBar.height, max(0, barHidden - moved))
        barSnap?.cancel()
        barSnap = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            withAnimation(.easeOut(duration: 0.18)) { barHidden = barHidden > HomeCompactBar.height / 2 ? HomeCompactBar.height : 0 }
        }
    }
    // A flat header matches the host cards instead of acquiring iOS 26 toolbar glass.
    private var header: some View {
        HStack {
            Button { withAnimation(.easeOut(duration: 0.2)) { model.drawer = true } } label: {
                AppIcon("ic_sidebar", size: 26).foregroundStyle(Palette.foreground)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.accessibilityLabel(model.text("打开菜单", "Open menu")).accessibilityIdentifier("open-drawer")
            Spacer(minLength: 0)
            HomeTabs()
            Spacer(minLength: 0)
            Button(action: toggleSearch) {
                AppIcon("ic_search", size: 26).foregroundStyle(Palette.foreground)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.accessibilityLabel(model.homeTab == .sessions ? model.text("搜索会话", "Search sessions") : model.text("搜索主机", "Search hosts"))
                .accessibilityIdentifier("search-hosts")
        }.buttonStyle(.plain).padding(.horizontal, 6).frame(height: 64)
    }

}

/// The home page's tabs in the toolbar: the names side by side, the selected one in full colour with a short bar beneath it.
struct HomeTabs: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            tab(model.text("会话", "Sessions"), .sessions, id: "home-tab-sessions")
            tab(model.text("主机", "Hosts"), .hosts, id: "home-tab-hosts")
        }
    }
    private func tab(_ title: String, _ value: HomeTab, id: String) -> some View {
        let active = model.homeTab == value
        return Button { withAnimation(.easeInOut(duration: 0.25)) { model.homeTab = value } } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 22, weight: .regular)).lineLimit(1)
                    .foregroundStyle(active ? Palette.foreground : Palette.secondary.opacity(0.7))
                Capsule().fill(active ? Palette.foreground : Color.clear).frame(width: 22, height: 3)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected, .isHeader] : []).accessibilityIdentifier(id)
    }
}

/// The home page's one bar in landscape: the drawer, the tabs as a segmented control with how many each holds, the
/// session filters, then search and add.
struct HomeCompactBar: View {
    static let height: CGFloat = 48
    @EnvironmentObject var model: AppModel
    /// The groups of the sessions the list shows, for its filters.
    let groups: [SessionGroupMembers]
    let searching: Bool
    let toggleSearch: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            icon("ic_sidebar", label: model.text("打开菜单", "Open menu"), id: "open-drawer") {
                withAnimation(.easeOut(duration: 0.2)) { model.drawer = true }
            }
            HStack(spacing: 0) {
                tab(model.text("会话", "Sessions"), count: model.records.count, .sessions, id: "home-tab-sessions")
                tab(model.text("主机", "Hosts"), count: model.hosts.count, .hosts, id: "home-tab-hosts")
            }.padding(3).background(Palette.foreground.opacity(0.07), in: Capsule())
            // Takes the room between the tabs and search even when it holds nothing, so search and add stay at the end.
            ZStack(alignment: .leading) {
                if model.homeTab == .sessions && groups.count > 1 {
                    SessionFilters(groups: groups, total: groups.reduce(0) { $0 + $1.records.count })
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            icon(searching ? "ic_close" : "ic_search", label: searching ? model.text("关闭搜索", "Close search")
                 : model.homeTab == .sessions ? model.text("搜索会话", "Search sessions") : model.text("搜索主机", "Search hosts"),
                 id: "search-hosts", action: toggleSearch)
            if model.homeTab == .sessions {
                icon("ic_add", label: model.text("新建会话", "New session"), id: "add-session") { model.sheet = .newSession }
            } else {
                icon("ic_add", label: model.text("添加主机", "Add host"), id: "add-host") { model.sheet = .editor(nil) }
            }
        }.buttonStyle(.plain).padding(.horizontal, 6).frame(height: Self.height)
    }
    private func icon(_ name: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppIcon(name, size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private func tab(_ title: String, count: Int, _ value: HomeTab, id: String) -> some View {
        let active = model.homeTab == value
        let color = active ? Palette.foreground : Palette.secondary
        return Button { withAnimation(.easeInOut(duration: 0.25)) { model.homeTab = value } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: active ? .semibold : .regular))
                Text("\(count)").font(.system(size: 15, weight: .semibold)).opacity(0.7)
            }.foregroundStyle(color).lineLimit(1).padding(.horizontal, 14).frame(height: 32)
                .background(active ? Palette.foreground.opacity(0.14) : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected, .isHeader] : []).accessibilityIdentifier(id)
    }
}
