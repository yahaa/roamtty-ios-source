import SwiftUI

/// The line above a home list: how many it holds on the left, the + that adds one on the right.
struct HomeListHeader: View {
    let label: String
    let addLabel: String
    let id: String
    let onAdd: () -> Void
    var body: some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .regular)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer()
            Button(action: onAdd) { AppIcon("ic_add", size: 24).foregroundStyle(Palette.foreground).frame(width: 48, height: 48).contentShape(Rectangle()) }
                .accessibilityLabel(addLabel).accessibilityIdentifier(id)
        }.padding(.leading, 18).padding(.trailing, 6).frame(height: 56)
    }
}

struct HomeEmptyState<Action: View>: View {
    var logo = false
    let title: String
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 16) {
            if logo { Image("RoamttyLogo").resizable().scaledToFit().frame(width: 56, height: 56).padding(.bottom, 8).accessibilityIdentifier("empty-logo") }
            Text(title).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            action
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How far a home list has scrolled: its content's top in its scroll view (0 at rest, negative as it scrolls on) and
/// how tall the content is.
struct HomeScrollOffsetKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Where a home list reports how far it has scrolled, held to the range it can rest in (overscroll and its bounce
/// left out): `HomeScreen` slides its landscape bar by it.
struct HomeScrollReportKey: EnvironmentKey {
    static let defaultValue: (HomeTab, CGFloat) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var homeScrolled: (HomeTab, CGFloat) -> Void {
        get { self[HomeScrollReportKey.self] }
        set { self[HomeScrollReportKey.self] = newValue }
    }
}

private struct HomeScrollSpace: ViewModifier {
    @Environment(\.homeScrolled) private var scrolled
    let tab: HomeTab
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                let lowest = min(0, geometry.containerSize.height - geometry.contentSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
                return min(0, max(lowest, -(geometry.contentOffset.y + geometry.contentInsets.top)))
            } action: { _, offset in scrolled(tab, offset) }
        } else {
            // Named outside the scroll view: one named on the scroll view itself moves with its content.
            GeometryReader { viewport in
                content.onPreferenceChange(HomeScrollOffsetKey.self) { frame in
                    let lowest = min(0, viewport.size.height - frame.height)
                    scrolled(tab, min(0, max(lowest, frame.minY)))
                }
            }.coordinateSpace(name: "home-scroll-\(tab)")
        }
    }
}

extension View {
    /// On a scroll view's content: reports where it is to the scroll view `homeScrollSpace` names.
    func reportsHomeScroll(_ tab: HomeTab) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HomeScrollOffsetKey.self, value: proxy.frame(in: .named("home-scroll-\(tab)")))
        })
    }
    /// On a home list's scroll view: passes how far it has scrolled to `homeScrolled`.
    func homeScrollSpace(_ tab: HomeTab) -> some View { modifier(HomeScrollSpace(tab: tab)) }
}
