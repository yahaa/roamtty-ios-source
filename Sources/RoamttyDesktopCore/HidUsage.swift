/// USB HID keyboard usages (page 0x07): keys go by physical position, whatever the remote layout.
/// Port of Android `desktop-core/HidUsage.kt` (roamtty #218).
public enum HidUsage {
    public static let A = 0x04
    public static let C = 0x06
    public static let D = 0x07
    public static let V = 0x19
    public static let X = 0x1B
    public static let Z = 0x1D
    public static let ENTER = 0x28
    public static let ESCAPE = 0x29
    public static let BACKSPACE = 0x2A
    public static let TAB = 0x2B
    public static let SPACE = 0x2C
    public static let F1 = 0x3A
    public static let PRINT_SCREEN = 0x46
    public static let INSERT = 0x49
    public static let HOME = 0x4A
    public static let PAGE_UP = 0x4B
    public static let DELETE = 0x4C
    public static let END = 0x4D
    public static let PAGE_DOWN = 0x4E
    public static let RIGHT = 0x4F
    public static let LEFT = 0x50
    public static let DOWN = 0x51
    public static let UP = 0x52
    public static let LEFT_CTRL = 0xE0
    public static let LEFT_SHIFT = 0xE1
    public static let LEFT_ALT = 0xE2
    public static let LEFT_GUI = 0xE3

    public static func letter(_ c: Character) -> Int {
        let v = Int(c.lowercased().unicodeScalars.first!.value)
        return A + (v - Int(UnicodeScalar("a").value))
    }

    public static func f(_ n: Int) -> Int { n <= 12 ? F1 + n - 1 : 0x68 + n - 13 }

    /// The keys Android's `fromAndroid` passes on (letters, digits, punctuation, F1–F12, editing and
    /// arrow keys, keypad, menu, modifiers), plus ISO's extra backslash key (0x64) that iOS reports.
    private static let desktopKeys: [ClosedRange<Int>] = [0x04...0x31, 0x33...0x63, 0x64...0x65, 0xE0...0xE7]

    /// A hardware keyboard's `UIKey.keyCode` (a `UIKeyboardHIDUsage`, already a HID usage) to the usage
    /// to send; nil for keys a desktop has no use for (media keys, language keys, …). iOS counterpart of
    /// Android's `HidUsage.fromAndroid(KeyEvent.KEYCODE_*)`.
    public static func fromKeyboardHIDUsage(_ usage: Int) -> Int? {
        desktopKeys.contains { $0.contains(usage) } ? usage : nil
    }
}

/// The on-screen computer keyboard's modifiers (plan §5.2): a tap latches one for the next key, a long
/// press holds it until tapped again.
public final class ModifierLatch {
    public enum State: Sendable { case off, once, locked }

    public struct KeyEvent: Equatable, Sendable {
        public let hid: Int
        public let down: Bool
        public init(_ hid: Int, _ down: Bool) { self.hid = hid; self.down = down }
    }

    /// Insertion-ordered, like Kotlin's linkedMapOf: modifiers go down in the order they were latched.
    private var order: [Int] = []
    private var states: [Int: State] = [:]

    public init() {}

    public func state(_ hid: Int) -> State { states[hid] ?? .off }

    private func set(_ hid: Int, _ s: State) {
        if states[hid] == nil { order.append(hid) }
        states[hid] = s
    }

    public func tap(_ hid: Int) { set(hid, state(hid) == .off ? .once : .off) }

    public func hold(_ hid: Int) { set(hid, .locked) }

    /// A key was tapped: the (key, down) events to send. Latched modifiers wrap the key; once-latched ones then release.
    public func press(_ hid: Int) -> [KeyEvent] { wrap([hid]) }

    private func wrap(_ keys: [Int]) -> [KeyEvent] {
        let mods = order.filter { states[$0] != .off && !keys.contains($0) }
        var out: [KeyEvent] = []
        mods.forEach { out.append(KeyEvent($0, true)) }
        keys.forEach { out.append(KeyEvent($0, true)) }
        keys.reversed().forEach { out.append(KeyEvent($0, false)) }
        mods.reversed().forEach { out.append(KeyEvent($0, false)) }
        for (hid, s) in states where s == .once { states[hid] = nil; order.removeAll { $0 == hid } }
        return out
    }
}
