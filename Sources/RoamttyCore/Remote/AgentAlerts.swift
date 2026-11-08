// Behavioral port of Roamtty Android's AgentAlerts.kt: when a session's agent is worth a system notification.
import Foundation

/// When a session's agent is worth a notification, read from the reports its status poll gives: it waits for the
/// user, or it finished a turn that worked at least `minDoneSeconds`. Each session has at most one; it goes once the
/// agent works again, or the request it showed is gone.
public enum AgentAlerts {
    public enum Kind: String, CaseIterable, Sendable { case waiting, done }

    /// What a session's notification does on a new report.
    public enum Change: Equatable, Sendable { case show(Kind), withdraw, keep }

    /// Turns shorter than this end without a notification: the user is likely still looking.
    public static let minDoneSeconds: Int64 = 60

    /// The change `current` calls for after `previous`, with `shown` the notification the session has now.
    public static func next(_ previous: AgentStatus?, _ current: AgentStatus?, shown: Kind?) -> Change {
        guard let current else {
            // The agent left; what it finished still stands, a request it made does not.
            return shown == .waiting ? .withdraw : .keep
        }
        switch current.state {
        case .waiting:
            guard let previous, previous.state == .waiting, previous.tool == current.tool, previous.detail == current.detail else { return .show(.waiting) }
            return .keep
        case .working: return shown != nil ? .withdraw : .keep
        case .idle:
            if (current.workedSeconds ?? 0) >= minDoneSeconds && !sameTurn(previous, current) { return .show(.done) }
            return shown == .waiting ? .withdraw : .keep
        }
    }

    /// A report of the turn `previous` already told of: polls repeat it until the next one.
    private static func sameTurn(_ previous: AgentStatus?, _ current: AgentStatus) -> Bool {
        guard let previous, previous.state == .idle else { return false }
        return previous.task == current.task && previous.workedSeconds == current.workedSeconds && previous.reply == current.reply
    }

    /// "Claude 等你确认", "Codex 已完成"; `agent` nil for one this app does not know.
    public static func title(_ kind: Kind, agent: CodingAgent?, english: Bool) -> String {
        let name = agent?.shortLabel ?? "Agent"
        switch kind {
        case .waiting: return english ? "\(name) needs you" : "\(name) 等你确认"
        case .done: return english ? "\(name) finished" : "\(name) 已完成"
        }
    }

    /// One line: the host, then what the agent asks to run, or how long it worked and the start of its answer.
    public static func text(_ kind: Kind, host: String, status: AgentStatus, english: Bool) -> String {
        let parts: [String]
        switch kind {
        case .waiting: parts = [host, status.detail.isEmpty ? status.tool : status.detail]
        case .done: parts = [host, status.workedSeconds.map { durationText($0, english: english) } ?? "", replyPreview(status.reply)]
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
    }
}

/// Which agent notifications the user wants, the one notification setting in the app.
public enum AgentNotifications: String, Codable, CaseIterable, Sendable {
    case all, waitingOnly, off

    public func allows(_ kind: AgentAlerts.Kind) -> Bool {
        switch self {
        case .all: return true
        case .waitingOnly: return kind == .waiting
        case .off: return false
        }
    }

    public func label(english: Bool) -> String {
        switch self {
        case .all: return english ? "When an agent needs you or finishes" : "等你确认和完成时"
        case .waitingOnly: return english ? "Only when an agent needs you" : "只在等你确认时"
        case .off: return english ? "Off" : "不提醒"
        }
    }
}
