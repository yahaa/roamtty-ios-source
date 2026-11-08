import Foundation

extension Host {
    /// Before the probe finishes, retain the saved preference. Once known, use
    /// tmux only when this host actually provides it, matching Android.
    public var newSessionMode: SessionMode {
        guard let plugins else { return mode }
        return plugins.contains("tmux") ? .tmux : .shell
    }
}
