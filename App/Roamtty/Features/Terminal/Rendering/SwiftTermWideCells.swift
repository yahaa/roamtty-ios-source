import SwiftTerm

extension Terminal {
    /// Blanks what is left of a wide character once one of its halves is overwritten, as xterm does, and returns
    /// whether a screen row changed. SwiftTerm 1.13 keeps the other half: a right half left on its own draws as a
    /// white block, because SwiftTerm stamps it with an inverted background it never sets, and a left half hides
    /// whatever was written over its right. mosh sends only the cells it changed and counts on the terminal to have
    /// blanked these, so a line of Chinese redrawn one column over kept a block until the row was rewritten.
    func blankSplitWideCharacters() -> Bool {
        var changed = false
        for row in 0..<rows {
            guard let line = getLine(row: row) else { continue }
            let end = min(cols, line.count)
            var left: CharData?
            var col = 0
            while col < end {
                let cell = line[col]
                if cell.width == 2 && col + 1 < end && line[col + 1].width == 0 {
                    left = cell; col += 2; continue
                }
                if cell.width == 2 {
                    line[col] = buffer.getNullCell(attribute: cell.attribute); changed = true
                } else if cell.width == 0 {
                    line[col] = left.map { buffer.getNullCell(attribute: $0.attribute) } ?? CharData.Null; changed = true
                }
                left = line[col]; col += 1
            }
        }
        return changed
    }
}
