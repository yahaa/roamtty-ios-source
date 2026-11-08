import SwiftUI

/// Android `drawGhost`, `ToolboxPet` and `ItermuxLogo`: the toolbox ghost drawn live so it can bob,
/// sway, ripple its hem, blink and wave the wrench. Everything is drawn on Android's grids
/// (26 units for the pet, 72 for the logo) so the two apps keep the same picture.
struct GhostPose {
    var float: Double = 0
    var sway: Double = 0
    var hem: Double = 0
    var eyes: Double = 1
    var wave: Double = 0
    var cursor: Double = 1

    static let still = GhostPose()

    /// Android's infinite transitions, read at one moment.
    static func at(_ time: TimeInterval) -> GhostPose {
        let ms = time * 1000
        return GhostPose(float: fastOutSlowIn(reversing(ms, period: 1400)),
                         sway: -5 + 10 * fastOutSlowIn(reversing(ms, period: 2300)),
                         hem: ms.truncatingRemainder(dividingBy: 1100) / 1100 * 2 * .pi,
                         eyes: keyframes(ms, period: 3600, [(0, 1), (3250, 1), (3330, 0.1), (3420, 1), (3600, 1)]),
                         wave: keyframes(ms, period: 5200, [(0, 0), (3000, 0), (3180, -30), (3380, 14), (3580, -30), (3780, 14), (3980, 0), (5200, 0)]),
                         cursor: ms.truncatingRemainder(dividingBy: 1060) < 530 ? 1 : 0)
    }

    /// A tween that runs forward then back, as `RepeatMode.Reverse` does.
    private static func reversing(_ ms: Double, period: Double) -> Double {
        let phase = ms.truncatingRemainder(dividingBy: 2 * period) / period
        return phase <= 1 ? phase : 2 - phase
    }

    /// Linear interpolation between keyframes, Compose's default.
    private static func keyframes(_ ms: Double, period: Double, _ frames: [(Double, Double)]) -> Double {
        let t = ms.truncatingRemainder(dividingBy: period)
        for (a, b) in zip(frames, frames.dropFirst()) where t <= b.0 {
            return b.0 == a.0 ? b.1 : a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
        }
        return frames.last?.1 ?? 0
    }

    /// Material's FastOutSlowInEasing, cubic-bezier(0.4, 0, 0.2, 1).
    static func fastOutSlowIn(_ x: Double) -> Double {
        func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
        var low = 0.0, high = 1.0
        for _ in 0..<16 { let mid = (low + high) / 2; if curve(mid, 0.4, 0.2) < x { low = mid } else { high = mid } }
        return curve((low + high) / 2, 0, 1)
    }
}

private enum GhostInk {
    static let body = Color(red: 0xF8 / 255, green: 0xF7 / 255, blue: 0xFF / 255)
    static let ink = Color(red: 0x3B / 255, green: 0x35 / 255, blue: 0x50 / 255)
    static let blush = Color(red: 0xFF / 255, green: 0x9E / 255, blue: 0xB5 / 255)
    static let metal = Color(red: 0xD9 / 255, green: 0xDE / 255, blue: 0xE8 / 255)
    static let keyboard = Color(red: 0xED / 255, green: 0xEB / 255, blue: 0xF5 / 255)
}

