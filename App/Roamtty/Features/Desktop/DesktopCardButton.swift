import SwiftUI
import RoamttyDesktopCore

/// Android `DesktopCardButton` / `IconTag`: a MetaTag-sized desktop icon at the end of a session or
/// host status row (plan §4.3). Never a spinner — lit wash while open or connecting; a corner badge
/// for connected / poor / needs / recovering.
struct DesktopCardButton: View {
    let state: DesktopButton
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        if case .hidden = state {
            EmptyView()
        } else {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    CardActionIcon(icon: "ic_desktop", tint: tint, wash: wash)
                    if let badge {
                        Circle().fill(badge)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Palette.panel, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                            .accessibilityIdentifier("\(accessibilityID)-badge-\(badgeName)")
                    }
                }
                .frame(width: 40, height: 36, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID)
        }
    }

    private var live: Bool {
        switch state {
        case .connected, .poor, .recovering, .connecting: return true
        default: return false
        }
    }

    private var tint: Color { live ? Palette.accent : Palette.secondary }

    private var wash: Color {
        live ? Palette.accent.opacity(0.16) : Palette.foreground.opacity(0.06)
    }

    private var badge: Color? {
        switch state {
        case .connected: return Palette.success
        case .poor, .needsAction, .recovering: return Palette.warning
        default: return nil
        }
    }

    /// Android `$tag-badge-${state.name.lowercase()}`.
    private var badgeName: String {
        switch state {
        case .hidden: return "hidden"
        case .openable: return "openable"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .poor: return "poor"
        case .needsAction: return "needs_action"
        case .recovering: return "recovering"
        }
    }
}
