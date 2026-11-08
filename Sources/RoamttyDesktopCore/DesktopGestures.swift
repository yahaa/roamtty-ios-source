import Foundation

/// The remote screen inside the view: fitted with letterboxing, then zoomed and panned locally.
/// Zoom never reaches the host; coordinates always come out in the display's native pixels.
/// Port of Android `desktop-core/DesktopGestures.kt` (roamtty #218). Sizes are view points on iOS
/// (Android uses pixels with a density; pass `density: 1` to `DesktopGestures` for points).
public struct Viewport: Equatable, Sendable {
    public var viewWidth: Float, viewHeight: Float
    public var remoteWidth: Int, remoteHeight: Int
    public var zoom: Float = 1, panX: Float = 0, panY: Float = 0

    public static let MAX_ZOOM: Float = 5

    public init(viewWidth: Float, viewHeight: Float, remoteWidth: Int, remoteHeight: Int, zoom: Float = 1, panX: Float = 0, panY: Float = 0) {
        self.viewWidth = viewWidth; self.viewHeight = viewHeight; self.remoteWidth = remoteWidth; self.remoteHeight = remoteHeight
        self.zoom = zoom; self.panX = panX; self.panY = panY
    }

    /// View pixels per native pixel at zoom 1.
    public var baseScale: Float {
        remoteWidth <= 0 || remoteHeight <= 0 ? 1 : min(viewWidth / Float(remoteWidth), viewHeight / Float(remoteHeight))
    }
    public var scale: Float { baseScale * zoom }
    public var contentWidth: Float { Float(remoteWidth) * scale }
    public var contentHeight: Float { Float(remoteHeight) * scale }
    /// Top-left of the content in the view.
    public var left: Float { (viewWidth - contentWidth) / 2 + panX }
    public var top: Float { (viewHeight - contentHeight) / 2 + panY }

    public func toRemote(_ x: Float, _ y: Float) -> (x: Int, y: Int) {
        (clampInt((x - left) / scale, max(0, remoteWidth - 1)), clampInt((y - top) / scale, max(0, remoteHeight - 1)))
    }

    public func contains(_ x: Float, _ y: Float) -> Bool { x >= left && y >= top && x < left + contentWidth && y < top + contentHeight }

    public func toView(_ rx: Float, _ ry: Float) -> (x: Float, y: Float) { (left + rx * scale, top + ry * scale) }

    /// Keeps the zoomed content covering the view where it can, and centred where it cannot.
    public func clamped() -> Viewport {
        func limit(_ content: Float, _ view: Float, _ pan: Float) -> Float {
            if content <= view { return 0 }
            let slack = (content - view) / 2
            return min(max(pan, -slack), slack)
        }
        var v = self
        v.panX = limit(contentWidth, viewWidth, panX)
        v.panY = limit(contentHeight, viewHeight, panY)
        return v
    }

    public func panned(_ dx: Float, _ dy: Float) -> Viewport {
        var v = self; v.panX += dx; v.panY += dy
        return v.clamped()
    }

    /// Zooms by `factor` keeping the point under (`fx`, `fy`) where it is.
    public func zoomed(_ factor: Float, _ fx: Float, _ fy: Float) -> Viewport {
        let next = min(max(zoom * factor, 1), Viewport.MAX_ZOOM)
        let ratio = next / zoom
        // The focus stays put: its offset from the view centre plus pan scales with the zoom.
        let cx = viewWidth / 2
        let cy = viewHeight / 2
        var v = self
        v.zoom = next
        v.panX = fx - cx - (fx - cx - panX) * ratio
        v.panY = fy - cy - (fy - cy - panY) * ratio
        return v.clamped()
    }
}

/// Kotlin's `toInt().coerceIn(0, hi)`: truncates toward zero, NaN as 0.
private func clampInt(_ v: Float, _ hi: Int) -> Int {
    let i: Int = v.isNaN ? 0 : v >= Float(Int32.max) ? Int(Int32.max) : v <= Float(Int32.min) ? Int(Int32.min) : Int(v)
    return min(max(i, 0), hi)
}

