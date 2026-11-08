import SwiftUI
import UIKit
import RoamttyCore

/// The navigation stack under the drawer, the sheets, the share-upload picker, alerts and notices.
/// What each route and sheet shows is `AppRouteDestination` and `AppSheetContent`.
struct RootScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedShareUpload: UUID?
    /// How far a horizontal swipe has pulled the open drawer back towards the left edge.
    @State private var drawerDrag: CGFloat = 0
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack(path: $model.path) {
                HomeScreen()
                    .navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
            }
            if model.drawer {
                let width = min(360, UIScreen.main.bounds.width * 0.82)
                Color.black.opacity(0.35 * (1 + drawerDrag / width)).ignoresSafeArea().onTapGesture { withAnimation { model.drawer = false } }
                    .gesture(drawerSwipe(width: width))
                DrawerScreen().frame(width: width).offset(x: drawerDrag).transition(.move(edge: .leading))
                    .simultaneousGesture(drawerSwipe(width: width))
            }
            AuthenticationOverlay()
        }
        .onChange(of: model.drawer) { open in if open { drawerDrag = 0 } }
        .sheet(item: $model.sheet) { sheet in
            AppSheetContent(sheet: sheet).environmentObject(model).preferredColorScheme(model.colorScheme).tint(Palette.accent)
        }
        .sheet(
            isPresented: Binding(get: { !model.incomingFiles.isEmpty && model.sheet == nil && model.childModalCount == 0 && model.authentication == nil },
                                 set: { if !$0 { model.incomingFiles = [] } }),
            onDismiss: completeShareHandoff) {
            ShareUploadHostPicker { host in
                selectedShareUpload = model.files.prepareSharedUpload(model.incomingFiles, hostID: host.id)
                model.incomingFiles = []
            }.environmentObject(model).preferredColorScheme(model.colorScheme)
        }
        .alert(model.text("无法完成操作", "Unable to complete"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(model.text("好", "OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment: .top) { if let notice = model.notice { NoticeBanner(notice: notice) } }
    }
    /// The drawer follows a leftward swipe and closes once it has moved a third of its width or is flung.
    private func drawerSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) || drawerDrag != 0 else { return }
                drawerDrag = min(0, value.translation.width)
            }
            .onEnded { value in
                let close = drawerDrag != 0 && (drawerDrag < -width / 3 || value.predictedEndTranslation.width < -width / 2)
                // A closed drawer keeps its offset until it opens again, so it slides out from where the finger left it.
                withAnimation(.easeOut(duration: 0.2)) { if close { model.drawer = false } else { drawerDrag = 0 } }
            }
    }
    private func completeShareHandoff() {
        guard let requestID = selectedShareUpload else { return }
        selectedShareUpload = nil
        guard let hostID = model.files.releaseSharedUpload(requestID) else { return }
        guard model.host(hostID) != nil else {
            let urls = model.files.finishSharedUpload(requestID)
            model.incomingFiles.append(contentsOf: urls.filter { !model.incomingFiles.contains($0) })
            return
        }
        model.path = [.host(hostID), .files(hostID)]
    }
}
