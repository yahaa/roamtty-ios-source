import Foundation

/// Keeps a remote vertical swipe scrolling after the finger lifts, slowing down like a UIScrollView.
///
/// Android flings through Termux's `Scroller` and lets one fling travel at most half a screen of rows when tmux or
/// the alternate screen scrolls; the same cap applies here. Rows count downward: positive scrolls toward newer
/// output, as `TerminalScrollAccumulator.rowsDown` does.
public struct TerminalScrollInertia: Equatable {
    /// The UIScrollView `.normal` deceleration rate: velocity keeps this share of itself each millisecond.
    public static let decelerationRate = 0.998
    /// Seconds for the velocity to fall by a factor of e.
    static let timeConstant = -0.001 / log(decelerationRate)

    private let velocity: Double
    /// The whole number of rows the fling travels, signed.
    public let totalRows: Int
    private var sentRows = 0

    /// nil when the swipe was too slow to carry on for a row.
    public init?(rowsPerSecond: Double, screenRows: Int) {
        guard rowsPerSecond.isFinite else { return nil }
        let limit = Double(max(1, screenRows / 2))
        let distance = min(limit, abs(rowsPerSecond) * Self.timeConstant)
        guard distance >= 1 else { return nil }
        let sign: Double = rowsPerSecond < 0 ? -1 : 1
        velocity = sign * distance / Self.timeConstant
        totalRows = Int(sign) * Int(distance)
    }

    public var finished: Bool { sentRows == totalRows }

    /// The rows to scroll now, `elapsed` seconds after the finger lifted.
    public mutating func rowsDown(after elapsed: TimeInterval) -> Int {
        let travelled = abs(velocity) * Self.timeConstant * (1 - exp(-max(0, elapsed) / Self.timeConstant))
        let reached = min(abs(totalRows), Int(travelled.rounded())) * (totalRows < 0 ? -1 : 1)
        defer { sentRows = reached }
        return reached - sentRows
    }
}
