import Foundation
import RoamttyCore
import RoamttyTransport

/// Host tools follow the saved host. Session tools retain the exact runtime and SSH
/// connection that opened them, including after that host's address or user is edited.
enum RemoteConnectionTarget {
    case host(String)
    case session(String, SessionConnectionSnapshot<SessionRuntime, SSHConnection>)

    @MainActor static func session(_ runtime: SessionRuntime) -> Self {
        .session(runtime.record.id, SessionConnectionSnapshot(session: runtime, connection: runtime.ssh))
    }

    @MainActor var runtime: SessionRuntime? {
        if case .session(_, let snapshot) = self { return snapshot.session }
        return nil
    }
}
