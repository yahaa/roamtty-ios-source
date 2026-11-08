import SwiftUI
import RoamttyCore

/// The page each `AppRoute` pushes.
struct AppRouteDestination: View {
    @EnvironmentObject var model: AppModel
    let route: AppRoute
    var body: some View {
        switch route {
        case .host(let id):
            if let host = model.host(id) { HostDetailScreen(hostID: host.id) }
        case .terminal(let id):
            if let runtime = model.runtimes[id] {
                // Reconnect retains the journal ID but owns a new renderer.
                // Recreate UIKit and sheet state with that runtime instance.
                TerminalScreen(runtime: runtime).id(ObjectIdentifier(runtime))
            } else if let record = model.records.first(where: { $0.id == id }) {
                // A session restored from the journal reconnects as soon as it is shown.
                Color.clear.onAppear { model.openRestored(record) }
            } else { EmptyMessage(title: model.text("会话已关闭", "Session closed"), message: model.text("返回会话列表重新连接。", "Return to the session list to connect again.")) }
        case .files(let id, let sessionID, let directory):
            if let host = model.host(id) {
                let target = model.connectionTarget(hostID: id, sessionID: sessionID)
                FileBrowserScreen(host: target.runtime?.host ?? host, sessionID: sessionID, initialDirectory: directory, connectionTarget: target)
            }
        case .desktop(let id):
            if let controller = model.desktops[id] {
                DesktopPage(controller: controller).id(ObjectIdentifier(controller))
            } else {
                EmptyMessage(title: model.text("桌面已关闭", "Desktop closed"), message: model.text("返回后可再次打开。", "You can open it again from the list."))
            }
        }
    }
}
