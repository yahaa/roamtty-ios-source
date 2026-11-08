import UIKit
import CoreText
import SwiftTerm
#if canImport(RoamttyCore)
import RoamttyCore
#endif

/// Android's pressed link (roamtty #275): the link or path under a finger turns the accent colour, underlined, once
/// the touch has stayed long enough to be a press, and for a moment after a tap opens it. SwiftTerm has no way to
/// restyle cells, so the marked characters are drawn again over the terminal, on its background.
@MainActor final class TerminalLinkPress {
    /// Like a list item's pressed state: a scroll that starts on a link does not flash it (Android's tap timeout).
    static let pressDelay: TimeInterval = 0.1
    /// How long a confirmed tap keeps its link marked, so the press reads as a response.
    static let shownAfterTap: TimeInterval = 0.15
    /// A lifted finger's mark waits this long for its tap to be confirmed, which waits out a double tap.
    static let shownAfterLift: TimeInterval = 0.35 + shownAfterTap

    private weak var terminalView: TerminalView?
    private let overlay = PressedLinkView()
    private var marked: [PressedLinkView.Glyph] = []
    private var pending: DispatchWorkItem?
    private var clearing: DispatchWorkItem?

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.accessibilityElementsHidden = true
    }

    /// A finger came down on `spans` (nil: on no link). The mark shows after `pressDelay` unless the touch moves on.
    func press(_ spans: [TerminalLinkSpan]?) {
        clear()
        guard let spans, !spans.isEmpty, let view = terminalView else { return }
        let grid = SwiftTermTextGrid(terminal: view.getTerminal())
        marked = spans.flatMap { span -> [PressedLinkView.Glyph] in
            let cells = grid.cells(span.row)
            return (span.start..<min(span.end, cells.count)).compactMap { column in
                let cell = cells[column]
                guard cell.width > 0, !cell.text.isEmpty else { return nil }
                return PressedLinkView.Glyph(row: span.row, column: column, width: cell.width, text: cell.text)
            }
        }
        let show = DispatchWorkItem { [weak self] in self?.show() }
        pending = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressDelay, execute: show)
    }

    /// The finger lifted: a quick tap lifts before the press shows, so it shows now, until the tap is confirmed.
    func lift() {
        guard !marked.isEmpty else { return }
        show()
        clear(after: Self.shownAfterLift)
    }

    /// The tap opened the link: its mark stays a moment longer.
    func confirm() {
        guard !marked.isEmpty else { return }
        show()
        clear(after: Self.shownAfterTap)
    }

    /// The terminal's content changed or scrolled: a mark over characters no longer there would show stale text, so it
    /// goes once any marked cell reads differently.
    func contentChanged() {
        guard !marked.isEmpty, let view = terminalView else { return }
        let grid = SwiftTermTextGrid(terminal: view.getTerminal())
        var rows: [Int: [TerminalTextCell]] = [:]
        let stale = marked.contains { glyph in
            let cells = rows[glyph.row] ?? grid.cells(glyph.row)
            rows[glyph.row] = cells
            return !cells.indices.contains(glyph.column) || cells[glyph.column].text != glyph.text
        }
        if stale { clear() }
    }

    func clear() {
        pending?.cancel(); pending = nil
        clearing?.cancel(); clearing = nil
        marked = []
        overlay.glyphs = []
        overlay.removeFromSuperview()
    }

    private func clear(after delay: TimeInterval) {
        clearing?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clear() }
        clearing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show() {
        pending?.cancel(); pending = nil
        guard let view = terminalView, !marked.isEmpty else { return }
        let terminal = view.getTerminal(), size = view.getOptimalFrameSize()
        overlay.cell = CGSize(width: size.width / CGFloat(max(1, terminal.cols)), height: size.height / CGFloat(max(1, terminal.rows)))
        overlay.font = view.font
        overlay.color = UIColor(Palette.accent)
        overlay.background = view.nativeBackgroundColor
        overlay.glyphs = marked
        // The scroll view's bounds start at its content offset: row 0 is the top row on screen.
        overlay.frame = view.bounds
        if overlay.superview !== view { view.addSubview(overlay) } else { view.bringSubviewToFront(overlay) }
        overlay.setNeedsDisplay()
    }
}

/// The marked characters, drawn where SwiftTerm draws them: each in its own cells, on the line's baseline.
final class PressedLinkView: UIView {
    struct Glyph { let row: Int; let column: Int; let width: Int; let text: String }
    var glyphs: [Glyph] = []
    var cell = CGSize(width: 8, height: 16)
    var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var color = UIColor.systemBlue
    var background = UIColor.black

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !glyphs.isEmpty else { return }
        // SwiftTerm puts the baseline its descent and leading above the bottom of the row.
        let baselineFromBottom = ceil(-font.descender + font.leading)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let underline = (position: CTFontGetUnderlinePosition(font as CTFont), thickness: CTFontGetUnderlineThickness(font as CTFont))
        for glyph in glyphs {
            let box = CGRect(x: CGFloat(glyph.column) * cell.width, y: CGFloat(glyph.row) * cell.height,
                             width: CGFloat(glyph.width) * cell.width, height: cell.height)
            context.setFillColor(background.cgColor)
            context.fill(box.insetBy(dx: -0.5, dy: 0))
            let baseline = box.maxY - baselineFromBottom
            (glyph.text as NSString).draw(at: CGPoint(x: box.minX, y: baseline - font.ascender), withAttributes: attributes)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: box.minX, y: baseline + max(1, -underline.position), width: box.width, height: max(1, underline.thickness)))
        }
    }
}

/// Follows every touch on the terminal without taking part: down, a move past the slop, up or a cancel.
@MainActor final class TerminalTouchTracker: UIGestureRecognizer {
    private let began: (CGPoint) -> Void
    private let moved: () -> Void
    private let ended: () -> Void
    private var start: CGPoint?
    init(began: @escaping (CGPoint) -> Void, moved: @escaping () -> Void, ended: @escaping () -> Void) {
        self.began = began; self.moved = moved; self.ended = ended
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.count ?? touches.count) == 1, let touch = touches.first, let view else { start = nil; moved(); return }
        let point = touch.location(in: view)
        start = point; began(point)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if hypot(point.x - start.x, point.y - start.y) > 10 { self.start = nil; moved() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if start != nil { ended() }
        start = nil; state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if start != nil { moved() }
        start = nil; state = .failed
    }
    override func reset() { start = nil }
}