private func hypot(_ x: Float, _ y: Float) -> Float { (x * x + y * y).squareRoot() }

public enum PointerMode: Sendable { case touch, mouse }

public enum SwipeDirection: Sendable, Equatable { case up, down, left, right }

/// What the phone should feel or show, never sent to the host.
public enum GestureFeedback: Sendable, Equatable {
    /// A hold was recognised: lift for a right click, or move to drag.
    case hold
    /// A held finger started a drag: the button went down.
    case pickup
    /// A click that needed a hold or a second finger (right, middle).
    case click
    /// A three-finger swipe, an edge swipe or a smart zoom.
    case shortcut
}

/// What a gesture asks for: remote input, a local change to the viewport, or feedback.
public enum GestureAction: Equatable, Sendable {
    case moveTo(x: Int, y: Int)
    /// 1 left, 2 right, 3 middle.
    case button(Int, down: Bool)
    /// 1/120 of a notch; positive `dy` scrolls up.
    case wheel(dx: Int, dy: Int)
    case view(Viewport)
    /// Three fingers swiped: the page turns it into the host's shortcut.
    case swipe(SwipeDirection)
    case feedback(GestureFeedback)
}

/// A hold in progress, for the ring the page draws under the fingers (view points).
public struct HoldIndicator: Equatable, Sendable {
    public let x: Float, y: Float
    public let fingers: Int
    /// False while waiting for the hold, true once it fired.
    public let armed: Bool
    /// When the hold fires, while waiting for it.
    public let firesAt: Int64
}

/// Touches to desktop input, after Apple's trackpad (docs/DESKTOP-GESTURES.md). The number of fingers
/// is the mouse button: one is left, two right, three middle. Taps act at once; holding a finger
/// (two for the right button) until the ring fills picks it up: lift to click with that button, or
/// move to drag. Two fingers scroll the host, with inertia; pinching zooms the picture locally.
/// `.mouse` is trackpad mode: one finger moves the cursor, with acceleration, and clicks act where it
/// is. `.touch` is direct touch, as on a phone: taps and holds act where the finger is, and a slide
/// scrolls what is under it, with inertia (zoomed in, it moves the picture first, then scrolls past its edge).
/// The cursor is the phone's: moves go out as absolute positions, so the host adds no acceleration
/// of its own and the cursor drawn here is where the host's is. Times are milliseconds.
public final class DesktopGestures {
    public static let HOLD_MS: Int64 = 350
    /// Two fingers rest a moment before scrolling, so their hold is longer.
    public static let HOLD2_MS: Int64 = 500
    public static let DOUBLE_TAP_MS: Int64 = 300
    /// A multi-finger tap lifts within this.
    public static let TAP_MS: Int64 = 350
    /// Inertia frames.
    public static let FRAME_MS: Int64 = 16
    /// UIScrollView's normal deceleration, per millisecond.
    public static let DECELERATION: Float = 0.998

    public var mode: PointerMode
    private let density: Float
    public var viewport = Viewport(viewWidth: 1, viewHeight: 1, remoteWidth: 1, remoteHeight: 1)
    /// Movement under this (view points) is still a tap or a hold.
    private let slop: Float
    private var doubleTapRadius: Float { 20 * density }
    private var edgeZone: Float { 16 * density }

    /// The phone's cursor in native pixels: where the last move put it, or where the host said.
    public private(set) var cursorX: Float = 0, cursorY: Float = 0
    public private(set) var hasCursor = false
    private var lastLocalMoveAt: Int64 = .min / 2
    /// The time of the event being handled.
    private var now: Int64 = 0
    public private(set) var indicator: HoldIndicator?

    private struct Finger { var x: Float, y: Float, startX: Float, startY: Float }
    private var fingers: [Int: Finger] = [:]
    /// Finger ids in landing order: multi-finger gestures use the first ones.
    private var order: [Int] = []

