import Foundation

/// Tokens that tell whether work started for a host, or for one owner of a login (a session or a host's tools), is
/// still wanted. Editing a host or cancelling an owner moves its generation on, so callbacks of the older attempt
/// see they are stale and drop their results.
public struct ConnectionGenerations: Sendable {
    private var hosts: [String: UUID] = [:]
    private var owners: [String: UUID] = [:]

    public init() {}

    /// The host's current generation, created on first use.
    public mutating func host(_ id: String) -> UUID {
        if let value = hosts[id] { return value }
        let value = UUID(); hosts[id] = value; return value
    }

    /// The owner's current generation, created on first use.
    public mutating func owner(_ id: String) -> UUID {
        if let value = owners[id] { return value }
        let value = UUID(); owners[id] = value; return value
    }

    /// Makes everything started for the host stale.
    public mutating func invalidateHost(_ id: String) { hosts[id] = UUID() }

    /// Makes everything started for the owner stale.
    public mutating func invalidateOwner(_ id: String) { owners[id] = UUID() }

    /// Whether `host` and, when given, `owner` are still at the generations an attempt started with.
    public func isCurrent(host id: String, generation: UUID, owner: String?, ownerGeneration: UUID?) -> Bool {
        guard hosts[id] == generation else { return false }
        return owner.map { owners[$0] == ownerGeneration } ?? true
    }

    /// Marks the start of work for `host` on behalf of `owner` (none: the host alone decides).
    public mutating func attempt(host id: String, owner: String?) -> ConnectionAttempt {
        ConnectionAttempt(host: id, hostGeneration: host(id), owner: owner, ownerGeneration: owner.map { self.owner($0) })
    }

    /// Whether neither the attempt's host nor its owner moved on since it started.
    public func isCurrent(_ attempt: ConnectionAttempt) -> Bool {
        isCurrent(host: attempt.host, generation: attempt.hostGeneration, owner: attempt.owner, ownerGeneration: attempt.ownerGeneration)
    }
}

/// The generations a piece of work started at, kept by its callbacks to tell whether their results are still wanted.
public struct ConnectionAttempt: Equatable, Sendable {
    public let host: String
    public let hostGeneration: UUID
    public let owner: String?
    public let ownerGeneration: UUID?
}
