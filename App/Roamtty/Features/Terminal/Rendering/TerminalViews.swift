import UIKit
import SwiftUI
import SwiftTerm
import RoamttyCore

struct NativeTerminal: UIViewRepresentable {
    /// Not observed: the view only needs the settings and the colour scheme reapplied, not every change of the session.
    let runtime: SessionRuntime
    @ObservedObject private var fonts = FontCatalog.shared
    var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> TerminalView { runtime.configure(settings: settings, scheme: scheme); return runtime.terminalView }
    func updateUIView(_ view: TerminalView, context: Context) { runtime.configure(settings: settings, scheme: scheme) }
    static func dismantleUIView(_ view: TerminalView, coordinator: ()) { _ = view.resignFirstResponder() }
}

/// The terminal surface: steady cursors like Android's, VoiceOver text, and hooks the runtime needs from the view.
@MainActor final class AccessibleTerminalView: TerminalView {
    private var terminalReady = false
    private var cursorShape: CursorStyle = .steadyBlock
    var viewportChanged: (() -> Void)?
    var pasteStarted: ((Bool) -> Void)?
    var pasteFinished: (() -> Void)?
    override func paste(_ sender: Any?) {
        pasteStarted?(getTerminal().bracketedPasteMode)
        super.paste(sender)
        pasteFinished?()
    }
    /// True while `keepKeyboardDeleteRepeating` writes to SwiftTerm's input buffer: what that sends must not reach the host.
    private(set) var placingKeyboardPlaceholder = false
    private var keyboardPlaceholderQueued = false
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        keepKeyboardDeleteRepeating()
        return accepted
    }
    /// The system keyboard stops repeating a held delete once it sees no text before the cursor, and only what was
    /// typed since the last Enter is in SwiftTerm's input buffer: a held delete on a pasted, recalled or empty line
    /// sent one delete. So, as on Android (`IME_REMOTE_PLACEHOLDER`), spaces stand in for the remote line. They go
    /// before anything typed, and deleting one sends a delete as any other does.
    func keepKeyboardDeleteRepeating() {
        guard isFirstResponder, markedTextRange == nil,
              offset(from: beginningOfDocument, to: endOfDocument) < Self.keyboardPlaceholderMinimum,
              let start = textRange(from: beginningOfDocument, to: beginningOfDocument) else { return }
        placingKeyboardPlaceholder = true
        replace(start, withText: String(repeating: " ", count: Self.keyboardPlaceholderLength))
        placingKeyboardPlaceholder = false
    }
    /// For a caller inside SwiftTerm's own edit, which sets the selection after sending: runs once it has finished.
    func queueKeepKeyboardDeleteRepeating() {
        guard !keyboardPlaceholderQueued else { return }
        keyboardPlaceholderQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.keyboardPlaceholderQueued = false
            self?.keepKeyboardDeleteRepeating()
        }
    }
    private static let keyboardPlaceholderLength = 64
    /// Refilled below this: a repeat takes about 100 ms, so the refill always comes before the buffer runs out.
    private static let keyboardPlaceholderMinimum = 16
    override var contentOffset: CGPoint { didSet { viewportChanged?() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        if terminalReady {
            let terminal = getTerminal()
            terminal.setCursorStyle(cursorShape)
        }
        viewportChanged?()
    }
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        // Android's terminal preserves DECSCUSR shapes without enabling blinking.
        // Apply that same policy after remote style changes and SwiftTerm font resets.
        cursorShape = Self.steadyCursor(newStyle)
        super.cursorStyleChanged(source: source, newStyle: cursorShape)
    }
    private static func steadyCursor(_ style: CursorStyle) -> CursorStyle {
        switch style {
        case .blinkBlock: return .steadyBlock
        case .blinkBar: return .steadyBar
        case .blinkUnderline: return .steadyUnderline
        default: return style
        }
    }
    /// Feeds host output without pulling a reader back. SwiftTerm puts the view at the live bottom on each new line
    /// and each synchronized-output frame, as Claude Code draws, so dragging back through a busy terminal fought
    /// every update. Someone reading back, or with a finger or fling on the view, keeps their place; a view left
    /// at the bottom still follows the output.
    func feedKeepingPlace(_ bytes: ArraySlice<UInt8>) {
        let terminal = getTerminal(), screen = CGFloat(max(1, terminal.rows))
        let rowHeight = getOptimalFrameSize().height / screen
        let reading = rowHeight > 0 && !terminal.isCurrentBufferAlternate
            && (isTracking || isDecelerating || contentOffset.y < contentSize.height - (screen + 0.5) * rowHeight)
        let place = contentOffset.y
        feed(byteArray: bytes); spokenTextStale = true
        if terminal.blankSplitWideCharacters() { terminal.updateFullScreen() }
        let now = ProcessInfo.processInfo.systemUptime
        if let begins = TerminalSynchronizedOutput.lastChange(in: bytes) { frameBegan = begins ? now : nil }
        if !terminal.isCurrentBufferAlternate {
            // A full scrollback drops its oldest lines as new ones arrive and the rest move up a row each.
            let dropped = terminal.droppedScrollbackLines(since: droppedLines, fed: bytes.count)
            undrawnDrops += max(0, dropped - droppedLines); droppedLines = dropped
        }
        guard reading, !terminal.isCurrentBufferAlternate else { undrawnDrops = 0; return }
        // Move up with the text being read, once it is on screen: mid frame, SwiftTerm still shows the old copy.
        var shift = 0
        if frameBegan.map({ now - $0 >= TerminalSynchronizedOutput.timeout }) ?? true { shift = undrawnDrops; undrawnDrops = 0 }
        var target = place - CGFloat(shift) * rowHeight
        // A finger pulling past either end, or the bounce after it, is left to the scroll view.
        if !isTracking && !isDecelerating { target = min(max(0, contentSize.height - bounds.height), max(0, target)) }
        if contentOffset.y != target { contentOffset.y = target }
    }
    /// Scrollback lines SwiftTerm has dropped so far, and those the view has not yet moved up for.
    private var droppedLines = 0, undrawnDrops = 0
    /// When the host's synchronized frame began, while one is open.
    private var frameBegan: TimeInterval?
    override func selectionChanged(source: Terminal) { super.selectionChanged(source: source); viewportChanged?() }
    /// The scroll view's own pan moves local history and cannot be subclassed. It answers as its own delegate, so the
    /// recognizer `TerminalTapRecognizer` describes is let run beside it here.
    @objc(gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:)
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === panGestureRecognizer && other.view !== self && !(other is UIPanGestureRecognizer)
    }
    /// The host hid the cursor (DECTCEM), as Claude Code's and Codex's panels do; it is then parked anywhere.
    private(set) var hostHidCursor = false
    override func showCursor(source: Terminal) { hostHidCursor = false; super.showCursor(source: source) }
    override func hideCursor(source: Terminal) { hostHidCursor = true; super.hideCursor(source: source) }
    override func mouseModeChanged(source: Terminal) {
        // SwiftTerm's implementation adds a button-drag recognizer even with
        // allowMouseReporting=false. Only our vertical wheel recognizer reports
        // mouse input; native long-press selection must remain local.
        viewportChanged?()
    }
    deinit { TerminalCensus.change(-1) }
    override init(frame: CGRect) {
        TerminalCensus.change(1)
        super.init(frame: frame); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"; accessibilityTraits = [.updatesFrequently]
    }
    required init?(coder: NSCoder) {
        TerminalCensus.change(1)
        super.init(coder: coder); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"
    }
    /// The text VoiceOver and UI tests read. Export only the needed tail rows, and rebuild
    /// only after output, at most twice a second, as `.updatesFrequently` requests it often.
    private var spokenText: (text: String, at: TimeInterval)?
    private var spokenTextStale = true
    override var accessibilityValue: String? {
        get {
            let now = ProcessInfo.processInfo.systemUptime
            if let spokenText, !spokenTextStale || now - spokenText.at < 0.5 { return spokenText.text }
            let text = String(decoding: getTerminal().getBufferTailAsData(maxBytes: 16_384), as: UTF8.self)
            spokenText = (text, now); spokenTextStale = false
            return text
        }
        set { }
    }
}

