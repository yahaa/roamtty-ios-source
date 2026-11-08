import Foundation
import RoamttyCore

/// The agent notifications (`AgentNotifier`): what each session's status poll reports decides them.
extension AppModel {
    func installAgentNotifications() {
        let notifier = AgentNotifier.shared
        notifier.viewing = { [weak self] in
            guard let self, self.foreground, case .terminal(let id)? = self.path.last else { return nil }
            return id
        }
        notifier.open = { [weak self] id in self?.openNotified(id) }
    }

    /// Tells the user of `runtime`'s agent as its report moved from `previous` to `current`.
    func agentReported(_ runtime: SessionRuntime, previous: AgentStatus?, current: AgentStatus?) {
        let id = runtime.record.id, notifier = AgentNotifier.shared, setting = settings.agentNotifications
        // iOS asks the user once; the first agent seen is when the notifications become of use.
        if current != nil, foreground, setting != .off { notifier.requestPermission() }
        switch AgentAlerts.next(previous, current, shown: notifier.shown[id]) {
        case .show(let kind):
            guard let current else { return }
            // One the user turned off still replaces what the session showed, which is out of date now.
            guard setting.allows(kind) else { notifier.withdraw(id); return }
            let agent = CodingAgent.fromCommand(current.agent) ?? runtime.launchedAgent
            notifier.show(kind, session: id, title: AgentAlerts.title(kind, agent: agent, english: english),
                          body: AgentAlerts.text(kind, host: runtime.host.name, status: current, english: english))
        case .withdraw: notifier.withdraw(id)
        case .keep: break
        }
    }

    /// A tapped notification's session, over whatever was on screen; one closed since is not opened.
    func openNotified(_ id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        sheet = nil; drawer = false
        openSession(record)
    }
}
