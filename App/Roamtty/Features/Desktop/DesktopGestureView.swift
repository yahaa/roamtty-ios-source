import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The page's touch surface: hands the picture's touches to `DesktopGestureView`.
struct DesktopGestureOverlay: UIViewRepresentable {
    @ObservedObject var controller: DesktopController
    let size: CGSize

    func makeUIView(context: Context) -> DesktopGestureView {
        let view = DesktopGestureView()
        view.controller = controller
        return view
    }
    func updateUIView(_ uiView: DesktopGestureView, context: Context) {
        uiView.controller = controller
        uiView.boundsSize = size
        uiView.hostCursorChanged(controller.cursor)
    }
    static func dismantleUIView(_ uiView: DesktopGestureView, coordinator: ()) {
        uiView.stopTicking()
        uiView.controller = nil
    }
}

/// Raw touches into `DesktopGestures`, and what it asks for out to the host. It also draws what the
/// gestures need on the phone: the cursor where the phone put it, the hold ring, and haptics.
final class DesktopGestureView: UIView {
    weak var controller: DesktopController?
    var boundsSize: CGSize = .zero
    private let gestures = DesktopGestures(mode: .touch, density: 1)
    /// Fires once, when `gestures` next needs a tick (a hold, a waiting right click, inertia); nil while nothing waits.
    private var tickTimer: Timer?
    /// The timer's target: the run loop retains it, never the view.
    private final class TickTarget: NSObject {
        weak var view: DesktopGestureView?
        init(_ view: DesktopGestureView) { self.view = view }
        @objc func tick() { view?.tick() }
        @objc func hold() { view?.holdFired() }
    }
    /// Each finger's id for `gestures`, for as long as it touches.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var lastTouchEnded: Int64 = 0

    /// A touch that starts on the network figures waits: a still hold moves them, anything else is replayed to
    /// the picture as it came (`OverlayTouch`), so the figures never take a gesture from the desktop.
    private let overlay = OverlayTouch(slop: 10)
    /// Who has the touches since the first finger came down, until the last lifts.
    private var routing: OverlayTouch.Owner = .none
    /// What a waiting touch did so far, replayed to `gestures` if it turns out to be the picture's.
    private enum Held {
        case began(Int, Float, Float, Int64)
        case moved([(id: Int, x: Float, y: Float)], Int64)
        case ended(Int, Float, Float, Int64)
    }
    private var held: [Held] = []
    private var holdTimer: Timer?
    private var boxTouch: ObjectIdentifier?
    private var boxPoint: CGPoint = .zero

    private let cursorLayer = CALayer()
    private var cursorShape: CursorImage?
    private var cursorShown: RemoteCursor?
    private let ringLayer = CAShapeLayer()
    private var ringShown: HoldIndicator?
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let tapFeel = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        cursorLayer.contentsScale = UIScreen.main.scale
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 2
        layer.addSublayer(cursorLayer)
        ringLayer.isHidden = true
        ringLayer.zPosition = 1
        layer.addSublayer(ringLayer)
        accessibilityIdentifier = "desktop-gestures"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { tickTimer?.invalidate(); holdTimer?.invalidate() }

    /// Three-finger swipes are the host's, not the system's undo and redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Arms the timer for `gestures.tickAt`, instead of ticking every display frame while the page shows.
    private func scheduleTick() {
        tickTimer?.invalidate(); tickTimer = nil
        guard window != nil, let at = gestures.tickAt else { return }
        let timer = Timer(timeInterval: max(0, Double(at - Self.nowMs()) / 1000), target: TickTarget(self),
                          selector: #selector(TickTarget.tick), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        touchIDs.removeAll()
        endRouting()
        apply(gestures.cancel())
        tickTimer?.invalidate(); tickTimer = nil
    }

    /// The clock touches carry: seconds since boot.
    private static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    private static func ms(_ touch: UITouch) -> Int64 { Int64(touch.timestamp * 1000) }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncViewport()
        refreshCursor()
    }

