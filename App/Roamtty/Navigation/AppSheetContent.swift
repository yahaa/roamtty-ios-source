import SwiftUI
import RoamttyCore

/// The page each `AppSheet` presents, with the login questions its work may ask on top.
struct AppSheetContent: View {
    @EnvironmentObject var model: AppModel
    let sheet: AppSheet
    var body: some View {
        ZStack {
            switch sheet {
            case .editor(let host): HostEditorScreen(original: host)
            case .newHost(let agent): HostEditorScreen(original: nil, forSession: .some(agent))
            case .newSession: NewSessionSheet()
            case .continueSession(let host): ContinueSessionScreen(host: host)
            case .settings: SettingsScreen()
            case .launch(let host, let agent, let directory, let picked, let newSession):
                LaunchScreen(host: host, forAgent: agent, initialDirectory: directory, initialAgent: picked,
                             title: newSession ? (agent ? model.text("选择工作目录", "Choose a working folder") : model.text("新建会话", "New session")) : nil)
            case .plugins(let host): PluginsScreen(host: host)
            case .guide: HelpScreen()
            case .about: AboutScreen()
            }
            AuthenticationOverlay()
        }
    }
}