extension GraphicsContext {
    fileprivate mutating func rotate(_ degrees: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y); rotate(by: .degrees(degrees)); translateBy(x: -pivot.x, y: -pivot.y)
    }
    fileprivate mutating func scale(x: Double, y: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y); scaleBy(x: x, y: y); translateBy(x: -pivot.x, y: -pivot.y)
    }

    /// The ghost on its 26-unit grid, holding a keyboard and a wrench painted `accent`.
    func drawGhost(accent: Color, pose: GhostPose) {
        let line = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path { Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)) }
        func circle(_ c: CGPoint, _ r: Double) -> Path { oval(c.x - r, c.y - r, 2 * r, 2 * r) }
        func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
            Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        }
        // Wrench behind the paw, swinging around the grip.
        var wrench = self
        let grip = CGPoint(x: 19.6, y: 14.2)
        wrench.rotate(pose.wave, around: grip)
        let handle = Path { $0.move(to: grip); $0.addLine(to: CGPoint(x: 22.4, y: 7.6)) }
        wrench.stroke(handle, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        wrench.stroke(handle, with: .color(accent), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        // Open-ended head, its jaw facing away from the grip.
        let head = Path { $0.addArc(center: CGPoint(x: 23.2, y: 5.4), radius: 2.1, startAngle: .degrees(-22), endAngle: .degrees(248), clockwise: false) }
        wrench.stroke(head, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        wrench.stroke(head, with: .color(GhostInk.metal), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        // Dome head, straight sides and a hem that ripples as it floats.
        let body = Path { path in
            path.move(to: CGPoint(x: 4, y: 20.4))
            path.addLine(to: CGPoint(x: 4, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 4, y: 6.2), control2: CGPoint(x: 7.6, y: 3))
            path.addCurve(to: CGPoint(x: 20, y: 11), control1: CGPoint(x: 16.4, y: 3), control2: CGPoint(x: 20, y: 6.2))
            path.addLine(to: CGPoint(x: 20, y: 20.4))
            for i in 1...24 {
                let t = Double(i) / 24
                path.addLine(to: CGPoint(x: 20 - 16 * t, y: 20.4 + 1.3 * sin(t * 6 * .pi + pose.hem)))
            }
            path.closeSubpath()
        }
        fill(body, with: .color(GhostInk.body))
        stroke(body, with: .color(GhostInk.ink), style: line)
        // The left paw holds a little keyboard in front of the body, tipping a bit as the wrench waves.
        let paw = CGPoint(x: 3.9, y: 14.6 - pose.wave / 40)
        var board = self
        board.rotate(-10 + pose.wave / 8, around: paw)
        let left = paw.x - 2.2, top = paw.y + 0.2
        board.fill(rounded(left, top, 7.2, 4.4, 0.9), with: .color(GhostInk.keyboard))
        board.stroke(rounded(left, top, 7.2, 4.4, 0.9), with: .color(GhostInk.ink), lineWidth: 1.1)
        for row in 0..<2 { for col in 0..<4 {
            board.fill(rounded(left + 0.8 + Double(col) * 1.45, top + 0.75 + Double(row) * 1.25, 0.95, 0.8, 0.25), with: .color(accent))
        } }
        board.fill(rounded(left + 1.9, top + 3.25, 3.2, 0.6, 0.3), with: .color(accent))
        // The left paw holds the keyboard; the right paw grips the wrench.
        for (center, radius) in [(paw, 1.7), (grip, 1.8)] {
            fill(circle(center, radius), with: .color(GhostInk.body))
            stroke(circle(center, radius), with: .color(GhostInk.ink), style: line)
        }
        // Eyes close from the top and bottom at once.
        for x in [9.2, 14.8] {
            var eye = self
            eye.scale(x: 1, y: pose.eyes, around: CGPoint(x: x, y: 11.2))
            eye.fill(oval(x - 1.1, 9.6, 2.2, 3.2), with: .color(GhostInk.ink))
            eye.fill(circle(CGPoint(x: x + 0.35, y: 10.4), 0.45), with: .color(.white))
        }
        fill(oval(6.4, 13, 2.4, 1.3), with: .color(GhostInk.blush.opacity(0.6)))
        fill(oval(15.2, 13, 2.4, 1.3), with: .color(GhostInk.blush.opacity(0.6)))
        fill(oval(11.2, 13.6, 1.6, 1.8), with: .color(GhostInk.ink))
    }
}

/// Android `ToolboxPet`'s picture: it pops in, bobs over its shadow, sways, ripples its hem,
/// blinks and now and then waves the wrench. Still under Reduce Motion.
struct ToolboxPetArt: View {
    var animated = true
    @State private var appeared = Date()
    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let pose = animated ? GhostPose.at(context.date.timeIntervalSinceReferenceDate) : .still
            let hop = animated ? Self.hop(context.date.timeIntervalSince(appeared)) : 0
            Canvas { canvas, size in
                var grid = canvas
                let unit = min(size.width, size.height) / 26
                grid.scaleBy(x: unit, y: unit)
                let lift = pose.float * 1.6 + hop * 4
                // The shadow stays on the ground and shrinks as the ghost rises.
                let shadow = 1 - lift / 9
                grid.fill(Path(ellipseIn: CGRect(x: 12 - 5 * shadow, y: 23.6, width: 10 * shadow, height: 1.6)), with: .color(.black.opacity(0.22 * shadow)))
                grid.translateBy(x: 0, y: 0.4 - lift)
                grid.rotate(pose.sway, around: CGPoint(x: 12, y: 21))
                grid.drawGhost(accent: Palette.accent, pose: pose)
            }
        }.onAppear { appeared = Date() }.accessibilityHidden(true)
    }

    /// Android's pop-in: up over 180 ms, then a loose spring back to rest.
    private static func hop(_ elapsed: TimeInterval) -> Double {
        guard elapsed >= 0 else { return 0 }
        if elapsed < 0.18 { return GhostPose.fastOutSlowIn(elapsed / 0.18) }
        let t = elapsed - 0.18
        return t > 2 ? 0 : exp(-7.4 * t) * cos(20 * t)
    }
}

