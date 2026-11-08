import Foundation

/// Tells a held keyboard delete from tapped ones (Android `ImeBackspaceTracker`). A held delete clears the line once
/// and swallows the rest of its repeats.
///
/// The keyboard reports only repeated deletes, never the key going down or up, so this goes by arrival time. Measured
/// on iOS 26: one delete, about 500 ms of nothing, about 2 s of one every 100 ms, then one or two every 350 ms. The
/// first pause and any tap break the 100 ms stream, so only that stream can start a clear. The slower last phase
/// would look like a release to the same test, which is why a clear stays in force over longer gaps than start one.
public struct TerminalDeleteHold: Equatable {
    public enum Action: Equatable { case delete, clear, ignore }

    /// Seconds between deletes that still count as one stream.
    static let repeatGap = 0.15
    /// Seconds of unbroken stream that make a hold.
    static let holdDuration = 0.6
    /// Seconds without a delete that end a hold already cleared: longer than the keyboard's slowest repeat.
    static let clearedGap = 0.6

    private var started: Double?
    private var last: Double?
    private var cleared = false

    public init() {}

    /// What the delete arriving at `now` (seconds, monotonic) should do.
    public mutating func onDelete(at now: Double) -> Action {
        let sameStream = last.map { now >= $0 && now - $0 <= (cleared ? Self.clearedGap : Self.repeatGap) } ?? false
        if !sameStream {
            started = now
            cleared = false
        }
        last = now
        if cleared { return .ignore }
        if now - (started ?? now) >= Self.holdDuration {
            cleared = true
            return .clear
        }
        return .delete
    }

    /// Any other input ends the stream.
    public mutating func reset() {
        started = nil
        last = nil
        cleared = false
    }

    /// Whether these bytes are one press of the delete key, with or without the kitty keyboard protocol on.
    public static func isDelete(_ bytes: Data) -> Bool {
        if bytes == Data([0x7f]) || bytes == Data([0x08]) { return true }
        return ["\u{1b}[127u", "\u{1b}[127;1u", "\u{1b}[127;1:1u"].contains(String(decoding: bytes, as: UTF8.self))
    }

    /// Readline's kill to line start and kill to line end, as Android sends. History is left alone.
    public static let clearLine = Data([0x15, 0x0b])
}
