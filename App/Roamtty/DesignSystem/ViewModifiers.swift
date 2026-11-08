import SwiftUI

extension View {
    func pageBackground() -> some View { background(Palette.background).foregroundStyle(Palette.foreground) }
    /// The line under a panel row; `shown` false for the last row.
    func panelDivider(_ shown: Bool = true) -> some View { overlay(alignment: .bottom) { if shown { Divider().overlay(Palette.outline).padding(.leading, 16) } } }
}
/// Queue incoming shares until an existing preview, transfer, or command sheet closes.
struct ChildModalPresence: ViewModifier {
    @EnvironmentObject var model: AppModel
    @State private var registered = false
    func body(content: Content) -> some View {
        content.onAppear { if !registered { registered = true; model.childModalCount += 1 } }
            .onDisappear { if registered { registered = false; model.childModalCount = max(0, model.childModalCount - 1) } }
    }
}
