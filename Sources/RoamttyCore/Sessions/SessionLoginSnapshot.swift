import Foundation

/// An in-memory login snapshot, never written to the session journal or credential store.
public struct SessionLoginSnapshot: Sendable {
    public let host: Host
    private var credentials: Credentials

    public init(host: Host, credentials: Credentials = Credentials()) {
        self.host = host; self.credentials = credentials
    }
    public func reconnect(using savedHost: Host) -> SessionReconnectLogin {
        if host.hasSameLoginIdentity(as: savedHost) {
            return SessionReconnectLogin(host: savedHost, usesSavedCredentials: true, retainedCredentials: nil)
        }
        return SessionReconnectLogin(host: host, usesSavedCredentials: false, retainedCredentials: credentials)
    }
    public mutating func invalidateAuthentication() {
        if let count = credentials.password?.count { credentials.password?.resetBytes(in: 0..<count) }
        credentials.password = nil; credentials.passphrase = nil
    }
    public mutating func clear() { credentials.clear() }
}

public struct SessionReconnectLogin: Sendable {
    public let host: Host
    public let usesSavedCredentials: Bool
    public let retainedCredentials: Credentials?
}