    private enum Phase {
        case idle
        case pending, moving, holdArmed, dragging, edgeDone
        case pending2, scroll, pinch, hold2Armed, rightDrag
        case pending3, swiped
        case spent
    }
    private var phase = Phase.idle
    private var peak = 0
    private var startedAt: Int64 = 0
    private var downX: Float = 0, downY: Float = 0
    /// Whether every finger stayed within the slop so far.
    private var still = true
    private var holdAt: Int64?
    private var edge: (left: Bool, right: Bool, top: Bool, bottom: Bool)?
    /// Multi-finger centroid where the count last changed, and on the last move.
    private var anchorX: Float = 0, anchorY: Float = 0, anchorSpan: Float = 0
    private var lastX: Float = 0, lastY: Float = 0, lastSpan: Float = 0
    private var lastMoveAt: Int64 = 0
    /// Smoothed velocity of the finger or centroid, points per millisecond.
    private var vx: Float = 0, vy: Float = 0
    private var wheelX: Float = 0, wheelY: Float = 0
    /// Touch mode: the last tap, so a second one nearby lands on the same pixel.
    private var lastTap: LastTap?
    private struct LastTap { let x: Float, y: Float, rx: Int, ry: Int, at: Int64 }
    /// A two-finger tap's right click waits a moment for a second tap, which zooms instead.
    private var pendingRight: (at: Int64, x: Float, y: Float)?
    /// `panFirst`: a one-finger flick in touch mode, which moves a zoomed picture before scrolling.
    private var inertia: (vx: Float, vy: Float, at: Int64, panFirst: Bool)?
    /// Touch mode: dragging near the edge of a zoomed picture moves it; when the last frame was.
    private var autoPanAt: Int64?

    public init(mode: PointerMode = .touch, density: Float = 1) {
        self.mode = mode
        self.density = density
        slop = 10 * density
    }

    /// When `tick` next needs calling; nil when nothing is pending.
    public var tickAt: Int64? {
        [holdAt, pendingRight?.at, inertia.map { $0.at + Self.FRAME_MS }, autoPanAt.map { $0 + Self.FRAME_MS }].compactMap { $0 }.min()
    }

    /// The host's cursor. While the phone moved it lately, the phone's own position stands.
    public func hostCursor(x: Int, y: Int, time: Int64) {
        if !hasCursor || time - lastLocalMoveAt > 500 {
            cursorX = Float(x); cursorY = Float(y); hasCursor = true
        }
    }

    // MARK: Touches

    public func began(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        now = time
        var out: [GestureAction] = []
        inertia = nil
        fingers[id] = Finger(x: x, y: y, startX: x, startY: y)
        order.removeAll { $0 == id }
        order.append(id)
        let n = fingers.count
        peak = max(peak, n)
        switch n {
        case 1:
            phase = .pending; peak = 1; startedAt = time; still = true
            downX = x; downY = y; lastX = x; lastY = y; lastMoveAt = time; vx = 0; vy = 0
            holdAt = time + Self.HOLD_MS
            edge = edgeOf(x, y)
            indicator = HoldIndicator(x: x, y: y, fingers: 1, armed: false, firesAt: time + Self.HOLD_MS)
        case 2:
            switch phase {
            case .pending, .moving:
                phase = .pending2
                let c = centroid(2)
                anchorX = c.x; anchorY = c.y; anchorSpan = c.span; lastX = c.x; lastY = c.y; lastSpan = c.span
                lastMoveAt = time; vx = 0; vy = 0; wheelX = 0; wheelY = 0
                holdAt = time + Self.HOLD2_MS
                indicator = HoldIndicator(x: c.x, y: c.y, fingers: 2, armed: false, firesAt: time + Self.HOLD2_MS)
            default:
                out += endOneFinger()
            }
        case 3:
            switch phase {
            case .pending2:
                flushRight(&out)
                phase = .pending3
                let c = centroid(3)
                anchorX = c.x; anchorY = c.y; holdAt = nil; indicator = nil
            case .scroll, .pinch:
                break // a third finger brushing the glass: the first two carry on
            default:
                out += endOneFinger() + endTwoFinger()
            }
        default:
            out += endOneFinger() + endTwoFinger()
        }
        return out
    }

