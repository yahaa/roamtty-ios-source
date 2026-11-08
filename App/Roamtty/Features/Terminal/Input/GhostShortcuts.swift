import SwiftUI
import UIKit
import RoamttyCore

struct GhostMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View { ToolboxPetArt(animated: !reduceMotion) }
}
struct GhostShortcuts: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject var runtime: SessionRuntime
    @Binding var toolbox: TerminalToolboxState
    let center: CGPoint
    let viewport: CGSize
    let onTap: () -> Void
    @State private var hovered: Int?
    @State private var app = ScreenApp.shell
    @State private var submenu: [TerminalShortcut]?
    @State private var heldCenter: CGPoint?
    @State private var pressed = false
    /// The ring (and each sub-ring) springs out from the pet, as Android's does.
    @State private var openScale: CGFloat = 0
    private var shortcuts: [TerminalShortcut] { submenu ?? app.shortcuts }
    private var anchor: CGPoint { heldCenter ?? center }
    private var arc: TerminalShortcutArc {
        .layout(count: shortcuts.count, centerY: anchor.y, top: 24, bottom: max(24, viewport.height - 24),
                maxRadius: max(100, 43 * Double(max(0, shortcuts.count - 1)) / (160 * .pi / 180)), minRadius: 72, spacing: 43)
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if toolbox.ringOpen {
                if toolbox.ringPinned { Color.clear.contentShape(Rectangle()).onTapGesture { toolbox.dismissRing() } }
                Path { path in
                    if let first = arc.angles.first, let last = arc.angles.last {
                        path.addArc(center: anchor, radius: arc.radius, startAngle: .degrees(last), endAngle: .degrees(first), clockwise: false)
                    }
                }.stroke(Palette.accent.opacity(0.12 * openScale), lineWidth: 14).allowsHitTesting(false)
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, item in
                    let offset = arc.itemOffset(at: index)
                    Button { pick(item, byTap: true) } label: {
                        VStack(spacing: 1) {
                            Text(item.label).font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                                .foregroundStyle(hovered == index ? Palette.onAccent : Palette.accent)
                            let hint = item.hint(english: model.english)
                            if !hint.isEmpty { Text(hint).font(.system(size: 9)).lineLimit(1).foregroundStyle(hovered == index ? Palette.onAccent : Palette.secondary) }
                        }.frame(width: 40, height: 40)
                            .background(hovered == index ? Palette.accent.opacity(0.9) : armed(item.action) ? Palette.accentPanel.opacity(0.8) : Palette.surfaceVariant.opacity(0.7), in: Circle())
                            .overlay { Circle().stroke(hovered == index ? Palette.accent : Palette.outline.opacity(0.4), lineWidth: 1) }
                            .shadow(color: .black.opacity(hovered == index ? 0.3 : 0), radius: 4)
                            .scaleEffect((hovered == index ? 1.2 : 1) * openScale)
                            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hovered)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).position(x: anchor.x + offset.x * openScale, y: anchor.y + offset.y * openScale)
                        .allowsHitTesting(toolbox.ringPinned).accessibilityLabel(item.description(english: model.english)).accessibilityIdentifier(item.tag)
                }
                if let hovered, shortcuts.indices.contains(hovered) {
                    let right = anchor.x - arc.radius - 28, width = max(0, min(132, right - 8))
                    if width > 20 {
                        Text(shortcuts[hovered].description(english: model.english)).font(.system(size: 11)).lineLimit(5).foregroundStyle(Palette.inverseForeground)
                            .padding(.horizontal, 8).padding(.vertical, 5).background(Palette.inverseSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            .frame(width: width, alignment: .trailing).position(x: right - width / 2, y: anchor.y).allowsHitTesting(false)
                    }
                }
            }
            ToolboxPetArt(animated: !reduceMotion && !toolbox.ringOpen).frame(width: 44, height: 44)
                .scaleEffect(pressed ? 0.86 : 1).animation(.spring(response: 0.18, dampingFraction: 0.4), value: pressed)
                .allowsHitTesting(false).position(anchor)
            GhostControl(label: model.text("终端工具箱；长按显示快捷键", "Terminal tools; hold for shortcuts"),
                         onTouch: { toolbox.wake(at: now) },
                         onPress: { pressed = $0 },
                         onTap: { if toolbox.ringOpen { toolbox.dismissRing() } else { onTap() } },
                         onHoldStart: beginHold, onHoldMove: moveHold, onHoldEnd: endHold)
                .frame(width: 48, height: 48).position(anchor)
        }.frame(width: viewport.width, height: viewport.height)
            .onChange(of: toolbox.ringOpen) { open in if !open { submenu = nil; hovered = nil; heldCenter = nil; openScale = 0 } else { unfold() } }
            .onChange(of: submenu?.count) { _ in if toolbox.ringOpen { unfold() } }
            .task(id: hovered) {
                guard let index = hovered, shortcuts.indices.contains(index), case .menu(let items) = shortcuts[index].action else { return }
                do { try await Task.sleep(for: .milliseconds(350)); submenu = items; hovered = nil; UIImpactFeedbackGenerator(style: .light).impactOccurred() } catch { }
            }
    }
    private func unfold() {
        openScale = 0
        if reduceMotion { openScale = 1 } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { openScale = 1 } }
    }
    private func beginHold() {
        guard !toolbox.ringOpen else { return }
        app = runtime.screenApp(); submenu = nil; hovered = nil; heldCenter = center
        toolbox.beginRing(at: now); UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func moveHold(_ drag: CGSize) {
        guard toolbox.ringOpen else { return }
        if submenu != nil && hypot(drag.width, drag.height) < arc.radius * 0.25 { submenu = nil; hovered = nil }
        let next = arc.hoveredItem(x: drag.width, y: drag.height)
        if next != hovered { hovered = next; if next != nil { UISelectionFeedbackGenerator().selectionChanged() } }
    }
    private func endHold(_ released: Bool) {
        guard toolbox.ringOpen else { return }
        if !released { toolbox.completeRing(at: now) } else if let hovered, shortcuts.indices.contains(hovered) { pick(shortcuts[hovered], byTap: false) } else { toolbox.pinRing(at: now) }
        hovered = nil
    }
    private func pick(_ item: TerminalShortcut, byTap: Bool) {
        if case .menu(let items) = item.action { submenu = items; hovered = nil; toolbox.pinRing(at: now); return }
        if byTap { toolbox.dismissRing() } else { toolbox.completeRing(at: now) }
        activate(item.action)
    }
    private func armed(_ action: TerminalShortcutAction) -> Bool {
        action == .ctrl && runtime.controlArmed || action == .shift && runtime.shiftArmed
    }
    private func activate(_ action: TerminalShortcutAction) {
        switch action {
        case .menu: break
        case .ctrl:
            runtime.shiftArmed = false; runtime.armControl()
            if runtime.controlArmed { _ = runtime.terminalView.becomeFirstResponder() }
        case .shift:
            if runtime.controlArmed { runtime.armControl() }
            runtime.shiftArmed.toggle()
        case .keys(let keys, let repeatAfter):
            runtime.clearModifiers(); runtime.terminalView.scrollToLiveOutput()
            if runtime.send(keys), let repeatAfter { DispatchQueue.main.asyncAfter(deadline: .now() + repeatAfter) { runtime.send(keys) } }
        case .functionKey(let number):
            guard let input = TerminalKeys.function(number, control: runtime.controlArmed, shift: runtime.shiftArmed) else { return }
            runtime.clearModifiers(); runtime.terminalView.scrollToLiveOutput(); runtime.send(input)
        }
    }
}

