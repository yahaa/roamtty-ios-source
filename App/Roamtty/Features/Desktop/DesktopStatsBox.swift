import SwiftUI

/// Where the network figures sit over the picture, as fractions of the room it leaves them (0, 0 the top
/// left), and their drag. The long press that starts one is `DesktopGestureView`'s (`OverlayTouch`).
/// Port of Android `StatsBox` (roamtty #274).
final class DesktopStatsBox: ObservableObject {
    @Published private(set) var fx: CGFloat = 0
    @Published private(set) var fy: CGFloat = 0
    @Published private(set) var dragging = false
    /// Whether the figures are on (显示网络状态): only then does a touch on `frame` wait for a hold.
    var shown = false
    /// The figures in the picture's coordinates, as last laid out. Not cleared when a view goes: on rotation the old
    /// view disappears after the new one has laid out.
    var frame: CGRect?
    /// The room the picture leaves them, in points: what a fraction is of.
    var room: CGSize = .zero
    /// A drag ended: where to keep them.
    var onMoved: ((CGFloat, CGFloat) -> Void)?
    private var from: CGPoint = .zero
    private var fromFraction: CGPoint = .zero

    var moved: Bool { fx != 0 || fy != 0 }

    func contains(_ point: CGPoint) -> Bool { shown && frame?.contains(point) == true }

    func place(_ x: Double, _ y: Double) { fx = CGFloat(min(1, max(0, x))); fy = CGFloat(min(1, max(0, y))) }

    func startDrag(at point: CGPoint) {
        from = point; fromFraction = CGPoint(x: fx, y: fy); dragging = true
    }

    /// Follows the finger from where the drag started, kept inside the picture.
    func drag(to point: CGPoint) {
        guard dragging else { return }
        if room.width > 0 { fx = min(1, max(0, fromFraction.x + (point.x - from.x) / room.width)) }
        if room.height > 0 { fy = min(1, max(0, fromFraction.y + (point.y - from.y) / room.height)) }
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        onMoved?(fx, fy)
    }

    func reset() { fx = 0; fy = 0 }
}

/// Places its one subview at the box's fractions inside the room the proposal leaves, `margin` from each edge.
struct DesktopStatsPlacement: Layout {
    let fx: CGFloat
    let fy: CGFloat
    let margin: CGFloat
    let box: DesktopStatsBox

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let room = CGSize(width: max(0, bounds.width - size.width - 2 * margin), height: max(0, bounds.height - size.height - 2 * margin))
        box.room = room
        view.place(at: CGPoint(x: bounds.minX + margin + fx * room.width, y: bounds.minY + margin + fy * room.height),
                   anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

struct DesktopStatsFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
