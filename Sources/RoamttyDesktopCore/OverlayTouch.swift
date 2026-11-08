import Foundation

/// Who owns a touch that starts on a small box floating over the picture (the network figures, moved by a
/// long press). The box takes it only when the first finger holds still on it for `holdMs`; anything sooner
/// (a lift, a move past `slop`, a second finger) makes it the picture's, and the caller replays what it held
/// back, in order and with the touches' own times, so a tap, a swipe or a pinch over the box reaches the desktop
/// exactly as elsewhere. Only a still long press on the box is lost to the picture.
/// Port of Android `desktop-core/OverlayTouch.kt` (roamtty #274).
public final class OverlayTouch {
    public enum Owner: Equatable, Sendable { case none, pending, box, picture }

    /// How long a finger stays still on the box before it picks the box up.
    public static let holdMs: Int64 = 400

    public private(set) var owner: Owner = .none
    private let slop: Float
    private var downX: Float = 0
    private var downY: Float = 0
    private var downAt: Int64 = 0

    public init(slop: Float) { self.slop = slop }

    /// When a still finger becomes the box's: the caller ticks then.
    public var holdAt: Int64? { owner == .pending ? downAt + Self.holdMs : nil }

    /// The first finger: on the box it waits, anywhere else it is the picture's at once.
    @discardableResult
    public func down(onBox: Bool, _ x: Float, _ y: Float, time: Int64) -> Owner {
        downX = x; downY = y; downAt = time
        owner = onBox ? .pending : .picture
        return owner
    }

    /// The first finger moved to `x`, `y`. Still until now (every earlier move stayed within the slop): past the
    /// hold it is the box's however far this move goes, even when the timer runs late.
    @discardableResult
    public func moved(_ x: Float, _ y: Float, time: Int64) -> Owner {
        if owner == .pending {
            if time >= downAt + Self.holdMs { owner = .box } else if hypot(x - downX, y - downY) > slop { owner = .picture }
        }
        return owner
    }

    /// Another finger came down: a waiting touch was a pinch or a two-finger gesture, the picture's.
    @discardableResult
    public func otherFinger() -> Owner {
        if owner == .pending { owner = .picture }
        return owner
    }

    /// The hold's time came with the finger still: the box's.
    @discardableResult
    public func tick(_ time: Int64) -> Owner {
        if owner == .pending, time >= downAt + Self.holdMs { owner = .box }
        return owner
    }

    /// The last finger lifted: a waiting touch was a tap. The owner it ended with; the next touch starts afresh.
    @discardableResult
    public func up(time: Int64) -> Owner {
        if owner == .pending { owner = time >= downAt + Self.holdMs ? .box : .picture }
        defer { owner = .none }
        return owner
    }

    /// The touch was cancelled.
    public func reset() { owner = .none }
}
