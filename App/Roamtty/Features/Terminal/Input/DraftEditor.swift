import SwiftUI
import UIKit

/// The terminal's prompt editor (Android `TerminalPane` editor mode): text is staged here and sent as one paste.
/// Cursor keys and delete act on the native text view, so they follow grapheme boundaries like Android's.
@MainActor final class DraftController: ObservableObject {
    static let limit = 128 * 1024
    @Published var text = ""
    fileprivate weak var view: UITextView?

    func moveCursor(left: Bool) {
        guard let view else { return }
        let range = view.selectedRange
        let nsText = view.text as NSString
        let position: Int
        if range.length > 0 {
            position = left ? range.location : range.location + range.length
        } else if left {
            position = range.location == 0 ? 0 : nsText.rangeOfComposedCharacterSequence(at: range.location - 1).location
        } else {
            position = range.location >= nsText.length ? nsText.length : NSMaxRange(nsText.rangeOfComposedCharacterSequence(at: range.location))
        }
        view.selectedRange = NSRange(location: position, length: 0)
    }
    func deleteBackward() {
        guard let view else { return }
        let range = view.selectedRange
        let nsText = view.text as NSString
        let target = range.length > 0 ? range : range.location == 0 ? nil : nsText.rangeOfComposedCharacterSequence(at: range.location - 1)
        guard let target else { return }
        view.text = nsText.replacingCharacters(in: target, with: "")
        view.selectedRange = NSRange(location: target.location, length: 0)
        text = view.text
    }
    func clear() { view?.text = ""; text = "" }
    /// Inserts at the cursor (or replaces the selection), clipped to the 128 KiB draft limit.
    func insert(_ inserted: String) {
        guard !inserted.isEmpty else { return }
        let current = view?.text ?? text
        let nsText = current as NSString
        let range = view?.selectedRange ?? NSRange(location: nsText.length, length: 0)
        let available = max(0, Self.limit - nsText.length + range.length)
        var clipped = String(inserted.utf16.prefix(available)) ?? ""
        if clipped.isEmpty, available > 0 { clipped = String(inserted.prefix(available)) }
        guard !clipped.isEmpty else { return }
        let next = nsText.replacingCharacters(in: range, with: clipped)
        text = next
        view?.text = next
        view?.selectedRange = NSRange(location: range.location + (clipped as NSString).length, length: 0)
    }
}

struct DraftEditor: UIViewRepresentable {
    @ObservedObject var controller: DraftController
    let placeholder: String
    var maxLines: Int
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textColor = UIColor(Palette.foreground)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.textContainer.lineFragmentPadding = 4
        // Always scrollable: toggling this while sizing re-enters layout and keeps the app from going idle.
        view.isScrollEnabled = true
        view.accessibilityIdentifier = "prompt-editor"
        view.text = controller.text
        let label = UILabel()
        label.text = placeholder
        label.font = view.font
        label.textColor = UIColor(Palette.secondary)
        label.tag = 7
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                                     label.topAnchor.constraint(equalTo: view.topAnchor, constant: 14)])
        controller.view = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.view = view
        if view.text != controller.text, view.markedTextRange == nil { view.text = controller.text }
        view.viewWithTag(7)?.isHidden = !view.text.isEmpty
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let line = uiView.font?.lineHeight ?? 20
        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitted, line + inset), line * CGFloat(maxLines) + inset)
        return CGSize(width: width, height: ceil(height))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DraftEditor
        init(_ parent: DraftEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            if (textView.text as NSString).length > DraftController.limit { textView.text = String(textView.text.utf16.prefix(DraftController.limit)) ?? textView.text }
            textView.viewWithTag(7)?.isHidden = !textView.text.isEmpty
            parent.controller.text = textView.text
        }
    }
}

/// Android's `InputControlButton`: a round, borderless symbol key.
struct InputControlButton: View {
    let symbol: String
    let label: String
    let id: String
    var size: CGFloat = 40
    var enabled = true
    var onLongPress: (() -> Void)?
    let action: () -> Void
    var body: some View {
        Text(symbol).font(.system(size: symbol.count > 1 ? 14 : 22)).foregroundStyle(Palette.foreground.opacity(enabled ? 1 : 0.38))
            .frame(width: size, height: size).contentShape(Circle())
            .onTapGesture { if enabled { action() } }
            .onLongPressGesture(minimumDuration: 0.5) { if enabled { onLongPress?() } }
            .accessibilityElement().accessibilityLabel(label).accessibilityIdentifier(id).accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
}

struct DraftInputControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DraftController
    var body: some View {
        HStack(spacing: 0) {
            InputControlButton(symbol: "←", label: model.text("光标左移", "Move cursor left"), id: "draft-left") { controller.moveCursor(left: true) }
            InputControlButton(symbol: "→", label: model.text("光标右移", "Move cursor right"), id: "draft-right") { controller.moveCursor(left: false) }
            InputControlButton(symbol: "⌫", label: model.text("删除字符，长按清空当前输入", "Delete; hold to clear"), id: "draft-delete",
                               onLongPress: { controller.clear() }) { controller.deleteBackward() }
        }
    }
}
