import Foundation

/// The program currently using the terminal's input area. Titles and old banners
/// are intentionally excluded because they can outlive the program that set them.
public enum ScreenApp: String, CaseIterable, Sendable {
    case claude, codex, grok, gemini, shell

    public init(_ agent: CodingAgent) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok: self = .grok
        }
    }

    private static let geminiModel = NSRegularExpression(literal: #"\bgemini-\d"#, options: .caseInsensitive)
    private static let codexContext = NSRegularExpression(literal: #"\b[Cc]ontext \d+% left|\d+% context left"#)
    private static let rule = NSRegularExpression(literal: #"^\s*─{20,}\s*$"#)
    private static let claudeFooters = ["shift+tab to cycle", "⏵⏵", "⏸ plan mode", "? for shortcuts", "esc to interrupt"]

    /// `cursorRow` is an index into the supplied visible screen rows, not scrollback.
    /// Matches Android ScreenApp: three rows above through eight below the cursor.
    public static func detect(rows: [String], cursorRow: Int) -> ScreenApp {
        guard !rows.isEmpty else { return .shell }
        let cursor = min(max(cursorRow, 0), rows.count - 1)
        let near = rows[max(cursor - 3, 0)..<min(cursor + 9, rows.count)]
        if near.contains(where: { matches(geminiModel, $0) || $0.contains("Type your message") }) { return .gemini }
        if near.contains(where: { matches(codexContext, $0) }) { return .codex }
        if near.contains(where: {
            ($0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("─╯") &&
                ($0.contains("Grok") || $0.contains("always-approve"))) || $0.contains("Ctrl+x:shortcuts")
        }) { return .grok }
        // Codex's prompt; its footer also says "? for shortcuts" and "esc to interrupt", and a phone-wide screen cuts
        // "Context … left" off.
        if rows[cursor].drop(while: { $0.isWhitespace }).hasPrefix("› ") { return .codex }
        if near.contains(where: { line in claudeFooters.contains(where: line.contains) }) || claudePrompt(rows, cursor: cursor) {
            return .claude
        }
        return .shell
    }

    private static func matches(_ expression: NSRegularExpression, _ row: String) -> Bool {
        expression.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) != nil
    }

    private static func claudePrompt(_ rows: [String], cursor: Int) -> Bool {
        guard let top = stride(from: cursor, through: max(cursor - 3, 0), by: -1).first(where: { matches(rule, rows[$0]) }),
              top + 1 < rows.count,
              rows[top + 1].drop(while: { $0.isWhitespace }).hasPrefix("❯") else { return false }
        let bottom = min(cursor + 6, rows.count - 1)
        guard top + 2 <= bottom else { return false }
        return (top + 2...bottom).contains(where: { matches(rule, rows[$0]) })
    }
}

/// Literal bytes, terminal-encoded function keys, one-shot modifiers, or a submenu.
public indirect enum TerminalShortcutAction: Equatable, Sendable {
    /// Send once immediately, then once more after `repeatAfter` seconds when present.
    /// Android's double Escape uses 0.12 seconds; concatenating ESC ESC is not equivalent.
    case keys(String, repeatAfter: TimeInterval?)
    /// F1...F12; the terminal encodes these with its active keyboard mode/modifiers.
    case functionKey(Int)
    case ctrl
    case shift
    case menu([TerminalShortcut])
}

public struct TerminalShortcut: Equatable, Sendable {
    public let label: String
    public let hintZh: String
    public let hintEn: String
    public let descriptionZh: String
    public let descriptionEn: String
    public let tag: String
    public let action: TerminalShortcutAction

    public init(label: String, hintZh: String, hintEn: String, descriptionZh: String,
                descriptionEn: String, tag: String, action: TerminalShortcutAction) {
        self.label = label
        self.hintZh = hintZh
        self.hintEn = hintEn
        self.descriptionZh = descriptionZh
        self.descriptionEn = descriptionEn
        self.tag = tag
        self.action = action
    }

    public func hint(english: Bool) -> String { english ? hintEn : hintZh }
    public func description(english: Bool) -> String { english ? descriptionEn : descriptionZh }
}

extension ScreenApp {
    /// Android PetShortcutArc.kt's top-to-bottom order and AppLocale.kt's exact text.
    /// These are separate tables because identical chords do different things in each CLI.
    public var shortcuts: [TerminalShortcut] {
        switch self {
        case .claude:
            return [
                shortcutKeys("^T", "任务", "Tasks", "Ctrl+T：显示或隐藏任务列表", "Ctrl+T: show or hide the todo list", "pet-ctrl-t", "\u{14}"),
                shortcutKeys("^O", "详情", "Details", "Ctrl+O：展开完整对话记录", "Ctrl+O: expand the full transcript", "pet-ctrl-o", "\u{0f}"),
                shortcutKeys("Esc²", "回退", "Rewind", "Esc Esc：回退到之前的消息", "Esc Esc: rewind to an earlier message", "pet-escape-twice", "\u{1b}", repeatAfter: 0.12),
                shortcutKeys("⇧Tab", "模式", "Mode", "Shift+Tab：切换模式（默认 / 接受编辑 / 计划）", "Shift+Tab: switch mode (default / accept edits / plan)", "pet-shift-tab", "\u{1b}[Z"),
                shortcutKeys("^C", "取消", "Cancel", "Ctrl+C：清空输入或取消", "Ctrl+C: clear input or cancel", "pet-ctrl-c", "\u{03}"),
                shortcutKeys("^B", "后台", "Background", "Ctrl+B：把运行中的任务转到后台", "Ctrl+B: move the running task to the background", "pet-ctrl-b", "\u{02}"),
                shortcutKeys("⌥P", "模型", "Model", "Alt+P：切换模型", "Alt+P: switch model", "pet-alt-p", "\u{1b}p")
            ]
        case .codex:
            return [
                shortcutKeys("^T", "记录", "Log", "Ctrl+T：打开对话记录", "Ctrl+T: open the transcript", "pet-ctrl-t", "\u{14}"),
                shortcutKeys("^O", "复制", "Copy", "Ctrl+O：复制最后一条回复", "Ctrl+O: copy the last reply", "pet-ctrl-o", "\u{0f}"),
                shortcutKeys("Esc²", "编辑", "Edit", "Esc Esc：编辑上一条消息", "Esc Esc: edit the previous message", "pet-escape-twice", "\u{1b}", repeatAfter: 0.12),
                shortcutKeys("⇧Tab", "计划", "Plan", "Shift+Tab：切换 Plan 模式", "Shift+Tab: toggle Plan mode", "pet-shift-tab", "\u{1b}[Z"),
                shortcutKeys("⇧←", "回答", "Answer", "Shift+←：回答提问", "Shift+←: answer the question", "pet-shift-left", "\u{1b}[1;2D"),
                shortcutKeys("⇧→", "返回", "Back", "Shift+→：回到输入框", "Shift+→: back to the composer", "pet-shift-right", "\u{1b}[1;2C"),
                shortcutKeys("^C", "取消", "Cancel", "Ctrl+C：清空输入或退出", "Ctrl+C: clear input or quit", "pet-ctrl-c", "\u{03}")
            ]
        case .grok:
            return [
                shortcutKeys("^T", "任务", "Tasks", "Ctrl+T：显示或隐藏任务面板", "Ctrl+T: show or hide the todo pane", "pet-ctrl-t", "\u{14}"),
                shortcutKeys("^O", "自动", "Auto", "Ctrl+O：开关自动批准", "Ctrl+O: toggle auto-approve", "pet-ctrl-o", "\u{0f}"),
                shortcutKeys("^P", "命令", "Palette", "Ctrl+P：打开命令面板", "Ctrl+P: open the command palette", "pet-ctrl-p", "\u{10}"),
                shortcutKeys("⇧Tab", "模式", "Mode", "Shift+Tab：切换模式（普通 / 计划 / 自动批准）", "Shift+Tab: switch mode (normal / plan / always approve)", "pet-shift-tab", "\u{1b}[Z"),
                shortcutKeys("^C", "中断", "Stop", "Ctrl+C：中断当前回复", "Ctrl+C: interrupt the reply", "pet-ctrl-c", "\u{03}"),
                shortcutKeys("^X", "快捷", "Keys", "Ctrl+X：查看全部快捷键", "Ctrl+X: show all shortcuts", "pet-ctrl-x", "\u{18}")
            ]
        case .gemini:
            return [
                shortcutKeys("^T", "任务", "Tasks", "Ctrl+T：查看完整任务列表", "Ctrl+T: show the full todo list", "pet-ctrl-t", "\u{14}"),
                shortcutKeys("^O", "展开", "More", "Ctrl+O：显示更多内容", "Ctrl+O: show more lines", "pet-ctrl-o", "\u{0f}"),
                shortcutKeys("^Y", "YOLO", "YOLO", "Ctrl+Y：开关 YOLO 模式", "Ctrl+Y: toggle YOLO mode", "pet-ctrl-y", "\u{19}"),
                shortcutKeys("⇧Tab", "模式", "Mode", "Shift+Tab：切换批准模式", "Shift+Tab: switch approval mode", "pet-shift-tab", "\u{1b}[Z"),
                shortcutKeys("Esc²", "回退", "Rewind", "Esc Esc：清空输入或回退", "Esc Esc: clear input or rewind", "pet-escape-twice", "\u{1b}", repeatAfter: 0.12),
                shortcutKeys("^L", "清屏", "Clear", "Ctrl+L：清屏", "Ctrl+L: clear the screen", "pet-ctrl-l", "\u{0c}"),
                shortcutKeys("^C", "取消", "Cancel", "Ctrl+C：取消或退出", "Ctrl+C: cancel or quit", "pet-ctrl-c", "\u{03}")
            ]
        case .shell:
            return [
                TerminalShortcut(label: "Fn", hintZh: "F1–12", hintEn: "F1–12",
                                 descriptionZh: "功能键：停在这里展开 F1–F12",
                                 descriptionEn: "Function keys: rest here to open F1–F12",
                                 tag: "pet-fn", action: .menu((1...12).map { number in
                    TerminalShortcut(label: "F\(number)", hintZh: "", hintEn: "", descriptionZh: "发送 F\(number)",
                                     descriptionEn: "Send F\(number)", tag: "pet-f\(number)", action: .functionKey(number))
                                 })),
                TerminalShortcut(label: "Ctrl", hintZh: "下一键", hintEn: "Next key",
                                 descriptionZh: "Ctrl，作用于下一次键盘字符",
                                 descriptionEn: "Ctrl applies to the next keyboard character", tag: "pet-ctrl", action: .ctrl),
                TerminalShortcut(label: "Shift", hintZh: "下一键", hintEn: "Next key",
                                 descriptionZh: "Shift，作用于下一次按键",
                                 descriptionEn: "Shift, applied to the next key", tag: "pet-shift", action: .shift),
                shortcutKeys("Tab", "补全", "Complete", "Tab：补全命令或路径", "Tab: complete a command or path", "pet-tab", "\t"),
                shortcutKeys("^C", "中断", "Stop", "Ctrl+C：中断当前命令", "Ctrl+C: interrupt the command", "pet-ctrl-c", "\u{03}"),
                shortcutKeys("^R", "历史", "History", "Ctrl+R：搜索历史命令", "Ctrl+R: search command history", "pet-ctrl-r", "\u{12}"),
                shortcutKeys("^D", "退出", "Exit", "Ctrl+D：结束输入或退出", "Ctrl+D: end input or exit", "pet-ctrl-d", "\u{04}"),
                shortcutKeys("^Z", "挂起", "Suspend", "Ctrl+Z：挂起前台程序", "Ctrl+Z: suspend the foreground program", "pet-ctrl-z", "\u{1a}")
            ]
        }
    }
}

private func shortcutKeys(_ label: String, _ hintZh: String, _ hintEn: String,
                          _ descriptionZh: String, _ descriptionEn: String, _ tag: String,
                          _ keys: String, repeatAfter: TimeInterval? = nil) -> TerminalShortcut {
    TerminalShortcut(label: label, hintZh: hintZh, hintEn: hintEn, descriptionZh: descriptionZh,
                     descriptionEn: descriptionEn, tag: tag, action: .keys(keys, repeatAfter: repeatAfter))
}

/// Android's left-facing shortcut ring. Coordinates use y increasing downward;
/// angles are degrees with zero pointing right. Item zero is the uppermost item.
public struct TerminalShortcutArc: Equatable, Sendable {
    public let radius: Double
    public let angles: [Double]

    /// `top` and `bottom` bound item centres; the UI accounts for the item radius.
    /// Shrinks the circle to find enough space, or uses the longest available arc.
    public static func layout(count: Int, centerY: Double, top: Double, bottom: Double,
                              maxRadius: Double, minRadius: Double, spacing: Double) -> TerminalShortcutArc {
        guard count > 0, centerY.isFinite, top.isFinite, bottom.isFinite, top <= bottom,
              maxRadius.isFinite, minRadius.isFinite, spacing.isFinite,
              maxRadius > 0, minRadius > 0, spacing >= 0 else {
            return TerminalShortcutArc(radius: 0, angles: [])
        }
        let minimum = min(minRadius, maxRadius)
        let maxReach = sin(80 * Double.pi / 180)
        func reach(_ room: Double, radius: Double) -> Double {
            asin(min(max(room / radius, 0), maxReach))
        }
        var radius = maxRadius
        var bestRadius = radius
        var bestUp = 0.0
        var bestDown = 0.0
        var bestLength = -1.0
        while true {
            let up = reach(centerY - top, radius: radius)
            let down = reach(bottom - centerY, radius: radius)
            let length = radius * (up + down)
            if length > bestLength {
                bestRadius = radius
                bestUp = up
                bestDown = down
                bestLength = length
            }
            if length >= spacing * Double(count - 1) || radius <= minimum { break }
            radius = max(radius - maxRadius / 32, minimum)
        }
        let first = 180 + bestUp * 180 / Double.pi
        let last = 180 - bestDown * 180 / Double.pi
        let angles = count == 1 ? [180] : (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
        return TerminalShortcutArc(radius: bestRadius, angles: angles)
    }

    public func itemOffset(at index: Int) -> (x: Double, y: Double) {
        let angle = angles[index] * Double.pi / 180
        return (radius * cos(angle), radius * sin(angle))
    }

    /// A short flick is sufficient once it leaves the inner 42% of the circle.
    /// Direction, rather than distance from the icon, selects the nearest item.
    public func hoveredItem(x: Double, y: Double) -> Int? {
        guard !angles.isEmpty, x.isFinite, y.isFinite, hypot(x, y) >= radius * 0.42 else { return nil }
        let raw = atan2(y, x) * 180 / Double.pi
        let angle = raw < 0 ? raw + 360 : raw
        var nearest = 0
        for index in angles.indices.dropFirst() where abs(angles[index] - angle) < abs(angles[nearest] - angle) {
            nearest = index
        }
        let step = angles.count > 1 ? abs(angles[0] - angles[1]) : 40
        return abs(angles[nearest] - angle) <= max(step * 0.6, 15) ? nearest : nil
    }
}
