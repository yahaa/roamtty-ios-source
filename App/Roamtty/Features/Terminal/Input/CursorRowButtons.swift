import SwiftUI

/// The cursor row's place on screen and the key beside it, published apart from the rest of the session.
@MainActor final class TerminalCursorRow: ObservableObject {
    @Published var bounds: CGRect?
    @Published var key: CursorRowKey = .escape
    @Published var slashCommandLine = false
}

/// Redraws `content` when the cursor row changes, so the page around it does not have to.
struct CursorRowReader<Content: View>: View {
    @ObservedObject var cursor: TerminalCursorRow
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

struct CursorRowButtons: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @ObservedObject private var cursor: TerminalCursorRow
    /// Android aligns the keys to the viewport's end, past the terminal's own end padding.
    var trailingInset: CGFloat = 0
    /// Keep the key's touch target above the system home gesture area.
    var bottomInset: CGFloat = 0
    /// Where the pet's arrow keys sit, in this view's coordinates: a cursor row within their span slides left of them.
    var avoid: CGRect?
    /// iPhone keyboards have no dismiss key: while one is up, a key beside Esc/Enter puts it away.
    var keyboardVisible = false
    init(runtime: SessionRuntime, trailingInset: CGFloat = 0, bottomInset: CGFloat = 0, avoid: CGRect? = nil, keyboardVisible: Bool = false) {
        self.runtime = runtime; cursor = runtime.cursorRow
        self.trailingInset = trailingInset; self.bottomInset = bottomInset; self.avoid = avoid; self.keyboardVisible = keyboardVisible
    }
    var body: some View {
        GeometryReader { geometry in
            if runtime.phase == .connected, let row = runtime.cursorRowBounds {
                let height: CGFloat = 32
                let y = min(max(row.midY, height / 2), max(height / 2, geometry.size.height - bottomInset - height / 2))
                let keys: CGFloat = keyboardVisible ? 2 : 1
                let shift: CGFloat = avoid.map { y - height / 2 < $0.maxY && y + height / 2 > $0.minY ? $0.width + 8 + 40 : 0 } ?? 0
                HStack(spacing: 0) {
                    if keyboardVisible {
                        CursorKeyButton(systemIcon: "keyboard.chevron.compact.down", label: model.text("收起键盘", "Hide keyboard"), id: "cursor-hide-keyboard") { runtime.hideKeyboard() }
                    }
                    switch runtime.cursorRowKey {
                    case .enter:
                        CursorKeyButton(systemIcon: "return", label: model.text("回车", "Enter"), id: "cursor-enter") { runtime.sendCursorKey(.enter) }
                    case .escape:
                        CursorKeyButton(text: "Esc", label: model.text("发送 Esc", "Send Esc"), id: "cursor-escape") { runtime.sendCursorKey(.escape) }
                    }
                }.frame(width: keys * 40, height: height)
                    .position(x: max(keys * 20, geometry.size.width + trailingInset - keys * 20 - shift), y: y)
                    .animation(.easeInOut(duration: 0.12), value: runtime.cursorRowKey)
                    .animation(.easeInOut(duration: 0.12), value: shift)
            }
        }
    }
}

/// A slim key drawn inside a larger touch area: an Android drawable, an SF Symbol, or a short text label.
struct CursorKeyButton: View {
    var icon: String?
    var systemIcon: String?
    var text: String?
    let label: String
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    AppIcon(icon, size: 16)
                } else if let systemIcon {
                    Image(systemName: systemIcon).font(.system(size: 13, weight: .medium))
                } else {
                    Text(text ?? "").font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }.foregroundStyle(Palette.accent).frame(width: 28, height: 20)
                .background(Palette.raised.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.outline.opacity(0.35), lineWidth: 1) }
                .frame(width: 40, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}
