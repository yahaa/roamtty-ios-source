import Foundation
import RoamttyCore

extension SSHConnection {
    /// mosh-server inherits the authenticated SSH connection's local address (-s), not an arbitrary client-supplied endpoint.
    public func startMosh(mode: SessionMode, remoteName: String, existing: Bool = false) throws -> MoshTransport {
        if mode == .tmux, try exec(RemoteCommands.tmuxProbe).status != 0 { throw RoamError.tmuxMissing }
        // mosh-server listens only on the address this SSH login reached; resolving the name again may pick another.
        guard let peer = peerAddress else { throw RoamError.transport("mosh 不可用，使用 SSH / mosh unavailable") }
        let lifetime = mode == .tmux ? 900 : 43800
        let attached = mode == .tmux ? " -- " + RemoteCommands.shell(RemoteCommands.tmuxAttach(remoteName, existing: existing)) : ""
        for locale in ["en_US.UTF-8", "C.UTF-8"] {
            let command = RemoteCommands.pathSetup + "; MOSH_SERVER_NETWORK_TMOUT=\(lifetime) mosh-server new -s -c 256 -l LANG=\(locale)" + attached
            let output = try exec(RemoteCommands.shell(command), timeout: 15).text
            if let connect = Mosh.parseConnect(output) { return try MoshTransport(host: peer, port: connect.port, key: connect.key) }
            if !output.contains("UTF-8") { break }
        }
        throw RoamError.transport("mosh 不可用，使用 SSH / mosh unavailable")
    }
}
