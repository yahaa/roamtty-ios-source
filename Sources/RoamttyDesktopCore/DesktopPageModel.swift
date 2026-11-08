import Foundation

/// Which sheet sits over the picture (Android `DesktopPanel`).
public enum DesktopPanel: String, Sendable { case none, operations, keyboard }

/// Which keyboard sub-page is showing (IME vs the F-key / 更多 page).
public enum DesktopKeyboardPage: String, Sendable { case ime, more }

/// Pure UI state for the desktop page: rail, panels, pointer mode, overlays. The session itself is
/// owned elsewhere; this only decides what the page shows and which inputs it would send.
/// Linux-testable; SwiftUI binds to it on iOS.
public final class DesktopPageModel: @unchecked Sendable {
    public var panel: DesktopPanel = .none
    public var pointerMode: PointerMode = .touch
    public var virtualMouse = false
    public var showStats = false
    public var keyboardPage: DesktopKeyboardPage = .ime
    public let latch = ModifierLatch()
    /// Clip note under the 操作 clipboard buttons.
    public var clipNote: String?
    public var english = false

    public init(pointerMode: PointerMode = .touch, showStats: Bool = false, english: Bool = false) {
        self.pointerMode = pointerMode; self.showStats = showStats; self.english = english
    }

    public func togglePanel(_ p: DesktopPanel) { panel = panel == p ? .none : p }
    public func dismissPanel() { panel = .none }

    /// A modifier of the shortcut bar: tap latches once, long-press locks.
    public func tapModifier(_ hid: Int) { latch.tap(hid) }
    public func holdModifier(_ hid: Int) { latch.hold(hid) }

    /// Press a non-modifier key through the latch (Android `key(hid)`).
    public func pressKey(_ hid: Int) -> [ModifierLatch.KeyEvent] { latch.press(hid) }

    /// A combo shortcut: all down, then all up in reverse.
    public func combo(_ keys: [Int]) -> [ModifierLatch.KeyEvent] {
        keys.map { ModifierLatch.KeyEvent($0, true) } + keys.reversed().map { ModifierLatch.KeyEvent($0, false) }
    }

    /// IME committed text: with a modifier latched, a single letter is a shortcut; else it is typed text
    /// (newlines become Enter). Returns the frames to send, in order.
    public enum Typed: Equatable {
        case frames([[UInt8]])
        case composingIgnored
    }

    public func commitIME(_ text: String, composing: Bool) -> Typed {
        if composing { return .composingIgnored }
        if text.isEmpty { return .frames([]) }
        if let ch = text.unicodeScalars.first, text.unicodeScalars.count == 1,
           let hid = Self.charKey(Character(ch)), latch.latched {
            return .frames(pressKey(hid).map { DesktopProtocol.key($0.hid, down: $0.down) })
        }
        var frames: [[UInt8]] = []
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if i > 0 { frames.append(contentsOf: pressKey(HidUsage.ENTER).map { DesktopProtocol.key($0.hid, down: $0.down) }) }
            if !part.isEmpty { frames.append(DesktopProtocol.text(String(part))) }
        }
        return .frames(frames)
    }

    public static func modifierKeys(os: String) -> [(label: String, hid: Int)] {
        switch os.lowercased() {
        case "macos": return [("⌃", HidUsage.LEFT_CTRL), ("⌥", HidUsage.LEFT_ALT), ("⌘", HidUsage.LEFT_GUI)]
        case "windows": return [("Ctrl", HidUsage.LEFT_CTRL), ("Alt", HidUsage.LEFT_ALT), ("Win", HidUsage.LEFT_GUI)]
        default: return [("Ctrl", HidUsage.LEFT_CTRL), ("Alt", HidUsage.LEFT_ALT), ("Super", HidUsage.LEFT_GUI)]
        }
    }

    public static func comboKeys(os: String) -> [(label: String, keys: [Int])] {
        switch os.lowercased() {
        case "macos":
            return [("⌘Tab", [HidUsage.LEFT_GUI, HidUsage.TAB]),
                    ("⌘Space", [HidUsage.LEFT_GUI, HidUsage.SPACE]),
                    ("⌘Q", [HidUsage.LEFT_GUI, HidUsage.letter("q")])]
        case "windows":
            return [("Alt+Tab", [HidUsage.LEFT_ALT, HidUsage.TAB]),
                    ("Ctrl+Shift+Esc", [HidUsage.LEFT_CTRL, HidUsage.LEFT_SHIFT, HidUsage.ESCAPE]),
                    ("Win+E", [HidUsage.LEFT_GUI, HidUsage.letter("e")])]
        default:
            return [("Alt+Tab", [HidUsage.LEFT_ALT, HidUsage.TAB]),
                    ("Ctrl+Alt+T", [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT, HidUsage.letter("t")]),
                    ("Alt+F4", [HidUsage.LEFT_ALT, HidUsage.f(4)])]
        }
    }

    public static func moreKeys() -> [(label: String, hid: Int)] {
        (1...12).map { ("F\($0)", HidUsage.f($0)) } + [
            ("Home", HidUsage.HOME), ("End", HidUsage.END), ("PgUp", HidUsage.PAGE_UP), ("PgDn", HidUsage.PAGE_DOWN),
            ("Del", HidUsage.DELETE), ("Ins", HidUsage.INSERT), ("Shift", HidUsage.LEFT_SHIFT),
            ("PrtSc", HidUsage.PRINT_SCREEN), ("←", HidUsage.LEFT), ("↑", HidUsage.UP), ("↓", HidUsage.DOWN), ("→", HidUsage.RIGHT)
        ]
    }

    /// A typed character as the key that makes it on a US layout, for shortcuts like Ctrl+C.
    public static func charKey(_ c: Character) -> Int? {
        if let s = c.unicodeScalars.first {
            let v = s.value
            if (65...90).contains(v) { return HidUsage.letter(Character(UnicodeScalar(v + 32)!)) }
            if (97...122).contains(v) { return HidUsage.letter(c) }
            if (49...57).contains(v) { return 0x1E + Int(v - 49) }
            if v == 48 { return 0x27 }
            if v == 32 { return HidUsage.SPACE }
        }
        return nil
    }

    public func qualityLabel(_ q: String) -> String {
        switch q {
        case "auto": return english ? "Auto" : "自动"
        case "smooth": return english ? "Smooth" : "流畅"
        case "clear": return english ? "Clear" : "清晰"
        case "original": return english ? "Original" : "原画"
        default: return q
        }
    }

    public func clipSentNote(empty: Bool) -> String {
        if empty { return english ? "Phone clipboard is empty" : "手机剪贴板为空" }
        return english ? "Sent to the remote clipboard" : "已发送到远程剪贴板"
    }

    public func clipReceivedNote(length: Int) -> String {
        if length == 0 { return english ? "Remote clipboard is empty" : "远程剪贴板为空" }
        return english ? "Copied remote clipboard (\(length) chars)" : "已复制远程剪贴板（\(length) 字）"
    }
}

private extension ModifierLatch {
    var latched: Bool {
        [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT, HidUsage.LEFT_GUI, HidUsage.LEFT_SHIFT].contains { state($0) != .off }
    }
}
