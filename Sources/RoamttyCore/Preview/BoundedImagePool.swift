import Foundation

/// Display handles must erase their image and every attached display reference on discard.
/// Copies of a handle may outlive a demand, but cannot keep decoded pixels alive afterwards.
@MainActor public protocol BudgetedImageResource: AnyObject {
    var decodedByteCount: Int { get }
    func discard()
}

/// Visibility-scoped image ownership. There is deliberately no cache without consumers.
/// Admission reserves the maximum output size before starting fetch/decode; completion
/// replaces the reservation with the real decoded cost. Cancelled work retains its slot
/// and reservation until its async loader returns, including non-cooperative decoders.
@MainActor public final class BoundedImagePool<Key: Hashable, Resource: BudgetedImageResource> {
    public typealias Loader = @MainActor () async throws -> Resource
    private struct Consumer { var callback: ((Resource?) -> Void)? }
    private final class Entry {
        let key: Key
        var loader: Loader?
        var consumers: [UUID: Consumer] = [:]
        var task: Task<Void, Never>?
        var resource: Resource?
        init(key: Key, loader: @escaping Loader) { self.key = key; self.loader = loader }
    }
    private let byteLimit: Int
    private let reservationBytes: Int
    private let concurrencyLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var keys: [Key: UUID] = [:]
    private var demands: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private var accountedBytes = 0
    private var active = 0
    private var runningKeys: Set<Key> = []

    public init(byteLimit: Int = 32 * 1024 * 1024, reservationBytes: Int = 16 * 1024 * 1024, concurrencyLimit: Int = 2) {
        precondition(reservationBytes > 0 && byteLimit >= reservationBytes && concurrencyLimit > 0)
        self.byteLimit = byteLimit; self.reservationBytes = reservationBytes; self.concurrencyLimit = concurrencyLimit
    }

    @discardableResult public func request(_ key: Key, load: @escaping Loader, onLoad: @escaping (Resource?) -> Void) -> UUID {
        let demand = UUID()
        let id: UUID
        let entry: Entry
        if let existing = keys[key], let found = entries[existing] { id = existing; entry = found } else {
            id = UUID(); entry = Entry(key: key, loader: load)
            keys[key] = id; entries[id] = entry; pending.append(id)
        }
        entry.consumers[demand] = Consumer(callback: entry.resource == nil ? onLoad : nil); demands[demand] = id
        if let resource = entry.resource { onLoad(resource) }
        drain()
        return demand
    }

    public func release(_ demand: UUID) {
        guard let id = demands.removeValue(forKey: demand), let entry = entries[id] else { return }
        entry.consumers.removeValue(forKey: demand)
        guard entry.consumers.isEmpty else { return }
        if keys[entry.key] == id { keys.removeValue(forKey: entry.key) }
        if let resource = entry.resource {
            let bytes = resource.decodedByteCount
            resource.discard() // Clear displays BEFORE making their bytes available again.
            accountedBytes -= bytes
            entry.resource = nil
        }
        if let task = entry.task { task.cancel() } else { entries.removeValue(forKey: id); pending.removeAll { $0 == id } }
        drain()
    }

    private func drain() {
        while !pending.isEmpty && active < concurrencyLimit && accountedBytes <= byteLimit - reservationBytes {
            // A cancelled decode may still be running. Do not overlap a replacement
            // for that key; independent queued images may use the other slot.
            guard let index = pending.firstIndex(where: { id in
                entries[id].map { !runningKeys.contains($0.key) } ?? true
            }) else { return }
            let id = pending.remove(at: index)
            guard let entry = entries[id], let loader = entry.loader else { continue }
            runningKeys.insert(entry.key)
            entry.loader = nil
            active += 1; accountedBytes += reservationBytes
            entry.task = Task {
                let result: Result<Resource, Error>
                do { result = .success(try await loader()) } catch { result = .failure(error) }
                self.complete(id, result: result)
            }
        }
    }

    private func complete(_ id: UUID, result: Result<Resource, Error>) {
        guard let entry = entries[id] else { return }
        entry.task = nil; active -= 1; accountedBytes -= reservationBytes
        runningKeys.remove(entry.key)
        var delivered: Resource?
        if case .success(let resource) = result {
            if !entry.consumers.isEmpty && resource.decodedByteCount > 0 && resource.decodedByteCount <= reservationBytes {
                entry.resource = resource; accountedBytes += resource.decodedByteCount; delivered = resource
            } else { resource.discard() }
        }
        let callbacks = entry.consumers
        // A ready entry needs consumer IDs, not their captured view/authorization context.
        for demand in entry.consumers.keys { entry.consumers[demand]?.callback = nil }
        if delivered == nil {
            if keys[entry.key] == id { keys.removeValue(forKey: entry.key) }
            entries.removeValue(forKey: id)
            for demand in callbacks.keys { demands.removeValue(forKey: demand) }
        }
        for (demand, consumer) in callbacks {
            // A callback may synchronously release another consumer.
            if delivered == nil || entry.consumers[demand] != nil { consumer.callback?(delivered) }
        }
        drain()
    }
}
