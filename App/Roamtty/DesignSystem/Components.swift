import SwiftUI
import UIKit
import RoamttyCore

/// Android's vector drawables, imported verbatim by scripts/import-android-icons.py.
struct AppIcon: View {
    let name: String
    var size: CGFloat = 22
    init(_ name: String, size: CGFloat = 22) { self.name = name; self.size = size }
    var body: some View { Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size) }
}
struct Panel<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 16) }
            VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            if let footer { Text(footer).font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 16) }
        }
    }
}
/// Every page's bar in landscape, where height is short: flat and 48pt, the control that leaves at the leading edge,
/// the title beside it (with a short detail after it when there is one), and the page's actions at the end. Pages and
/// sheets alike use it, so the bar looks and sits the same wherever the phone is turned.
struct LandscapeBar<Leading: View, Trailing: View>: View {
    static var height: CGFloat { 48 }
    let title: String
    var detail: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            leading
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1) }
            }.padding(.leading, 4).layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }.padding(.horizontal, 6).frame(height: Self.height)
    }
}
/// A 44-point icon button of a landscape bar: close, back, refresh, more.
struct BarIconButton: View {
    let icon: String
    let label: String
    var id: String?
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) { AppIcon(icon, size: 24).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(enabled ? Palette.foreground : Palette.foreground.opacity(0.38)).disabled(!enabled)
            .accessibilityLabel(label).accessibilityIdentifier(id ?? label)
    }
}
/// Landscape content as two columns of sections, read down the left then down the right; each column as wide as the
/// other and aligned at the top.
struct LandscapeColumns<Left: View, Right: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: spacing) { left }.frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: spacing) { right }.frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
struct InfoRow: View {
    let title: String
    var value: String?
    var icon: String?
    var subtitle: String?
    var body: some View {
        HStack(spacing: 12) {
            if let icon { Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 24) }
            if let subtitle { VStack(alignment: .leading, spacing: 2) { Text(title); Text(subtitle).font(.footnote).foregroundStyle(Palette.secondary) } } else { Text(title) }
            Spacer(minLength: 12)
            if let value { Text(value).foregroundStyle(Palette.secondary).multilineTextAlignment(.trailing).textSelection(.enabled) }
        }.font(.subheadline).padding(16).frame(minHeight: 52)
    }
}
/// Shared visual treatment for compact actions beside host and session tags.
struct CardActionIcon: View {
    let icon: String
    var tint: Color = Palette.secondary
    var wash: Color = Palette.foreground.opacity(0.06)

    var body: some View {
        AppIcon(icon, size: 13)
            .foregroundStyle(tint)
            .frame(width: 28, height: 20)
            .background(wash, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Palette.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
struct EmptyMessage: View {
    var icon = "terminal"
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent).padding(.bottom, 8)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity)
    }
}
extension ConnectionPhase {
    /// A connection's colour: up, closed, on its way, or failed.
    var tone: Color { self == .connected ? Palette.success : self == .disconnected ? Palette.secondary : active ? Palette.warning : Palette.danger }
}
struct PhaseLabel: View {
    @EnvironmentObject var model: AppModel
    let phase: ConnectionPhase
    var body: some View {
        HStack(spacing: 6) { Circle().fill(phase.tone).frame(width: 8, height: 8); Text(model.phaseText(phase)).font(.caption) }.foregroundStyle(phase.tone)
    }
}
