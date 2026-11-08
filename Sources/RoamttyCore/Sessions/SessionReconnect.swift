import Foundation

/// Why a session's terminal is not connected, for Android's reconnect rules (ConnectionUiModels.kt).
public enum SessionEnd: String, Equatable, Sendable {
    /// The connection dropped while it was up.
    case dropped
    /// The session came back from the journal after the app restarted.
    case restored
    /// The host could not be reached, or did not answer in time, while connecting.
    case unreachable
    /// The user, the server or a failed login ended it.
    case ended

    /// A login that failed or was refused waits for the user; a connection lost after it was up dropped, and a host
    /// that could not be reached may be back later.
    public init(failure error: Error, wasConnected: Bool) {
        switch error as? RoamError {
        case .authentication, .hostKeyChanged, .rejected, .cancelled, .tmuxMissing, .sessionLimit, .invalid: self = .ended
        default: self = wasConnected ? .dropped : .unreachable
        }
    }
}

public enum SessionReconnect {
    /// At most one automatic reconnect per session within this window, so a host that drops at once cannot loop.
    public static let interval: TimeInterval = 10

    /// Opening such a terminal reconnects it at once instead of offering a reconnect button.
    public static func onOpen(_ end: SessionEnd?) -> Bool { end == .dropped || end == .restored }

    /// The session list also reconnects a session that gave up on an unreachable or silent host, which may be back
    /// by then; it only does so once `hostBack` says the host answers again.
    public static func fromList(_ end: SessionEnd?) -> Bool { onOpen(end) || end == .unreachable }

    /// Whether a probe measured at or after `since` found the host's sshd answering. Until then the session list leaves
    /// an offline host's sessions alone instead of showing them "connecting" again and again.
    public static func hostBack(online: Bool, checkedAt: Date?, since: Date) -> Bool {
        guard online, let checkedAt else { return false }
        return checkedAt >= since
    }

    /// Seconds to wait before the next automatic attempt of a session last tried at `last`.
    public static func delay(lastAttempt last: Date?, now: Date) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, last.addingTimeInterval(interval).timeIntervalSince(now))
    }
}
