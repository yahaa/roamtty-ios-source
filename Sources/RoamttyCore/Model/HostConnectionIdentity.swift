public extension Host {
    /// Credentials are compared separately by the credential store; display settings
    /// and the preferred mode do not change an already authenticated connection.
    func hasSameLoginIdentity(as other: Host) -> Bool {
        id == other.id && endpoint == other.endpoint && username == other.username && auth == other.auth
    }
}