    public func moved(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        moved([(id, x, y)], time: time)
    }

    /// All the fingers that moved in one event.
    public func moved(_ touches: [(id: Int, x: Float, y: Float)], time: Int64) -> [GestureAction] {
        now = time
        for t in touches {
            guard var f = fingers[t.id] else { continue }
            f.x = t.x; f.y = t.y
            fingers[t.id] = f
            if hypot(f.x - f.startX, f.y - f.startY) >= slop { still = false }
        }
        guard !fingers.isEmpty else { return [] }
        var out: [GestureAction] = []
        switch phase {
        case .pending, .moving, .holdArmed, .dragging:
            guard let id = order.first, let f = fingers[id] else { return [] }
            out = moveOne(f.x, f.y, time: time)
        case .pending2, .scroll, .pinch, .hold2Armed, .rightDrag:
            guard fingers.count >= 2 else { return [] }
            out = moveTwo(time: time)
        case .pending3:
            guard fingers.count >= 3 else { return [] }
            let c = centroid(3)
            let dx = c.x - anchorX, dy = c.y - anchorY
            if hypot(dx, dy) >= 40 * density {
                phase = .swiped
                let dir: SwipeDirection = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
                out = [.swipe(dir), .feedback(.shortcut)]
            }
        default:
            break
        }
        return out
    }

    public func ended(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        guard let f = fingers[id] else { return [] }
        now = time
        if hypot(x - f.startX, y - f.startY) >= slop { still = false }
        fingers[id] = nil
        order.removeAll { $0 == id }
        let n = fingers.count
        var out: [GestureAction] = []
        if n < 2 {
            switch phase {
            case .scroll:
                // A pause before lifting leaves nothing to carry on.
                let speed = time - lastMoveAt > 60 ? 0 : hypot(vx, vy)
                if speed > 0.05 { inertia = (vx, vy, time, false) }
                phase = .spent
            case .pinch:
                phase = .spent
            case .hold2Armed:
                out += rightClick(anchorX, anchorY)
                phase = .spent
            case .rightDrag:
                out.append(.button(2, down: false))
                phase = .spent
            default:
                break
            }
        }
        if n == 0 { out += finish(time: time) }
        return out
    }

