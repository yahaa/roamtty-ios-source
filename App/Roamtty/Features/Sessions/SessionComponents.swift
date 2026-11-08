import SwiftUI
import RoamttyCore

/// Android `AgentStatusLine.kt` / `HomeSessions.kt` building blocks shared by the session list, drawer and sheets.
extension CodingAgent {
    /// The colour of an agent's mark; Grok's is black on white or white on black, so it takes the text colour.
    var brand: Color {
        switch self {
        case .claude: return Color(uiColor: UIColor(hex: 0xD97757))
        case .codex: return Color(uiColor: UIColor(hex: 0x6F86FF))
        case .grok: return Palette.foreground
        }
    }
    var iconName: String { "ic_agent_" + command }
}

extension AgentStatus.State {
    var color: Color {
        switch self {
        case .working: return Palette.accent
        case .waiting: return Palette.warning
        case .idle: return Palette.success
        }
    }
}

extension SessionGroup {
    @MainActor func label(_ model: AppModel, plainOnly: Bool) -> String {
        switch self {
        case .waiting: return model.text("待确认", "Needs you")
        case .working: return model.text("运行中", "Running")
        case .done: return model.text("已完成", "Done")
        case .other: return plainOnly ? model.text("终端", "Terminal") : model.text("其它", "Other")
        }
    }
    var color: Color {
        switch self {
        case .waiting: return Palette.warning
        case .working: return Palette.accent
        case .done: return Palette.success
        case .other: return Palette.secondary
        }
    }
}

/// An agent's mark on a tile in its own colours; with `state`, a dot in the corner shows what it is doing.
struct AgentIcon: View {
    @Environment(\.colorScheme) private var scheme
    let agent: CodingAgent
    var size: CGFloat = 40
    var state: AgentStatus.State?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28).fill(agent.brand.opacity(scheme == .dark ? 0.18 : 0.12))
                AppIcon(agent.iconName, size: size * 0.55).foregroundStyle(agent.brand)
            }.frame(width: size, height: size)
            if let state {
                Circle().fill(state.color).padding(size * 0.05).background(Circle().fill(Palette.surface))
                    .frame(width: size * 0.34, height: size * 0.34).offset(x: size * 0.04, y: size * 0.04)
            }
        }.frame(width: size, height: size).accessibilityLabel(agent.label).accessibilityIdentifier("agent-icon-\(agent.command)")
    }
}

/// A plain terminal's tile, beside the agents' own: a wash of the text colour, so it shows on a card too.
struct TerminalTile: View {
    @Environment(\.colorScheme) private var scheme
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Palette.foreground.opacity(scheme == .dark ? 0.12 : 0.08))
            Text("$_").font(.system(size: size * 0.33, weight: .bold, design: .monospaced)).foregroundStyle(Palette.secondary)
        }.frame(width: size, height: size).accessibilityIdentifier("terminal-icon")
    }
}

/// A session's tile, the one it was created from: the agent's mark while one runs or was launched, else the plain
/// terminal's. `state` puts the agent's status dot in its corner.
struct SessionIcon: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    var size: CGFloat = 40
    var state: AgentStatus.State?
    var body: some View {
        if let agent = model.sessionAgent(record) { AgentIcon(agent: agent, size: size, state: state) } else { TerminalTile(size: size) }
    }
}

