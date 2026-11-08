import UIKit
import UserNotifications
import RoamttyCore

/// The agent notifications (Android `SessionService.showAlert`): "Claude 等你确认" when an agent waits for the user,
/// "Claude 已完成" once it finished a long turn. One per session, replaced by the next and withdrawn once the agent
/// works again; none for the session on screen. Tapping one opens its session.
///
/// iOS suspends the app soon after it leaves the screen, and the status poll stops with it: `keepWatching` asks for
/// the time iOS grants a task to finish (about half a minute), and what changes after that is told once the app is back.
@MainActor final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    private let center = UNUserNotificationCenter.current()
    /// The notification each session shows now.
    private(set) var shown: [String: AgentAlerts.Kind] = [:]
    /// The session whose terminal is on screen, if any; set by the app model.
    var viewing: () -> String? = { nil }
    /// Opens a session's terminal; set by the app model. A tap that launched the app waits for it.
    var open: ((String) -> Void)? { didSet { if let pending, let open { self.pending = nil; open(pending) } } }
    private var pending: String?
    private var askedPermission = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// Before the app finishes launching, so a tap that launched it is delivered.
    func install() { center.delegate = self }

    /// Asks once per launch; iOS shows its question only the first time.
    func requestPermission() {
        guard !askedPermission else { return }
        askedPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func identifier(_ session: String) -> String { "agent-" + session }

    /// The app is in front and shows `session`'s terminal: its agent speaks for itself there.
    private func onScreen(_ session: String) -> Bool { UIApplication.shared.applicationState != .background && viewing() == session }

    func show(_ kind: AgentAlerts.Kind, session: String, title: String, body: String) {
        if onScreen(session) { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = Self.identifier(session)
        content.userInfo = ["session": session]
        // A request waits for the user and sounds; a finished turn only goes to the list, like Android's quiet channel.
        content.sound = kind == .waiting ? .default : nil
        content.interruptionLevel = kind == .waiting ? .active : .passive
        center.add(UNNotificationRequest(identifier: Self.identifier(session), content: content, trigger: nil))
        shown[session] = kind
    }

    /// Also removes one an earlier launch left: sessions keep their ids in the journal.
    func withdraw(_ session: String) {
        shown[session] = nil
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(session)])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(session)])
    }

    /// Takes back the notifications the user no longer wants.
    func apply(_ setting: AgentNotifications) {
        for (session, kind) in shown where !setting.allows(kind) { withdraw(session) }
    }

    /// Keeps the app running in the background for as long as iOS allows, so an agent that is still at work can
    /// still be heard from; `false` gives the time back.
    func keepWatching(_ on: Bool) {
        if on, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Agent status") { [weak self] in self?.keepWatching(false) }
        } else if !on, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // The completion-handler forms, finished on the main thread: the async forms finish on another one, and UIKit
    // then aborts the app as it comes to the front from the tap.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let session = notification.request.content.userInfo["session"] as? String
        let quiet = notification.request.content.interruptionLevel == .passive
        Task { @MainActor in
            // In the app as outside it: a finished turn goes to the list without a banner.
            completionHandler(session.map(self.onScreen) ?? false ? [] : quiet ? [.list] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let session = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            if tapped, let session {
                self.shown[session] = nil
                if let open = self.open { open(session) } else { self.pending = session }
            }
            completionHandler()
        }
    }
}
