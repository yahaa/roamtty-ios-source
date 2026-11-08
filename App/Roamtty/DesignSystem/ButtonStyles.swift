import SwiftUI

struct RoamButtonStyle: ButtonStyle {
    var primary = false
    /// Android's filled primary action: accent container, dark label.
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 44)
            .foregroundStyle(filled ? Palette.onAccent : primary ? Palette.accent : Palette.foreground)
            .background(filled ? Palette.accent : primary ? Palette.accentPanel : Palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Android's filled Material button: accent capsule, dimmed when disabled.
struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 40)
            .foregroundStyle(enabled ? Palette.onAccent : Palette.foreground.opacity(0.38))
            .background(enabled ? Palette.accent : Palette.foreground.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Android's text button: accent label, no container.
struct TextActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).padding(.horizontal, 8).frame(minHeight: 40)
            .foregroundStyle(enabled ? Palette.accent : Palette.foreground.opacity(0.38))
            .opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}

struct AccentCapsuleButton: View {
    let title: String
    var id: String?
    let action: () -> Void
    var body: some View {
        Button(title, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 24).frame(height: 44).background(Palette.accent, in: Capsule()).padding(.top, 8)
            .accessibilityIdentifier(id ?? title)
    }
}