/// The agent's name on a small wash of its colour, before the session's name.
struct AgentNameBadge: View {
    let agent: CodingAgent
    var body: some View {
        Text(agent.shortLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(agent.brand).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1).background(agent.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// A dot and `label` in `color`.
struct DotLabel: View {
    let label: String
    let color: Color
    var labelColor: Color?
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(labelColor ?? color).lineLimit(1).fixedSize()
        }
    }
}

/// Connection state as a coloured dot plus text, so colour is never the only signal. While the host is offline
/// (`hostOffline`) a grey hollow dot and "离线", then what the agent was last seen doing (`last`).
struct SessionStatusLabel: View {
    @EnvironmentObject var model: AppModel
    let phase: ConnectionPhase
    var hostOffline = false
    var last: AgentStatus?
    var body: some View {
        if hostOffline {
            HStack(spacing: 6) {
                Circle().strokeBorder(Palette.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                Text(offlineText).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1).fixedSize()
            }
        } else {
            DotLabel(label: model.phaseText(phase), color: phase.tone, labelColor: phase == .connected ? phase.tone : Palette.secondary)
        }
    }
    /// "离线", or "离线 · 上次已完成" with what the agent last reported.
    private var offlineText: String {
        let was: (String, String)?
        switch last?.state {
        case nil: was = nil
        case .waiting: was = ("待确认", "Needs you")
        case .working: was = ("运行中", "Running")
        case .idle: was = last?.workedSeconds != nil ? ("已完成", "Done") : ("空闲", "Idle")
        }
        guard let was else { return model.text("离线", "Offline") }
        return model.text("离线 · 上次\(was.0)", "Offline · last: \(was.1)")
    }
}

/// Claude Code's spinner, for a busy agent: a star that grows and shrinks through its frames beside `label`
/// ("思考中…" between commands) with a highlight sweeping across, both in `color`.
struct WorkingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let label: String
    /// Out and back as Claude Code draws it; it rests on the full star, which is all that shows with reduced motion.
    private static let frames: [String] = {
        let out = ["·", "✢", "✳", "✶", "✻", "✽"]
        let loop = out + out.reversed().dropFirst().dropLast()
        return Array(loop.dropFirst(4) + loop.prefix(4))
    }()
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let frame = reduceMotion ? "✻" : Self.frames[Int(time / 0.12) % Self.frames.count]
            let sweep = reduceMotion ? 0.5 : (time.truncatingRemainder(dividingBy: 2) / 2) * 3 - 1
            HStack(spacing: 4) {
                Text(frame).font(.system(size: 12, design: .monospaced)).foregroundStyle(color).frame(width: 14)
                Text(label).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LinearGradient(stops: [.init(color: color.opacity(0.6), location: sweep - 0.33), .init(color: color, location: sweep),
                                                            .init(color: color.opacity(0.6), location: sweep + 0.33)], startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1).fixedSize()
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// Claude Code's line after a turn: the resting star and how long the turn worked ("✻ 2m54s"), in the done colour.
struct TurnDone: View {
    @EnvironmentObject var model: AppModel
    let seconds: Int64
    var body: some View {
        HStack(spacing: 4) {
            Text("✻").font(.system(size: 12))
            Text(shortDuration(seconds)).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
        }.foregroundStyle(Palette.success).accessibilityElement(children: .ignore)
            .accessibilityLabel(model.text("已完成 · 用时 \(durationText(seconds, english: false))", "Worked for \(durationText(seconds, english: true))"))
    }
}

/// A card title on one line that, when too long for it, keeps scrolling like a subtitle (rests 1.2 s, then 30 pt/s
/// with a third of the line between copies) and fades out at the right edge; a title that fits stays still.
struct MarqueeTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var font: Font = .system(size: 16, weight: .semibold)
    @State private var full: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            let line = geometry.size.width
            let overflow = full > line + 0.5
            ZStack(alignment: .leading) {
                if overflow && !reduceMotion {
                    // 60 frames a second is smooth for 30 pt/s; ProMotion's 120 only doubled the work of every card.
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                        let gap = line / 3, period = (full + gap) / 30
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period + 1.2)
                        let offset = phase < 1.2 ? 0 : -CGFloat(phase - 1.2) * 30
                        HStack(spacing: gap) { label; label }.offset(x: offset)
                    }
                } else { label }
            }.frame(width: line, alignment: .leading).clipped()
                .mask(overflow ? AnyView(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: max(0, 1 - 18 / max(line, 1))), .init(color: .clear, location: 1)],
                    startPoint: .leading, endPoint: .trailing)) : AnyView(Color.black))
        }.frame(height: 22)
            .background(label.hidden().background(GeometryReader { Color.clear.preference(key: TitleWidth.self, value: $0.size.width) }).fixedSize())
            .onPreferenceChange(TitleWidth.self) { full = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
    private var label: some View { Text(text).font(font).lineLimit(1).fixedSize() }
    private struct TitleWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// A small pill button on a row's status line: filled with `fill`, text only when `plain`, else on a neutral wash.
struct RowAction: View {
    let label: String
    var icon: String?
    var fill: Color?
    var plain = false
    /// Uses the same compact icon tag as host-card actions; the label stays for VoiceOver.
    var iconOnly = false
    let action: () -> Void
    var body: some View {
        let content: Color = fill != nil ? Color(uiColor: UIColor(hex: 0x1D1A12)) : plain ? Palette.secondary : Palette.foreground
        let background = fill ?? (plain ? Color.clear : Palette.foreground.opacity(0.07))
        Button(action: action) {
            if let icon, iconOnly {
                CardActionIcon(icon: icon)
                    .frame(width: 40, height: 36, alignment: .trailing)
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 4) {
                    if let icon { AppIcon(icon, size: 13) }
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                }.foregroundStyle(content).padding(.horizontal, plain ? 6 : 10).frame(height: 28)
                    .background(background, in: Capsule()).contentShape(Capsule())
            }
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// The tags a session or host card shows beside its status.
struct MetaTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
