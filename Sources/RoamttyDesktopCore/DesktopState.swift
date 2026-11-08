import Foundation

/// What the read-only probe found on a host: a desktop session, none, or a desktop nobody is logged in to.
/// Port of Android `desktop-core/DesktopState.kt` (roamtty #218).
public enum DesktopProbe: String, CaseIterable, Sendable {
    case yes, no, nologin

    public static func decode(_ value: String?) -> DesktopProbe? { value.flatMap(DesktopProbe.init(rawValue:)) }
    /// Probe results older than this are probed again before they count.
    public static let cacheMs: Int64 = 7 * 24 * 3600 * 1000
}

/// Where one host's desktop connection is.
public enum DesktopPhase: Equatable, Sendable {
    case idle
    /// Probing, installing or starting the plugin, or waiting for the first frame.
    case connecting(step: Step, detail: String = "")
    /// The host needs the user: the `needs` of the hello, e.g. `not-logged-in`.
    case needsAction(needs: [String])
    case connected(poor: Bool = false, paused: Bool = false)
    /// The link dropped after the first frame; the last frame stays on screen.
    case recovering(sinceMs: Int64)
    case failed(message: String)

    public enum Step: Sendable { case login, install, start, firstFrame }
}

/// The desktop button on a session card.
public enum DesktopButton: Equatable, Sendable {
    case hidden, openable, connecting, needsAction, connected, poor, recovering

    /// §4.3 of the plan. `osSupported`: the pinned plugin has a build for the host's system.
    /// Linux hosts show the button only once a probe found a desktop; macOS and Windows show it unprobed.
    public static func derive(hostOnline: Bool, sessionConnected: Bool, os: String, osSupported: Bool,
                              probe: DesktopProbe?, probedAt: Int64?, now: Int64, phase: DesktopPhase) -> DesktopButton {
        // A desktop already open keeps its button whatever the session or probe say now.
        switch phase {
        case .connected(let poor, _): return poor ? .poor : .connected
        case .recovering: return .recovering
        case .connecting: return .connecting
        case .needsAction: return .needsAction
        case .idle, .failed: break
        }
        if !hostOnline || !sessionConnected || !osSupported { return .hidden }
        let fresh: DesktopProbe? = (probedAt.map { now - $0 < DesktopProbe.cacheMs } ?? false) ? probe : nil
        switch fresh {
        case .no?: return .hidden
        case .nologin?: return .needsAction
        case .yes?: return .openable
        case nil: return os == "MACOS" || os == "WINDOWS" ? .openable : .hidden
        }
    }
}
