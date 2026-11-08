import SwiftUI

/// Android `AppSearchField`: a filled, rounded field with a leading search glyph. `compact` is the landscape bar's
/// field: a 34-point capsule like the file browser's there.
struct AppSearchField: View {
    @Binding var text: String
    let placeholder: String
    var id = "search"
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            AppIcon("ic_search", size: compact ? 16 : 22).foregroundStyle(Palette.secondary)
            TextField(placeholder, text: $text).font(compact ? .subheadline : .body).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(id)
            if !text.isEmpty {
                Button { text = "" } label: { AppIcon("ic_clear", size: compact ? 16 : 18).foregroundStyle(Palette.secondary).frame(width: compact ? 28 : nil, height: compact ? 34 : nil) }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
            }
        }.padding(.leading, compact ? 12 : 16).padding(.trailing, compact ? (text.isEmpty ? 12 : 4) : 16).frame(height: compact ? 34 : 56)
            .background(compact ? Palette.foreground.opacity(0.08) : Palette.raised, in: RoundedRectangle(cornerRadius: compact ? 17 : 12))
    }
}
