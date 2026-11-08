import Foundation

/// Logins typed or unlocked during this run, kept in memory per host, and the hosts whose saved password failed.
/// Forgetting a login wipes its secrets before letting it go.
public struct CredentialCache: Sendable {
    private var cached: [String: Credentials] = [:]
    private var invalid = Set<String>()

    public init() {}

    public subscript(hostID: String) -> Credentials? { cached[hostID] }

    public mutating func store(_ credentials: Credentials, for hostID: String) { cached[hostID] = credentials }

    /// Wipes and drops the host's cached login.
    public mutating func forget(_ hostID: String) {
        cached[hostID]?.clear(); cached.removeValue(forKey: hostID)
    }

    /// Wipes and drops every cached login.
    public mutating func forgetAll() {
        for id in Array(cached.keys) { cached[id]?.clear() }
        cached.removeAll()
    }

    /// The host refused its login: forget it, and stop offering its saved password until the host is edited.
    public mutating func rejectLogin(_ hostID: String) {
        forget(hostID); invalid.insert(hostID)
    }

    /// Offers the saved password again.
    public mutating func acceptSavedPassword(_ hostID: String) { invalid.remove(hostID) }

    public func savedPasswordRejected(_ hostID: String) -> Bool { invalid.contains(hostID) }
}
