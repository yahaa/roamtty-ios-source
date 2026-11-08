import Foundation

/// Cancellation belongs to one transfer job, including its recursive children.
/// It never tears down a host's terminal or another job's channels.
public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
