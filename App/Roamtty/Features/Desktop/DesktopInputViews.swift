import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// A native IME client keeps marked text local until composition commits, just like Android's
/// hidden BasicTextField. Empty-field Delete and Return still emit remote key events.
struct DesktopIMEInput: UIViewRepresentable {
    var focused: Bool
    var onText: (String) -> Void
    var onControl: (Int) -> Void
    var onComposing: (String) -> Void

    func makeUIView(context: Context) -> DesktopIMETextView {
        let view = DesktopIMETextView()
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.keyboardAppearance = .dark
        view.delegate = context.coordinator
        view.onControl = onControl
        return view
    }

    func updateUIView(_ view: DesktopIMETextView, context: Context) {
        context.coordinator.parent = self
        view.onControl = onControl
        if focused && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard context.coordinator.parent.focused else { return }
                view?.becomeFirstResponder()
            }
        } else if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DesktopIMEInput
        init(_ parent: DesktopIMEInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            if textView.markedTextRange != nil {
                parent.onComposing(textView.text ?? "")
                return
            }
            parent.onComposing("")
            guard !textView.text.isEmpty else { return }
            let text = textView.text ?? ""
            textView.text = ""
            parent.onText(text)
        }
    }
}

final class DesktopIMETextView: UITextView {
    var onControl: ((Int) -> Void)?
    override func deleteBackward() {
        if text.isEmpty && markedTextRange == nil { onControl?(HidUsage.BACKSPACE) } else { super.deleteBackward() }
    }
}

/// The floating left / right buttons and scroll strip of the 虚拟鼠标 option.
struct VirtualMousePad: View {
    var click: (Int, Bool) -> Void
    var wheel: (Int, Int) -> Void
    @State private var drag: CGSize = .zero
    var body: some View {
        VStack(spacing: 8) {
            Text("Virtual").font(.caption2).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                mouseButton("L") { click(1, true); click(1, false) }
                mouseButton("R") { click(2, true); click(2, false) }
            }
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15))
                .frame(height: 48)
                .overlay(Text("⇅").foregroundStyle(.white.opacity(0.5)))
                .gesture(DragGesture().onChanged { v in
                    let dy = Int((-v.translation.height + drag.height) / 4)
                    if dy != 0 { wheel(0, dy); drag = .init(width: 0, height: v.translation.height) }
                }.onEnded { _ in drag = .zero })
        }
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
    private func mouseButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(.white).frame(maxWidth: .infinity).padding(10)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}
