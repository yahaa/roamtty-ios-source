import SwiftUI
import UIKit
import RoamttyCore

@main struct RoamttyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var splash = true
    init() {
        // iOS reclaims a suspended app's sockets, and the first write after resuming can raise SIGPIPE even with
        // SO_NOSIGPIPE set; its default action kills the app with no crash report. Ignored, the write fails with EPIPE.
        signal(SIGPIPE, SIG_IGN)
        Diagnostics.shared.start()
        // Before launching finishes, so the tap on a notification that launched the app opens its session.
        AgentNotifier.shared.install()
    }
    var body: some Scene {
        WindowGroup {
            RootScreen().environmentObject(model).preferredColorScheme(model.colorScheme).tint(Palette.accent)
                .task {
                    #if DEBUG
                    await DeviceValidation.runIfRequested(model: model)
                    await MemoryValidation.runIfRequested()
                    await DesktopMemoryValidation.runIfRequested()
                    await AppLifecycleValidation.runIfRequested(model: model)
                    #endif
                }
                .onChange(of: scenePhase) { phase in if phase == .active { model.resume() } else if phase == .background { model.suspend() } }
                .overlay { if splash { StartupSplash { withAnimation(.easeOut(duration: 0.3)) { splash = false } }.transition(.opacity) } }
                .onOpenURL { url in
                    if url.isFileURL {
                        model.importIncoming(url)
                    } else if url.scheme == "roamtty" { model.resume() }
                }
        }
    }
}
