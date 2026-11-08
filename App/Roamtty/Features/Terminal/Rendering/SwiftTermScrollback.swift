import SwiftTerm

extension Terminal {
    /// How many lines a full scrollback has dropped from its top so far, as the rest moved up to make room.
    ///
    /// SwiftTerm counts them privately (`linesTop`) and numbers its lines from there, so `getScrollInvariantLine`
    /// answers only for rows `dropped ..< dropped + kept`; this finds where that window starts. `earlier` is a
    /// previous answer and `fed` the bytes fed since: the count grows by at most a line per byte, and starts again
    /// from 0 once the scrollback is cleared. Reports the main screen's count while it is shown.
    func droppedScrollbackLines(since earlier: Int, fed: Int) -> Int {
        func kept(_ row: Int) -> Bool { row >= 0 && getScrollInvariantLine(row: row) != nil }
        if kept(earlier) && !kept(earlier - 1) { return earlier }
        if kept(0) { return 0 }
        // At least a screen of lines is kept, so stepping a screen at a time cannot pass over them.
        let step = max(1, rows), start = max(0, earlier)
        guard let inside = stride(from: start, through: start + fed + step, by: step).first(where: kept)
                ?? stride(from: 0, to: Int.max - step, by: step).first(where: kept) else { return earlier }
        var low = inside, below = inside - step
        while kept(below) { low = below; below -= step }
        // The first kept row is after `below` and at or before `low`.
        var lower = max(0, below + 1)
        while lower < low {
            let middle = (lower + low) / 2
            if kept(middle) { low = middle } else { lower = middle + 1 }
        }
        return low
    }
}
