import Foundation

/// Owns one import queue; clients only receive results on the main actor.
@MainActor final class ShareInboxWorker {
    struct Consumption {
        let urls: [URL]
        let errors: [Error]
    }
    /// Each open callback can cancel its own interest without cancelling other callers.
    private final class PendingCopy: @unchecked Sendable {
        let cancellation = ShareInboxCancellation()
        private let lock = NSLock()
        private var interested = 0
        @MainActor private(set) var observers: [(ShareInboxCancellation, @MainActor (Result<URL, Error>) -> Void)] = []
        @MainActor func observe(_ completion: @escaping @MainActor (Result<URL, Error>) -> Void) -> ShareInboxCancellation? {
            lock.lock()
            guard !cancellation.isCancelled else { lock.unlock(); return nil }
            interested += 1
            lock.unlock()
            let observer = ShareInboxCancellation(onCancel: { [weak self] in self?.cancelObserver() })
            observers.append((observer, completion))
            return observer
        }
        private func cancelObserver() {
            lock.lock(); defer { lock.unlock() }
            interested -= 1
            if interested == 0 { cancellation.cancel() }
        }
    }
    private var pendingCopies: [URL: PendingCopy] = [:]
    private let queue = DispatchQueue(label: "com.roamtty.share-import", qos: .userInitiated)
    // Acknowledge requests suppress snapshots already in flight until their ordered completion.
    private var acknowledging: [URL: Int] = [:]
    private let imports: () -> URL
    private let sharedInbox: () -> URL?
    private let consumeKeychain: (URL) -> [Error]
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void

    init(imports: @escaping () -> URL, sharedInbox: @escaping () -> URL? = { nil },
         consumeKeychain: @escaping (URL) -> [Error] = { _ in [] },
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.imports = imports; self.sharedInbox = sharedInbox; self.consumeKeychain = consumeKeychain
        self.startAccess = startAccess; self.stopAccess = stopAccess
    }
    func consume(completion: @escaping @MainActor (Consumption) -> Void) {
        let imports = imports, sharedInbox = sharedInbox, consumeKeychain = consumeKeychain
        queue.async {
            let root = imports()
            let errors = consumeKeychain(root) + Self.consumeDirectory(sharedInbox(), into: root)
            let urls = ShareImportLedger.pending(in: root)
            // A single serial worker submits every delivery to the main queue in FIFO order.
            DispatchQueue.main.async { [self] in
                completion(Consumption(urls: urls.filter { acknowledging[$0] == nil }, errors: errors))
            }
        }
    }
    @discardableResult func copyIncoming(_ url: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) -> ShareInboxCancellation {
        // Coalesce only exact URLs while a copy is in flight. Later opens remain new imports.
        if let pending = pendingCopies[url], let observer = pending.observe(completion) { return observer }
        let pending = PendingCopy()
        let observer = pending.observe(completion)!
        pendingCopies[url] = pending
        let cancellation = pending.cancellation
        // Acquire access to the original URL before the caller's open-URL callback returns.
        let accessed = startAccess(url)
        let imports = imports, stopAccess = stopAccess
        queue.async {
            let result = Result { () throws -> URL in
                defer { if accessed { stopAccess(url) } }
                try cancellation.check()
                let values = try ShareImportLedger.commit(into: imports(), id: UUID().uuidString, names: [url.lastPathComponent], cancellation: cancellation) { stage in
                    try FileManager.default.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent))
                }
                guard let destination = values.first else { throw NSError(domain: "RoamttyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared file could not be imported"]) }
                return destination
            }
            DispatchQueue.main.async { [self] in
                if pendingCopies[url] === pending { pendingCopies.removeValue(forKey: url) }
                for (observer, completion) in pending.observers {
                    do {
                        try observer.publish { }
                        completion(result)
                    } catch { completion(.failure(error)) }
                }
            }
        }
        return observer
    }
    func acknowledge(_ urls: [URL], completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        for url in urls { acknowledging[url, default: 0] += 1 }
        let imports = imports
        queue.async {
            let result = Result { try ShareImportLedger.acknowledge(urls, in: imports()) }
            DispatchQueue.main.async { [self] in
                for url in urls {
                    let remaining = (acknowledging[url] ?? 1) - 1
                    acknowledging[url] = remaining > 0 ? remaining : nil
                }
                completion(result)
            }
        }
    }
    nonisolated private static func consumeDirectory(_ shared: URL?, into root: URL) -> [Error] {
        guard let shared else { return [] }
        guard FileManager.default.fileExists(atPath: shared.path) else { return [] }
        var errors: [Error] = []
        do {
            let transactions = try FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil)
            for transaction in transactions {
                guard FileManager.default.fileExists(atPath: transaction.appendingPathComponent(".ready").path) else { continue }
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: transaction, includingPropertiesForKeys: nil)
                    let members = files.filter { $0.lastPathComponent != ".ready" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    try ShareImportLedger.commit(into: root, id: transaction.lastPathComponent, names: members.map(\.lastPathComponent)) { stage in
                        for file in members { try FileManager.default.copyItem(at: file, to: stage.appendingPathComponent(file.lastPathComponent)) }
                    }
                    // Receipt publication precedes source cleanup; cleanup failure remains retryable.
                    try? FileManager.default.removeItem(at: transaction)
                } catch { errors.append(error) }
            }
        } catch { errors.append(error) }
        return errors
    }
}