    /// The touches were taken away, or the screen is going: nothing may stay pressed.
    public func cancel() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .dragging { out.append(.button(1, down: false)) }
        if phase == .rightDrag { out.append(.button(2, down: false)) }
        fingers.removeAll(); order.removeAll()
        phase = .idle; peak = 0; holdAt = nil; indicator = nil; pendingRight = nil; inertia = nil; autoPanAt = nil
        return out
    }

    public func tick(_ time: Int64) -> [GestureAction] {
        now = time
        var out: [GestureAction] = []
        if let p = pendingRight, time >= p.at { flushRight(&out) }
        if let at = holdAt, time >= at {
            holdAt = nil
            switch phase {
            case .pending where fingers.count == 1:
                flushRight(&out)
                phase = .holdArmed
                indicator = HoldIndicator(x: downX, y: downY, fingers: 1, armed: true, firesAt: at)
                if mode == .touch { out.append(moveTo(downX, downY)) }
                out.append(.feedback(.hold))
            case .pending2 where fingers.count >= 2:
                flushRight(&out)
                phase = .hold2Armed
                indicator = HoldIndicator(x: anchorX, y: anchorY, fingers: 2, armed: true, firesAt: at)
                if mode == .touch { out.append(moveTo(anchorX, anchorY)) }
                out.append(.feedback(.hold))
            default:
                break
            }
        }
        if var i = inertia, time >= i.at + Self.FRAME_MS {
            let dt = Float(time - i.at)
            let decay = Self.powf(Self.DECELERATION, dt)
            i.vx *= decay; i.vy *= decay; i.at = time
            out += i.panFirst ? swipe(i.vx * dt, i.vy * dt) : scroll(i.vx * dt, i.vy * dt)
            inertia = hypot(i.vx, i.vy) < 0.02 ? nil : i
        }
        if let at = autoPanAt, time >= at + Self.FRAME_MS { out += autoPan(time: time) }
        return out
    }

    // MARK: One finger

    private func moveOne(_ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        let dx = x - lastX, dy = y - lastY
        let dt = Float(max(1, time - lastMoveAt))
        track(dx / dt, dy / dt)
        lastX = x; lastY = y; lastMoveAt = time
        let far = hypot(x - downX, y - downY) >= slop
        var out: [GestureAction] = []
        switch phase {
        case .pending:
            guard far else { return [] }
            flushRight(&out)
            holdAt = nil; indicator = nil
            if let e = edge, inward(e, x - downX, y - downY) {
                phase = .edgeDone
                return out + [toEdge(e), .feedback(.shortcut)]
            }
            phase = .moving
            // Touch mode scrolls what is under the finger: the host scrolls what is under its cursor.
            if mode == .touch { return out + [moveTo(downX, downY)] + swipe(dx, dy) }
            return out + follow(x, y, dx, dy)
        case .moving:
            return mode == .touch ? swipe(dx, dy) : follow(x, y, dx, dy)
        case .holdArmed:
            guard far else { return [] }
            phase = .dragging
            indicator = nil
            if mode == .touch {
                // The press goes where the finger landed, so the drag picks up what was under it.
                out = [moveTo(downX, downY), .button(1, down: true), .feedback(.pickup), moveTo(x, y)]
                armAutoPan(time)
                return out
            }
            return [.button(1, down: true), .feedback(.pickup)] + follow(x, y, dx, dy)
        case .dragging:
            if mode == .touch { armAutoPan(time) }
            return follow(x, y, dx, dy)
        default:
            return []
        }
    }

    /// Trackpad: the cursor travels the finger's way, faster the faster it goes. Touch: it is under the finger.
    private func follow(_ x: Float, _ y: Float, _ dx: Float, _ dy: Float) -> [GestureAction] {
        if mode == .touch { return [moveTo(x, y)] }
        let gain = Self.pointerGain(hypot(vx, vy) * 1000)
        let s = viewport.scale
        setCursor(cursorX + dx * gain / s, cursorY + dy * gain / s)
        return [.moveTo(x: Int(cursorX), y: Int(cursorY))] + keepCursorInView()
    }

    /// Pointer acceleration, after macOS: slow for precision, up to 4× for a flick across the screen.
    public static func pointerGain(_ pointsPerSecond: Float) -> Float {
        min(max(0.8 * powf(pointsPerSecond / 150, 0.6), 0.5), 4)
    }

    /// Trackpad, zoomed in: the picture follows a cursor that reaches its outer 15%.
    private func keepCursorInView() -> [GestureAction] {
        guard viewport.zoom > 1 else { return [] }
        let p = viewport.toView(cursorX, cursorY)
        let mx = viewport.viewWidth * 0.15, my = viewport.viewHeight * 0.15
        var dx: Float = 0, dy: Float = 0
        if p.x < mx { dx = mx - p.x } else if p.x > viewport.viewWidth - mx { dx = viewport.viewWidth - mx - p.x }
        if p.y < my { dy = my - p.y } else if p.y > viewport.viewHeight - my { dy = viewport.viewHeight - my - p.y }
        if dx == 0 && dy == 0 { return [] }
        let next = viewport.panned(dx, dy)
        if next == viewport { return [] }
        viewport = next
        return [.view(next)]
    }

    private func armAutoPan(_ time: Int64) {
        if autoPanAt == nil && viewport.zoom > 1 && edgeDepth(lastX, lastY) != (0, 0) { autoPanAt = time }
    }

    /// How far into the edge band a point is, -1…1 on each axis (negative: left or top).
    private func edgeDepth(_ x: Float, _ y: Float) -> (Float, Float) {
        let bx = min(60 * density, viewport.viewWidth * 0.15), by = min(60 * density, viewport.viewHeight * 0.15)
        func depth(_ v: Float, _ size: Float, _ band: Float) -> Float {
            if v < band { return -min(1, (band - v) / band) }
            if v > size - band { return min(1, (v - (size - band)) / band) }
            return 0
        }
        return (depth(x, viewport.viewWidth, bx), depth(y, viewport.viewHeight, by))
    }

    /// Touch mode: a drag held near the edge of a zoomed picture moves the picture, up to 600 pt/s.
    private func autoPan(time: Int64) -> [GestureAction] {
        guard let at = autoPanAt, phase == .dragging || phase == .rightDrag, mode == .touch, viewport.zoom > 1 else { autoPanAt = nil; return [] }
        let (ex, ey) = edgeDepth(lastX, lastY)
        let dt = Float(time - at)
        let next = viewport.panned(-ex * 0.6 * dt, -ey * 0.6 * dt)
        autoPanAt = time
        if next == viewport { autoPanAt = nil; return [] }
        viewport = next
        return [.view(next), moveTo(lastX, lastY)]
    }

    /// The picture's edges, where they show in the view: a touch within the edge zone of one (on either
    /// side of it, along the picture) may be an edge swipe. The black bars beside the picture are not
    /// the picture's: swiping back from the screen's edge starts there.
    private func edgeOf(_ x: Float, _ y: Float) -> (left: Bool, right: Bool, top: Bool, bottom: Bool)? {
        let v = viewport
        let pl = max(0, v.left), pr = min(v.viewWidth, v.left + v.contentWidth)
        let pt = max(0, v.top), pb = min(v.viewHeight, v.top + v.contentHeight)
        let alongY = y >= pt - edgeZone && y <= pb + edgeZone, alongX = x >= pl - edgeZone && x <= pr + edgeZone
        let e = (left: alongY && abs(x - pl) < edgeZone, right: alongY && abs(x - pr) < edgeZone,
                 top: alongX && abs(y - pt) < edgeZone, bottom: alongX && abs(y - pb) < edgeZone)
        return e.left || e.right || e.top || e.bottom ? e : nil
    }

    private func inward(_ e: (left: Bool, right: Bool, top: Bool, bottom: Bool), _ dx: Float, _ dy: Float) -> Bool {
        (e.left && dx > abs(dy)) || (e.right && -dx > abs(dy)) || (e.top && dy > abs(dx)) || (e.bottom && -dy > abs(dx))
    }

    /// An edge swipe puts the cursor on the host's edge there (the Dock, the taskbar), or in its corner.
    private func toEdge(_ e: (left: Bool, right: Bool, top: Bool, bottom: Bool)) -> GestureAction {
        let r = viewport.toRemote(downX, downY)
        var x = mode == .touch ? Float(r.x) : cursorX, y = mode == .touch ? Float(r.y) : cursorY
        if e.left { x = 0 } else if e.right { x = Float(viewport.remoteWidth - 1) }
        if e.top { y = 0 } else if e.bottom { y = Float(viewport.remoteHeight - 1) }
        setCursor(x, y)
        return .moveTo(x: Int(cursorX), y: Int(cursorY))
    }

    /// A second finger came while one was holding or dragging: that ends, and so does the gesture.
    private func endOneFinger() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .dragging { out.append(.button(1, down: false)) }
        if [.pending, .moving, .holdArmed, .dragging, .edgeDone].contains(phase) { phase = .spent }
        holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }

    private func endTwoFinger() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .rightDrag { out.append(.button(2, down: false)) }
        if [.pending2, .scroll, .pinch, .hold2Armed, .rightDrag, .pending3, .swiped].contains(phase) { phase = .spent }
        holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }

    // MARK: Two fingers

    private func centroid(_ count: Int) -> (x: Float, y: Float, span: Float) {
        let pts = order.prefix(count).compactMap { fingers[$0] }
        guard !pts.isEmpty else { return (lastX, lastY, lastSpan) }
        let x = pts.map(\.x).reduce(0, +) / Float(pts.count), y = pts.map(\.y).reduce(0, +) / Float(pts.count)
        let span = pts.count >= 2 ? hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y) : 0
        return (x, y, span)
    }

    private func moveTwo(time: Int64) -> [GestureAction] {
        let c = centroid(2)
        let dx = c.x - lastX, dy = c.y - lastY
        let dt = Float(max(1, time - lastMoveAt))
        track(dx / dt, dy / dt)
        var out: [GestureAction] = []
        if phase == .pending2 {
            if abs(c.span - anchorSpan) > 24 * density {
                phase = .pinch
            } else if hypot(c.x - anchorX, c.y - anchorY) > 12 * density {
                phase = .scroll
            }
            if phase != .pending2 { flushRight(&out); holdAt = nil; indicator = nil }
            if phase == .scroll && mode == .touch { out.append(moveTo(anchorX, anchorY)) }
        }
        switch phase {
        case .scroll:
            out += scroll(dx, dy)
        case .pinch:
            if lastSpan > 0 {
                viewport = viewport.zoomed(c.span / lastSpan, c.x, c.y).panned(dx, dy)
                out.append(.view(viewport))
            }
        case .hold2Armed:
            if hypot(c.x - anchorX, c.y - anchorY) >= slop {
                phase = .rightDrag
                indicator = nil
                if mode == .touch {
                    out += [moveTo(anchorX, anchorY), .button(2, down: true), .feedback(.pickup), moveTo(c.x, c.y)]
                    lastX = c.x; lastY = c.y
                    armAutoPan(time)
                } else {
                    out += [.button(2, down: true), .feedback(.pickup)] + follow(c.x, c.y, dx, dy)
                }
            }
        case .rightDrag:
            if mode == .touch { lastX = c.x; lastY = c.y; armAutoPan(time) }
            out += follow(c.x, c.y, dx, dy)
        default:
            break
        }
        lastX = c.x; lastY = c.y; lastSpan = c.span; lastMoveAt = time
        return out
    }

    /// Wheel units per point of finger travel: about what moves the content with the fingers.
    private var wheelPerPoint: Float { min(max(2.5 / viewport.scale, 2), 12) / density }

    /// Touch mode, one finger: zoomed in, the picture follows the finger, and only what is left past
    /// its edge scrolls the host, as a zoomed photo on a phone; at full size it all scrolls.
    private func swipe(_ dx: Float, _ dy: Float) -> [GestureAction] {
        var out: [GestureAction] = []
        var rx = dx, ry = dy
        if viewport.zoom > 1 {
            let next = viewport.panned(dx, dy)
            rx -= next.panX - viewport.panX
            ry -= next.panY - viewport.panY
            if next != viewport { viewport = next; out.append(.view(next)) }
        }
        return out + scroll(rx, ry)
    }

    /// Fingers moving down pull the page down, as on a phone: the wheel scrolls up.
    private func scroll(_ dx: Float, _ dy: Float) -> [GestureAction] {
        wheelX += dx * wheelPerPoint
        wheelY += dy * wheelPerPoint
        let wx = Int(wheelX), wy = Int(wheelY)
        // A few units at a time: macOS turns three of them into one pixel and drops the rest.
        guard abs(wx) >= 3 || abs(wy) >= 3 else { return [] }
        wheelX -= Float(wx); wheelY -= Float(wy)
        return [.wheel(dx: -wx, dy: wy)]
    }

    private func track(_ nvx: Float, _ nvy: Float) {
        vx = vx * 0.4 + nvx * 0.6
        vy = vy * 0.4 + nvy * 0.6
    }

    // MARK: Ends

    private func finish(time: Int64) -> [GestureAction] {
        var out: [GestureAction] = []
        switch phase {
        case .pending:
            flushRight(&out)
            if mode == .touch {
                // Where the finger landed, or a moment ago nearby: a double-click lands on one pixel.
                var r = viewport.toRemote(downX, downY)
                if let t = lastTap, startedAt - t.at <= Self.DOUBLE_TAP_MS, hypot(downX - t.x, downY - t.y) <= doubleTapRadius {
                    r = (t.rx, t.ry)
                }
                lastTap = LastTap(x: downX, y: downY, rx: r.x, ry: r.y, at: time)
                setCursor(Float(r.x), Float(r.y))
                out += [.moveTo(x: r.x, y: r.y), .button(1, down: true), .button(1, down: false)]
            } else {
                out += [.button(1, down: true), .button(1, down: false)]
            }
        case .moving where mode == .touch:
            let speed = time - lastMoveAt > 60 ? 0 : hypot(vx, vy)
            if speed > 0.05 { inertia = (vx, vy, time, true) }
        case .holdArmed:
            out += rightClick(downX, downY)
        case .dragging:
            out.append(.button(1, down: false))
        case .pending2:
            if still && time - startedAt <= Self.TAP_MS {
                if pendingRight != nil {
                    pendingRight = nil
                    out += smartZoom(anchorX, anchorY)
                } else {
                    pendingRight = (time + Self.DOUBLE_TAP_MS, anchorX, anchorY)
                }
            }
        case .pending3:
            if still && time - startedAt <= Self.TAP_MS {
                if mode == .touch { out.append(moveTo(anchorX, anchorY)) }
                out += [.button(3, down: true), .button(3, down: false), .feedback(.click)]
            }
        default:
            break
        }
        phase = .idle; peak = 0; holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }

    private func rightClick(_ x: Float, _ y: Float) -> [GestureAction] {
        (mode == .touch ? [moveTo(x, y)] : []) + [.button(2, down: true), .button(2, down: false), .feedback(.click)]
    }

    private func flushRight(_ out: inout [GestureAction]) {
        guard let p = pendingRight else { return }
        pendingRight = nil
        out += rightClick(p.x, p.y)
    }

    /// Two-finger double tap, as on a Mac: zoom in on that spot, or back out to the whole screen.
    private func smartZoom(_ x: Float, _ y: Float) -> [GestureAction] {
        if viewport.zoom > 1.01 {
            viewport = Viewport(viewWidth: viewport.viewWidth, viewHeight: viewport.viewHeight,
                                remoteWidth: viewport.remoteWidth, remoteHeight: viewport.remoteHeight)
        } else {
            viewport = viewport.zoomed(2.5 / viewport.zoom, x, y)
        }
        return [.view(viewport), .feedback(.shortcut)]
    }

    // MARK: Helpers

    private func setCursor(_ x: Float, _ y: Float) {
        cursorX = min(max(x, 0), Float(max(0, viewport.remoteWidth - 1)))
        cursorY = min(max(y, 0), Float(max(0, viewport.remoteHeight - 1)))
        hasCursor = true
        lastLocalMoveAt = now
    }

    private func moveTo(_ x: Float, _ y: Float) -> GestureAction {
        let r = viewport.toRemote(x, y)
        setCursor(Float(r.x), Float(r.y))
        return .moveTo(x: r.x, y: r.y)
    }

    private static func powf(_ base: Float, _ exp: Float) -> Float { Float(Foundation.pow(Double(base), Double(exp))) }
}

/// Three-finger swipes as the host's own shortcuts: up shows every window, down the desktop (the
/// plugin's actions, which know each system), left and right switch to the desktop on that side.
public enum DesktopSwipeShortcut {
    public static func frames(_ direction: SwipeDirection, os: String) -> [[UInt8]] {
        func combo(_ keys: [Int]) -> [[UInt8]] {
            keys.map { DesktopProtocol.key($0, down: true) } + keys.reversed().map { DesktopProtocol.key($0, down: false) }
        }
        let modifiers: [Int]
        switch os.lowercased() {
        case "macos": modifiers = [HidUsage.LEFT_CTRL]
        case "windows": modifiers = [HidUsage.LEFT_CTRL, HidUsage.LEFT_GUI]
        default: modifiers = [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT]
        }
        switch direction {
        case .up: return [DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS)]
        case .down: return [DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP)]
        // Fingers going left bring in the desktop on the right, as on a trackpad.
        case .left: return combo(modifiers + [HidUsage.RIGHT])
        case .right: return combo(modifiers + [HidUsage.LEFT])
        }
    }
}