    private func syncViewport() {
        guard let c = controller else { return }
        gestures.mode = c.page.pointerMode
        let w = Float(bounds.width > 0 ? bounds.width : boundsSize.width)
        let h = Float(bounds.height > 0 ? bounds.height : boundsSize.height)
        var vp = gestures.viewport
        vp.viewWidth = max(1, w); vp.viewHeight = max(1, h)
        let remote = (max(1, c.remoteSize.0), max(1, c.remoteSize.1))
        // A new screen size starts unzoomed, as on Android.
        if (vp.remoteWidth, vp.remoteHeight) != remote { vp = Viewport(viewWidth: vp.viewWidth, viewHeight: vp.viewHeight, remoteWidth: remote.0, remoteHeight: remote.1) }
        show(vp.clamped())
    }

    func hostCursorChanged(_ cursor: RemoteCursor?) {
        guard let cursor, cursor != cursorShown else { return }
        cursorShown = cursor
        gestures.hostCursor(x: cursor.x, y: cursor.y, time: Self.nowMs())
        refreshCursor()
    }

    @objc private func tick() {
        apply(gestures.tick(Self.nowMs()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        syncViewport()
        #if DEBUG
        // A double tap's second tap belongs with the first.
        if touchIDs.isEmpty, Self.nowMs() - lastTouchEnded > 500 { controller?.probeGestureStarted() }
        #endif
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let first = touchIDs.isEmpty
            let id = nextTouchID; nextTouchID += 1
            touchIDs[ObjectIdentifier(t)] = id
            let p = t.location(in: self)
            if first {
                routing = overlay.down(onBox: controller?.statsBox.contains(p) == true, Float(p.x), Float(p.y), time: Self.ms(t))
                if routing == .pending {
                    boxTouch = ObjectIdentifier(t); boxPoint = p
                    held = [.began(id, Float(p.x), Float(p.y), Self.ms(t))]
                    armHold()
                    continue
                }
            } else if routing == .pending {
                overlay.otherFinger()
                toPicture()
            }
            if routing == .picture { apply(gestures.began(id, Float(p.x), Float(p.y), time: Self.ms(t))) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let moved = touches.compactMap { t -> (id: Int, x: Float, y: Float)? in
            guard let id = touchIDs[ObjectIdentifier(t)] else { return nil }
            let p = t.location(in: self)
            return (id, Float(p.x), Float(p.y))
        }
        guard !moved.isEmpty else { return }
        let time = touches.map(Self.ms).max() ?? Self.nowMs()
        let finger = touches.first { ObjectIdentifier($0) == boxTouch }.map { $0.location(in: self) }
        switch routing {
        case .picture:
            apply(gestures.moved(moved, time: time))
        case .pending:
            held.append(.moved(moved, time))
            guard let finger else { return }
            boxPoint = finger
            switch overlay.moved(Float(finger.x), Float(finger.y), time: time) {
            case .picture: toPicture()
            case .box: pickUp(); controller?.statsBox.drag(to: finger)
            default: break
            }
        case .box:
            if let finger { controller?.statsBox.drag(to: finger) }
        case .none:
            break
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            let p = t.location(in: self)
            switch routing {
            case .picture:
                apply(gestures.ended(id, Float(p.x), Float(p.y), time: Self.ms(t)))
            case .pending:
                // Only the first finger can be down while a touch waits.
                held.append(.ended(id, Float(p.x), Float(p.y), Self.ms(t)))
                if overlay.up(time: Self.ms(t)) == .box { pickUp(); controller?.statsBox.endDrag() } else { toPicture() }
            case .box:
                if ObjectIdentifier(t) == boxTouch { controller?.statsBox.endDrag(); boxTouch = nil }
            case .none:
                break
            }
            lastTouchEnded = Self.ms(t)
        }
        if touchIDs.isEmpty { endRouting() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchIDs.removeAll()
        if routing == .picture { apply(gestures.cancel()) }
        endRouting()
    }

    // MARK: The figures' long press

    private func armHold() {
        holdTimer?.invalidate(); holdTimer = nil
        guard let at = overlay.holdAt else { return }
        let timer = Timer(timeInterval: max(0, Double(at - Self.nowMs()) / 1000), target: TickTarget(self),
                          selector: #selector(TickTarget.hold), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    fileprivate func holdFired() {
        if routing == .pending, overlay.tick(Self.nowMs()) == .box { pickUp() }
    }

    /// The waiting touch is the picture's: what it did so far goes to `gestures` first, in order.
    private func toPicture() {
        routing = .picture
        holdTimer?.invalidate(); holdTimer = nil
        let replay = held
        held = []
        for h in replay {
            switch h {
            case let .began(id, x, y, t): apply(gestures.began(id, x, y, time: t))
            case let .moved(m, t): apply(gestures.moved(m, time: t))
            case let .ended(id, x, y, t): apply(gestures.ended(id, x, y, time: t))
            }
        }
    }

    /// A still hold: the figures follow the finger; nothing of this touch reaches the host.
    private func pickUp() {
        guard routing != .box else { return }
        routing = .box
        holdTimer?.invalidate(); holdTimer = nil
        held = []
        controller?.statsBox.startDrag(at: boxPoint)
        impact.impactOccurred()
    }

    private func endRouting() {
        if routing == .box { controller?.statsBox.endDrag() }
        routing = .none
        overlay.reset()
        held = []
        boxTouch = nil
        holdTimer?.invalidate(); holdTimer = nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let hid = HidUsage.fromKeyboardHIDUsage(Int(key.keyCode.rawValue)) {
                controller?.input(DesktopProtocol.key(hid, down: true))
            }
        }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let hid = HidUsage.fromKeyboardHIDUsage(Int(key.keyCode.rawValue)) {
                controller?.input(DesktopProtocol.key(hid, down: false))
            }
        }
        super.pressesEnded(presses, with: event)
    }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            scheduleTick()
            InteractivePopGesture.desktop = self
        } else {
            stopTicking()
            if InteractivePopGesture.desktop === self { InteractivePopGesture.desktop = nil }
        }
    }

    /// Whether an edge swipe from this point (view coordinates) is the desktop's: it starts on the picture.
    func keepsEdgeSwipe(at point: CGPoint) -> Bool {
        controller?.remoteSize.0 ?? 0 > 0 && gestures.viewport.contains(Float(point.x), Float(point.y))
    }

    private func show(_ vp: Viewport) {
        gestures.viewport = vp
        // Layout calls this inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async { [weak self] in
            if let c = self?.controller, c.viewport != vp { c.viewport = vp }
        }
    }

