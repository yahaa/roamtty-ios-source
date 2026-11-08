import SwiftUI

/// Android `FormField`: a borderless grouped-form field; the label floats above once there is a value.
struct FormField: View {
    let label: String
    var placeholder: String?
    @Binding var text: String
    let id: String
    var secure = false
    @FocusState private var focused: Bool
    var body: some View {
        let floating = focused || !text.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            if floating { Text(label).font(.caption).foregroundStyle(focused ? Palette.accent : Palette.secondary).lineLimit(1) }
            Group {
                if secure { SecureField(floating ? (placeholder ?? "") : label, text: $text) } else { TextField(floating ? (placeholder ?? "") : label, text: $text) }
            }.font(.body).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                .accessibilityIdentifier(id)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture { focused = true }
            .animation(.easeOut(duration: 0.15), value: floating)
    }
}
