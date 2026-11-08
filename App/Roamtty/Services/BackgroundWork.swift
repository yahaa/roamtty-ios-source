import Foundation
import RoamttyTransport

/// A task with the token its bookkeeping checks, so a finished task does not clear a newer one under the same key.
struct TrackedTask {
    let token: UUID
    let task: Task<Void, Never>
    var cancellation: TransferCancellation?
    func cancel() { cancellation?.cancel(); task.cancel() }
}

func performInBackground<T>(_ operation: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try operation() }) } }
}