    private func apply(_ actions: [GestureAction]) {
        // Every gesture call comes through here, so the next tick follows whatever it changed.
        defer { scheduleTick(); refreshCursor(); refreshRing() }
        guard let c = controller else { return }
        for a in actions {
            switch a {
            case .moveTo(let x, let y):
                c.input(DesktopProtocol.abs(display: c.displayIndex, x: x, y: y))
            case .button(let b, let down):
                c.input(DesktopProtocol.button(b, down: down))
            case .wheel(let dx, let dy):
                c.input(DesktopProtocol.wheel(dx: dx, dy: dy))
            case .view(let vp):
                show(vp)
            case .swipe(let direction):
                DesktopSwipeShortcut.frames(direction, os: c.hello?.os ?? c.host.system).forEach(c.input)
            case .feedback(let kind):
                switch kind {
                case .hold, .pickup: impact.impactOccurred()
                case .click, .shortcut: tapFeel.impactOccurred()
                }
            }
            #if DEBUG
            c.probeInput(a)
            #endif
        }
    }

    // MARK: Cursor and ring

    /// The host's cursor image at the picture's scale, kept between 15 and 24 pt (the picture is often a
    /// fifth of the host's size, and zoomed in five times); an arrow until it sends one, about iOS's own pointer size.
    private func refreshCursor() {
        let visible = cursorShown?.visible ?? true
        guard gestures.hasCursor, visible, controller?.remoteSize.0 ?? 0 > 0 else { cursorLayer.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let shape = cursorShown?.shape
        if shape != cursorShape || cursorLayer.contents == nil {
            cursorShape = shape
            if let shape, let image = Self.image(shape) {
                cursorLayer.contents = image
                cursorLayer.anchorPoint = CGPoint(x: CGFloat(shape.hotX) / CGFloat(max(1, shape.width)), y: CGFloat(shape.hotY) / CGFloat(max(1, shape.height)))
            } else {
                cursorLayer.contents = Self.arrow
                cursorLayer.anchorPoint = CGPoint(x: 1.5 / 14, y: 1.5 / 21)
            }
        }
        let vp = gestures.viewport
        if let shape = cursorShape {
            let size = CGFloat(max(1, shape.height, shape.width))
            let s = min(max(CGFloat(vp.scale), 15 / size), 24 / size)
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(shape.width) * s, height: CGFloat(shape.height) * s)
        } else {
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: 10, height: 15)
        }
        let p = vp.toView(gestures.cursorX, gestures.cursorY)
        cursorLayer.position = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        cursorLayer.isHidden = false
    }

    private static func image(_ shape: CursorImage) -> CGImage? {
        guard shape.width > 0, shape.height > 0, shape.rgba.count >= shape.width * shape.height * 4,
              let provider = CGDataProvider(data: Data(shape.rgba) as CFData) else { return nil }
        return CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: shape.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The standard arrow, white with a black edge, its tip the hot spot.
    private static let arrow: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: 14, height: 21), format: format).image { ctx in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 17))
            path.addLine(to: CGPoint(x: 5.5, y: 13.2))
            path.addLine(to: CGPoint(x: 8.3, y: 19.5))
            path.addLine(to: CGPoint(x: 10.8, y: 18.4))
            path.addLine(to: CGPoint(x: 8.1, y: 12.3))
            path.addLine(to: CGPoint(x: 13, y: 12.3))
            path.close()
            UIColor.white.setFill(); path.fill()
            UIColor.black.setStroke(); path.lineWidth = 1.2; path.lineJoinStyle = .round; path.stroke()
            _ = ctx
        }.cgImage
    }()

    /// The hold ring: it fills while a hold is coming, then turns solid, blue for the left button, red for the right.
    private func refreshRing() {
        let next = gestures.indicator
        guard next != ringShown else { return }
        ringShown = next
        ringLayer.removeAllAnimations()
        guard let next else { ringLayer.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r: CGFloat = next.fingers > 1 ? 34 : 26
        ringLayer.path = UIBezierPath(arcCenter: .zero, radius: r, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        ringLayer.position = CGPoint(x: CGFloat(next.x), y: CGFloat(next.y))
        let color = next.fingers > 1 ? UIColor.systemRed : UIColor.systemBlue
        ringLayer.lineWidth = 3
        ringLayer.isHidden = false
        if next.armed {
            ringLayer.strokeColor = color.cgColor
            ringLayer.fillColor = color.withAlphaComponent(0.3).cgColor
            ringLayer.strokeEnd = 1
            ringLayer.opacity = 1
        } else {
            // Nothing shows for a tap: the ring starts after a moment and fills as the hold comes.
            ringLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            ringLayer.fillColor = UIColor.clear.cgColor
            ringLayer.strokeEnd = 1
            // A tap lasts under 0.2 s: only a finger still down after that sees the ring.
            let delay = 0.2
            let total = max(0.05, Double(next.firesAt - Self.nowMs()) / 1000 - delay)
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = 0; fill.toValue = 1
            fill.beginTime = CACurrentMediaTime() + delay; fill.duration = total
            fill.fillMode = .both
            ringLayer.add(fill, forKey: "fill")
        }
        CATransaction.commit()
        if next.armed { impact.prepare() } else { impact.prepare(); tapFeel.prepare() }
    }
}
