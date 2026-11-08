/// Captures the connection that owns an operation; session IDs alone are not ownership.
public final class SessionConnectionSnapshot<Session: AnyObject, Connection: AnyObject> {
    public private(set) weak var session: Session?
    private let connection: Connection?

    public init(session: Session?, connection: Connection?) {
        self.session = session; self.connection = connection
    }

    public func resolve(currentSession: Session?, currentConnection: Connection?, connected: Bool) throws -> Connection {
        guard let session, currentSession === session, let connection,
              currentConnection === connection, connected else { throw RoamError.cancelled }
        return connection
    }
}