/// Android `ItermuxLogo`: the launcher icon drawn live. Animated, the ghost bobs, ripples its hem,
/// blinks and waves the wrench while the cursor blinks; still, it matches the launcher icon.
struct RoamttyLogoArt: View {
    var animated = false
    private static let terminal = Color(red: 0x25 / 255, green: 0x27 / 255, blue: 0x28 / 255)
    private static let text = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xEA / 255)
    private static let accent = Color(red: 0xEF / 255, green: 0xA7 / 255, blue: 0x83 / 255)
    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let pose = animated ? GhostPose.at(context.date.timeIntervalSinceReferenceDate) : .still
            Canvas { canvas, size in
                var icon = canvas
                let unit = min(size.width, size.height) / 72
                icon.scaleBy(x: unit, y: unit)
                icon.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 72, height: 72), cornerRadius: 19), with: .color(Self.terminal))
                for (x1, x2, y) in [(12.0, 26.0, 9.0), (7, 19, 16), (52, 62, 16), (6, 14, 23)] {
                    icon.stroke(Path { $0.move(to: CGPoint(x: x1, y: y)); $0.addLine(to: CGPoint(x: x2, y: y)) },
                                with: .color(Self.text.opacity(0.1)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
                let prompt = Path { $0.move(to: CGPoint(x: 28, y: 58)); $0.addLine(to: CGPoint(x: 33, y: 62.5)); $0.addLine(to: CGPoint(x: 28, y: 67)) }
                icon.stroke(prompt, with: .color(Self.accent), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                icon.fill(Path(roundedRect: CGRect(x: 37, y: 57.5, width: 6, height: 10), cornerRadius: 1), with: .color(Self.accent.opacity(0.85 * pose.cursor)))
                icon.translateBy(x: 12.375, y: 7.5)
                icon.scaleBy(x: 1.75, y: 1.75)
                let lift = pose.float * 1.6, shadow = 1 - lift / 9
                icon.fill(Path(ellipseIn: CGRect(x: 12 - 5 * shadow, y: 23.6, width: 10 * shadow, height: 1.6)), with: .color(.black.opacity(0.35 * shadow)))
                icon.translateBy(x: 0, y: 0.4 - lift)
                icon.drawGhost(accent: Self.accent, pose: pose)
            }
        }
    }
}