extension TerminalView {
    /// Back to the live bottom before input the app sends itself. SwiftTerm's `scroll(toPosition: 1)` only moves the
    /// terminal's own viewport, which stays at the bottom while the view is dragged back through its history.
    func scrollToLiveOutput() {
        scroll(toPosition: 1)
        contentOffset.y = max(0, contentSize.height - bounds.height)
    }
}

/// How many terminal views are alive, for the diagnostics log: more than the open sessions means some leaked.
enum TerminalCensus {
    private static let lock = NSLock()
    private static var count = 0
    static var live: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func change(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
}

/// The terminal's own taps. Once a line has been typed, iOS 26 and later leave a text recognizer
/// (UIPhraseBoundaryGestureRecognizer) on a view it adds inside the terminal, seen on phones and not on the simulator.
/// It begins on every later touch and wins it, keyboard up or not, until the terminal leaves the screen: a tap could
/// no longer bring the keyboard back. Only recognizers on the terminal view itself may prevent these.
@MainActor final class TerminalTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { preventing.view === view }
}
/// The terminal's swipes, safe from the same recognizer: it left a terminal that could not be scrolled after typing.
@MainActor final class TerminalPanRecognizer: UIPanGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { preventing.view === view }
}
/// The terminal's pinch, safe from the same recognizer.
@MainActor final class TerminalPinchRecognizer: UIPinchGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { preventing.view === view }
}

/// Observes the initial workspace press without recognizing or consuming a gesture.
@MainActor final class TerminalTouchObserver: UIGestureRecognizer {
    let touched: () -> Void
    init(touched: @escaping () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touched(); state = .failed }
}