/// A native control keeps a real 48-point hit target and accessibility activation.
/// It is transparent: the animated pet is drawn under it, so the gesture surface stays still.
private struct GhostControl: UIViewRepresentable {
    let label: String
    let onTouch: () -> Void
    let onPress: (Bool) -> Void
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldMove: (CGSize) -> Void
    let onHoldEnd: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = GhostButton(type: .custom)
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "terminal-ghost"
        button.accessibilityTraits = [.button]
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 48, height: 48)
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.accessibilityLabel = label
    }
    @MainActor final class Coordinator: NSObject {
        var parent: GhostControl
        private var holding = false
        init(_ parent: GhostControl) { self.parent = parent }
        @objc func touchDown() { parent.onTouch(); parent.onPress(true) }
        @objc func touchEnd() { parent.onPress(false) }
        @objc func tap() { guard !holding else { return }; parent.onTap() }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                holding = true; parent.onPress(false); parent.onHoldStart()
            case .changed:
                guard holding, let view = recognizer.view else { return }
                let point = recognizer.location(in: view)
                parent.onHoldMove(CGSize(width: point.x - view.bounds.midX, height: point.y - view.bounds.midY))
            case .ended:
                guard holding else { return }; holding = false; parent.onHoldEnd(true)
            case .cancelled, .failed:
                guard holding else { return }; holding = false; parent.onHoldEnd(false)
            default: break
            }
        }
    }
}

/// Keeps the button at the pet's 48-point size whatever its SwiftUI wrapper proposes.
private final class GhostButton: UIButton {
    override var intrinsicContentSize: CGSize { CGSize(width: 48, height: 48) }
}
