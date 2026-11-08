import SwiftUI

struct ReachabilityLabel: View {
    @EnvironmentObject var model: AppModel
    let state: HostReachability
    var onImage = false
    var fontSize: CGFloat = 12
    private var tone: Color {
        switch state {
        case .checking: return onImage ? .white.opacity(0.5) : Palette.secondary
        case .online: return onImage ? Color(uiColor: UIColor(hex: 0x7FD19B)) : Palette.success
        case .offline: return onImage ? Color(uiColor: UIColor(hex: 0xF2A39B)) : Palette.danger
        }
    }
    private var label: String {
        switch state {
        case .checking: return model.text("检测中", "Checking")
        case .offline: return model.text("离线", "Offline")
        case .online(let ms): return model.text("在线", "Online") + " · " + (ms < 1 ? "<1" : String(format: "%.0f", ms)) + " ms"
        }
    }
    var body: some View {
        // Android colours only the online label; offline and checking text stays secondary beside its dot.
        let online = state.isOnline
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(label).font(.system(size: fontSize, weight: .medium)).foregroundStyle(online ? tone : onImage ? .white.opacity(0.72) : Palette.secondary)
        }
    }
}
