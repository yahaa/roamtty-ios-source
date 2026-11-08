import UIKit

/// The remote desktop keeps edge swipes that start on its picture for itself (they put the cursor on
/// the host's edge); outside the picture, on the black bars, swiping back works as on any page.
enum InteractivePopGesture {
    @MainActor static weak var desktop: DesktopGestureView?
}

/// SwiftUI turns the edge swipe back off on pages that hide the navigation bar, such as the terminal.
/// Keep it on for every pushed page, and let it win over the terminal's own pans that start near the edge.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
        if let desktop = InteractivePopGesture.desktop, desktop.window != nil,
           desktop.keepsEdgeSwipe(at: gestureRecognizer.location(in: desktop)) { return false }
        return true
    }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
}
