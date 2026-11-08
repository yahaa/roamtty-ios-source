import UIKit
import SwiftTerm
import RoamttyCore

/// A vertical swipe carried on after the finger lifts; see `TerminalScrollInertia`.
struct ScrollFling {
    var inertia: TerminalScrollInertia
    let start: CFTimeInterval
    let point: CGPoint
    /// The connection it started on; a fling stops with it.
    let generation: UUID
    let disposition: TerminalScrollDisposition
}

/// A row change sent by a tap on a multi-line input, waiting for the app to echo the cursor onto `row`.
struct PendingCursorTap {
    let row: Int
    let column: Int
    let deadline: CFTimeInterval
    /// The connection it was sent on; a reconnect drops it.
    let generation: UUID
}

/// Android's terminal gestures: taps place the cursor, complete or paste; a sideways swipe sends arrows; a vertical
/// swipe scrolls the host's screen; a pinch zooms the font.
extension SessionRuntime: UIGestureRecognizerDelegate {
    func installGestures() {
        // Keep SwiftTerm's native single tap solely for dismissing an intentional selection.
        // Its long press and selection handles remain installed; normal taps use Android's rules.
        for recognizer in terminalView.gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer else { continue }
            if tap.numberOfTapsRequired == 1 { selectionTap = tap; tap.delegate = self } else { tap.isEnabled = false }
        }
        let single = TerminalTapRecognizer(target: self, action: #selector(cursorTap(_:)))
        let double = TerminalTapRecognizer(target: self, action: #selector(completionTap(_:)))
        let triple = TerminalTapRecognizer(target: self, action: #selector(pasteTap(_:)))
        double.numberOfTapsRequired = 2; triple.numberOfTapsRequired = 3
        single.require(toFail: double); double.require(toFail: triple)
        for tap in [single, double, triple] { tap.delegate = self; terminalView.addGestureRecognizer(tap) }
        let touchObserver = TerminalTouchObserver { [weak self] in
            self?.workspaceTouches += 1; self?.inputGestureHadPinch = false; self?.stopScrollInertia()
        }
        terminalView.addGestureRecognizer(touchObserver)
        let swipe = TerminalPanRecognizer(target: self, action: #selector(horizontalSwipe(_:)))
        swipe.minimumNumberOfTouches = 1; swipe.maximumNumberOfTouches = 1; swipe.delegate = self
        horizontalPan = swipe; terminalView.addGestureRecognizer(swipe)
        terminalView.panGestureRecognizer.require(toFail: swipe)
        let scroll = TerminalPanRecognizer(target: self, action: #selector(verticalScroll(_:)))
        scroll.minimumNumberOfTouches = 1; scroll.maximumNumberOfTouches = 1; scroll.delegate = self
        verticalPan = scroll; terminalView.addGestureRecognizer(scroll)
        terminalView.panGestureRecognizer.require(toFail: scroll)
        let pinch = TerminalPinchRecognizer(target: self, action: #selector(pinchFont(_:)))
        terminalView.addGestureRecognizer(pinch)
        // The link under a finger is captured at touch down: output may move or replace its row before the tap.
        let press = TerminalTouchTracker(began: { [weak self] point in
            guard let self else { return }
            self.linkPress.press(self.terminalView.selectionActive ? nil : self.link(at: point)?.spans ?? self.path(at: point)?.spans)
        }, moved: { [weak self] in self?.linkPress.clear() }, ended: { [weak self] in self?.linkPress.lift() })
        press.delegate = self
        terminalView.addGestureRecognizer(press)
        ownRecognizers = [single, double, triple, touchObserver, swipe, scroll, pinch, press]
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === selectionTap { return terminalView.selectionActive }
        return !terminalView.selectionActive
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === horizontalPan, let pan = horizontalPan {
            let movement = pan.translation(in: terminalView)
            return !inputGestureHadPinch && writableViewport && abs(movement.x) > 1.5 * abs(movement.y)
        }
        if gestureRecognizer === verticalPan, let pan = verticalPan {
            let movement = pan.translation(in: terminalView), disposition = scrollDisposition
            return !inputGestureHadPinch && (disposition == .wheel || disposition == .arrows) && abs(movement.x) <= 1.5 * abs(movement.y)
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A recognizer on another view, such as iOS's leftover text recognizer, never holds up its taps.
        if gestureRecognizer is TerminalTapRecognizer && otherGestureRecognizer.view !== terminalView { return true }
        // The press tracker only watches; it never holds up another gesture.
        if gestureRecognizer is TerminalTouchTracker || otherGestureRecognizer is TerminalTouchTracker { return true }
        let isPan = gestureRecognizer === horizontalPan || gestureRecognizer === verticalPan
        return isPan && otherGestureRecognizer is UIPinchGestureRecognizer
    }

    // MARK: Geometry

    /// Input typed now lands at the live cursor: connected, nothing selected, scrolled to the bottom.
    private var writableViewport: Bool { phase == .connected && !terminalView.selectionActive && (!terminalView.canScroll || terminalView.scrollPosition >= 1) }
    private var scrollDisposition: TerminalScrollDisposition {
        let terminal = terminalView.getTerminal()
        return TerminalScrolling.disposition(connected: phase == .connected, selecting: terminalView.selectionActive,
                                             mouseTracking: terminal.mouseMode != .off, alternate: terminal.isCurrentBufferAlternate)
    }
    private var cellSize: CGSize {
        let terminal = terminalView.getTerminal(), optimal = terminalView.getOptimalFrameSize()
        return CGSize(width: optimal.width / CGFloat(max(1, terminal.cols)), height: optimal.height / CGFloat(max(1, terminal.rows)))
    }

    // MARK: Vertical scrolling

    @objc private func verticalScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: scrollGeneration = generation; scrollAccumulator.reset(); stopScrollInertia()
        case .changed: break
        case .ended:
            defer { scrollGeneration = nil; scrollAccumulator.reset() }
            guard !inputGestureHadPinch, scrollGeneration == generation else { return }
            startScrollInertia(velocityY: recognizer.velocity(in: terminalView).y, at: recognizer.location(in: terminalView))
            return
        case .cancelled, .failed: scrollGeneration = nil; scrollAccumulator.reset(); return
        default: return
        }
        guard !inputGestureHadPinch, scrollGeneration == generation, recognizer.numberOfTouches == 1 else { scrollGeneration = nil; return }
        let disposition = scrollDisposition
        guard disposition == .wheel || disposition == .arrows else { scrollGeneration = nil; return }
        let rows = scrollAccumulator.rowsDown(translationY: recognizer.translation(in: terminalView).y, rowHeight: cellSize.height)
        scrollRemotely(rows: rows, disposition: disposition, at: recognizer.location(in: terminalView))
    }
    /// Scrolls the host's screen: arrow keys for a full-screen app without mouse support, else mouse wheel events. A
    /// lost scroll is not lost input and the next frame of the swipe tries again, so it raises no notice.
    private func scrollRemotely(rows: Int, disposition: TerminalScrollDisposition, at position: CGPoint) {
        guard rows != 0 else { return }
        let terminal = terminalView.getTerminal()
        if disposition == .arrows {
            let key = TerminalKeys.arrow(rows < 0 ? "A" : "B", applicationCursor: terminal.applicationCursor, control: false, shift: false)
            send(Data(String(repeating: key, count: abs(rows)).utf8), reportFailure: false)
        } else {
            let cell = cellSize
            let point = TerminalScrolling.mousePoint(CGPoint(x: position.x - terminalView.contentOffset.x, y: position.y - terminalView.contentOffset.y),
                cell: cell, columns: terminal.cols, rows: terminal.rows)
            let flags = terminal.encodeButton(button: TerminalScrolling.mouseButton(rowsDown: rows), release: false, shift: false, meta: false, control: false)
            // One write however many rows: mosh allows 64 writes until the server acknowledges them, and a fast swipe
            // used to spend a write per row, losing the rest of the swipe and whatever was typed next.
            scrollEventBytes = Data()
            for _ in 0..<abs(rows) {
                terminal.sendEvent(buttonFlags: flags, x: point.column, y: point.row, pixelX: point.pixelX, pixelY: point.pixelY)
            }
            if let bytes = scrollEventBytes { send(bytes, reportFailure: false) }
            scrollEventBytes = nil
        }
    }
    /// A finger moving up scrolls down, so the fling runs against the touch velocity.
    private func startScrollInertia(velocityY: CGFloat, at position: CGPoint) {
        stopScrollInertia()
        let disposition = scrollDisposition, rowHeight = cellSize.height
        guard disposition == .wheel || disposition == .arrows, rowHeight > 0,
              let inertia = TerminalScrollInertia(rowsPerSecond: -Double(velocityY / rowHeight), screenRows: terminalView.getTerminal().rows) else { return }
        fling = ScrollFling(inertia: inertia, start: CACurrentMediaTime(), point: position, generation: generation, disposition: disposition)
        let link = CADisplayLink(target: self, selector: #selector(stepScrollInertia(_:)))
        link.add(to: .main, forMode: .common); flingLink = link
    }
    @objc private func stepScrollInertia(_ link: CADisplayLink) {
        // Like Android, a fling stops once the session or the host's scrolling mode changes under it.
        guard var current = fling, current.generation == generation, scrollDisposition == current.disposition else { stopScrollInertia(); return }
        let rows = current.inertia.rowsDown(after: link.targetTimestamp - current.start)
        fling = current
        scrollRemotely(rows: rows, disposition: current.disposition, at: current.point)
        if current.inertia.finished { stopScrollInertia() }
    }
    func stopScrollInertia() {
        flingLink?.invalidate(); flingLink = nil
        fling = nil
    }

    // MARK: Sideways swipes

    @objc private func horizontalSwipe(_ recognizer: UIPanGestureRecognizer) {
        let movement = recognizer.translation(in: terminalView)
        switch recognizer.state {
        case .began:
            swipeGeneration = generation; swipeHeld = false; swipeHoldPosition = nil
            trackSwipeHold(recognizer, movement: movement)
        case .changed: trackSwipeHold(recognizer, movement: movement)
        case .ended:
            swipeHold?.cancel(); swipeHold = nil
            defer { swipeGeneration = nil; swipeHoldPosition = nil; swipeHeld = false }
            guard !inputGestureHadPinch, swipeGeneration == generation, writableViewport, !swipeHeld,
                  let direction = TerminalKeys.swipeDirection(x: movement.x, y: movement.y) else { return }
            let input = TerminalKeys.arrow(direction < 0 ? "D" : "C", applicationCursor: terminalView.getTerminal().applicationCursor, control: controlArmed, shift: shiftArmed)
            clearModifiers(); send(input)
        case .cancelled, .failed:
            swipeHold?.cancel(); swipeHold = nil; swipeGeneration = nil; swipeHoldPosition = nil
        default: break
        }
    }
    /// Holding a sideways swipe for half a second jumps to the line's start or end (Ctrl-A / Ctrl-E).
    private func trackSwipeHold(_ recognizer: UIPanGestureRecognizer, movement: CGPoint) {
        guard !swipeHeld else { return }
        guard writableViewport, TerminalKeys.swipeDirection(x: movement.x, y: movement.y) != nil else { swipeHold?.cancel(); swipeHold = nil; swipeHoldPosition = nil; return }
        if let previous = swipeHoldPosition, abs(previous.x - movement.x) <= 8, abs(previous.y - movement.y) <= 8 { return }
        swipeHoldPosition = movement; swipeHold?.cancel()
        let token = generation
        swipeHold = Task { [weak self, weak recognizer] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self, let recognizer, self.generation == token, self.swipeGeneration == token, self.writableViewport,
                      recognizer.state == .began || recognizer.state == .changed else { return }
                let point = recognizer.translation(in: self.terminalView)
                guard let direction = TerminalKeys.swipeDirection(x: point.x, y: point.y) else { return }
                self.swipeHeld = true; self.clearModifiers(); self.send(direction < 0 ? "\u{1}" : "\u{5}")
            } catch { }
        }
    }

    // MARK: Taps

    @objc private func cursorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: terminalView)
        if let link = link(at: point) { linkPress.confirm(); open(link.url); return }
        if let path = path(at: point) { linkPress.confirm(); openPath(path, tappedAt: point); return }
        linkPress.clear()
        plainTap(at: point)
    }
    /// What a tap on anything but a link does: places the cursor, and shows or hides the keyboard.
    private func plainTap(at point: CGPoint) {
        pendingCursorTap = nil
        guard phase == .connected else { return }
        (SwiftTermMenu() as SwiftTermEditMenu).hide()
        refreshCursor()
        // A panel such as /usage hides the cursor and parks it away from the line typed on, even off screen: with
        // no cursor to aim at, any tap brings the keyboard back.
        if (terminalView as? AccessibleTerminalView)?.hostHidCursor == true && !terminalView.isFirstResponder {
            keyboardHide?.cancel(); _ = terminalView.becomeFirstResponder(); return
        }
        let movedCursor = moveCursor(toTap: point)
        guard let row = cursorRowBounds else { return }
        // The user now decides about the keyboard: an earlier Enter's delayed hide must not undo it.
        keyboardHide?.cancel()
        let y = point.y - terminalView.contentOffset.y
        // A tap into the input box, however far from the cursor, is typing there.
        if movedCursor || TerminalCursorControls.tapHitsCursor(y: y, rowTop: row.minY, rowHeight: row.height, viewportHeight: terminalView.bounds.height) { _ = terminalView.becomeFirstResponder() }
        // iPhone keyboards have no dismiss key and there is no Back button: a reading tap elsewhere puts it away.
        else if terminalView.isFirstResponder { _ = terminalView.resignFirstResponder() }
    }
    /// Like tapping into a text field, a tap on typed text moves the cursor there with arrow keys; see
    /// `TerminalCursorTap`. Returns whether the tap landed on the input.
    private func moveCursor(toTap point: CGPoint) -> Bool {
        let cell = cellSize
        let x = point.x - terminalView.contentOffset.x, y = point.y - terminalView.contentOffset.y
        guard writableViewport, (terminalView as? AccessibleTerminalView)?.hostHidCursor != true,
              cell.width > 0, cell.height > 0, x >= 0, y >= 0 else { return false }
        let terminal = terminalView.getTerminal(), cursor = terminal.getCursorLocation()
        let column = Int((x / cell.width).rounded()), row = Int(y / cell.height)
        switch TerminalCursorTap.move(SwiftTermTextGrid(terminal: terminal), cursorColumn: cursor.x, cursorRow: cursor.y, column: column, row: row) {
        case nil: return false
        case .along(let steps)?: sendArrows(steps, negative: "D", positive: "C")
        case .rows(let rows)?:
            sendArrows(rows, negative: "A", positive: "B")
            pendingCursorTap = PendingCursorTap(row: row, column: column, deadline: CACurrentMediaTime() + TerminalCursorTap.echoTimeout, generation: generation)
        }
        return true
    }
    /// Finishes a pending row change once the app has drawn the cursor on the tapped row.
    func finishCursorTap() {
        guard let pending = pendingCursorTap else { return }
        guard pending.generation == generation, writableViewport, (terminalView as? AccessibleTerminalView)?.hostHidCursor != true,
              CACurrentMediaTime() <= pending.deadline else { pendingCursorTap = nil; return }
        let terminal = terminalView.getTerminal(), cursor = terminal.getCursorLocation()
        guard cursor.y == pending.row else { return }
        pendingCursorTap = nil
        let steps = TerminalCursorTap.steps(SwiftTermTextGrid(terminal: terminal), cursorColumn: cursor.x, cursorRow: cursor.y, column: pending.column)
        sendArrows(steps, negative: "D", positive: "C")
    }
    private func sendArrows(_ count: Int, negative: String, positive: String) {
        guard count != 0 else { return }
        let key = TerminalKeys.arrow(count < 0 ? negative : positive, applicationCursor: terminalView.getTerminal().applicationCursor, control: false, shift: false)
        _ = send(String(repeating: key, count: abs(count)))
    }
    @objc private func completionTap(_ recognizer: UITapGestureRecognizer) {
        linkPress.clear()
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers()
        if send("\t") { wakeCursor(); petArrowTouches += 1 }
    }
    @objc private func pasteTap(_ recognizer: UITapGestureRecognizer) {
        linkPress.clear()
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers(); paste()
    }
    /// The complete HTTP(S) URL under a tap, including soft and TUI hard wraps and scrolled history.
    private func link(at point: CGPoint) -> TerminalWebLink? {
        let cell = cellSize
        let x = point.x - terminalView.contentOffset.x, y = point.y - terminalView.contentOffset.y
        guard cell.width > 0, cell.height > 0, x >= 0, y >= 0 else { return nil }
        return TerminalUrl.link(SwiftTermTextGrid(terminal: terminalView.getTerminal()), column: Int(x / cell.width), row: Int(y / cell.height))
    }
    /// A file path under a tap, as compilers, grep and coding agents print it. Paths on the live cursor's line are the
    /// command being typed: a tap there moves the cursor as before.
    private func path(at point: CGPoint) -> TerminalPathLink? {
        let cell = cellSize
        let x = point.x - terminalView.contentOffset.x, y = point.y - terminalView.contentOffset.y
        guard phase == .connected, onOpenPath != nil, cell.width > 0, cell.height > 0, x >= 0, y >= 0 else { return nil }
        let terminal = terminalView.getTerminal()
        guard let path = TerminalPath.at(SwiftTermTextGrid(terminal: terminal), column: Int(x / cell.width), row: Int(y / cell.height)) else { return nil }
        if writableViewport, (terminalView as? AccessibleTerminalView)?.hostHidCursor != true, path.covers(row: terminal.getCursorLocation().y) { return nil }
        return path
    }
    /// Opens the first of a tapped path's candidates that names a file, at its line; when none does, the tap does what
    /// a tap elsewhere does.
    private func openPath(_ path: TerminalPathLink, tappedAt point: CGPoint) {
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let file = await self.terminalFile(path.candidates)
            guard self.generation == token, self.phase == .connected else { return }
            if let file, let open = self.onOpenPath { open(file.path, file.line) } else { self.plainTap(at: point) }
        }
    }
    /// The first candidate that names a file on the host (not a folder), resolved from the shell's folder when it is
    /// relative; nil when none does or the host takes longer than `pathLookupTimeout` to say.
    func terminalFile(_ candidates: [TerminalPathCandidate]) async -> TerminalPathCandidate? {
        // A task group would wait for a lookup stuck on the network; whichever answers first is taken instead.
        final class Answer { var given = false }
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let file = await self.lookUpTerminalFile(candidates)
                if !answer.given { answer.given = true; continuation.resume(returning: file) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.pathLookupTimeout))
                if !answer.given { answer.given = true; continuation.resume(returning: nil) }
            }
        }
    }
    /// Android waits 8 s. A tap on a path that names no file only places the cursor once this is up, so a slow host
    /// would leave the tap without an answer that long; a first lookup that opens SFTP takes about a second.
    static let pathLookupTimeout: Double = 3
    private func lookUpTerminalFile(_ candidates: [TerminalPathCandidate]) async -> TerminalPathCandidate? {
        guard let ssh = await sideConnection() else { return nil }
        let cancellation = lifetimeCancellation
        var directory: String?, home: String?
        for candidate in candidates {
            // Absolute and home paths need no round trip for the shell's folder.
            var resolved = resolveTerminalPath(directory: nil, path: candidate.path)
            // A home path is shown by its full path, so a Markdown file's relative images resolve from its folder.
            if let relative = resolved, candidate.path.hasPrefix("~/") {
                if home == nil { home = validWorkingDirectory((try? await ssh.run("printf '%s' \"$HOME\"", timeout: 5, cancellation: cancellation))?.text) ?? "" }
                if let home, !home.isEmpty { resolved = joinRemotePath(directory: home, name: relative) }
            }
            if resolved == nil {
                if directory == nil { directory = await workingDirectory() }
                resolved = resolveTerminalPath(directory: directory, path: candidate.path)
            }
            guard let resolved, !Task.isCancelled else { continue }
            if (try? await performInBackground({ try ssh.isDirectory(resolved, cancellation: cancellation) })) == false {
                return TerminalPathCandidate(path: resolved, line: candidate.line)
            }
        }
        return nil
    }
    /// iOS hands GitHub and other universal links to their app when it is installed, else to the browser.
    private func open(_ link: String) {
        if let loopback = LoopbackUrl.parse(link), let open = onOpenLoopback { open(loopback); return }
        guard let url = terminalLinkTarget(link) else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened { self?.message = "无法打开链接：\(link) / Cannot open link: \(link)" }
        }
    }

    // MARK: Pinch

    @objc private func pinchFont(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { linkPress.clear(); inputGestureHadPinch = true; scrollGeneration = nil; stopScrollInertia(); swipeGeneration = nil; swipeHold?.cancel(); swipeHold = nil }
        if recognizer.state == .ended { onFontScaled?(Double(terminalView.font.pointSize.rounded())); return }
        guard recognizer.state == .changed else { return }
        let size = min(28, max(8, terminalView.font.pointSize * recognizer.scale))
        terminalView.font = terminalView.font.withSize(size); recognizer.scale = 1
        queueCursorRefresh()
    }
}

/// SwiftTerm 1.13 shows its copy and paste menu through `UIMenuController`, so only that API can close it. The call
/// goes through a protocol so that iOS 16's deprecation does not warn on every build.
private protocol SwiftTermEditMenu { func hide() }
private struct SwiftTermMenu: SwiftTermEditMenu {
    @available(iOS, deprecated: 16.0)
    func hide() { UIMenuController.shared.hideMenu() }
}
