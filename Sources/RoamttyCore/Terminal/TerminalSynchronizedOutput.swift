import Foundation

/// Synchronized output (DEC private mode 2026): the host brackets a redraw with `CSI ? 2026 h` and `CSI ? 2026 l`,
/// as Claude Code does every frame, and the terminal holds the old screen on show until the frame ends.
public enum TerminalSynchronizedOutput {
    /// A terminal shows the frame anyway this long after it began, as SwiftTerm does.
    public static let timeout: TimeInterval = 1
    private static let mode = Array("\u{1b}[?2026".utf8)

    /// Whether the last mode change in `bytes` begins a frame (true) or ends one (false); nil when there is none.
    public static func lastChange(in bytes: ArraySlice<UInt8>) -> Bool? {
        var end = bytes.endIndex
        while let final = bytes[..<end].lastIndex(where: { $0 == UInt8(ascii: "h") || $0 == UInt8(ascii: "l") }) {
            if final - bytes.startIndex >= mode.count && bytes[(final - mode.count)..<final].elementsEqual(mode) {
                return bytes[final] == UInt8(ascii: "h")
            }
            end = final
        }
        return nil
    }
}
