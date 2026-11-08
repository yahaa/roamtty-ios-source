import SwiftUI

/// Picks up from the system launch screen's colour: the logo pops in and plays for a moment, then fades into the app.
/// Touches pass through, so it never holds anything up.
struct StartupSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onDone: () -> Void
    @State private var shown = false
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            RoamttyLogoArt(animated: !reduceMotion).frame(width: 72, height: 72)
                .scaleEffect(shown || reduceMotion ? 1 : 0.8).opacity(shown || reduceMotion ? 1 : 0)
        }.allowsHitTesting(false).accessibilityHidden(true)
            .task {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { shown = true }
                try? await Task.sleep(for: reduceMotion ? .milliseconds(300) : .milliseconds(1100))
                onDone()
            }
    }
}
