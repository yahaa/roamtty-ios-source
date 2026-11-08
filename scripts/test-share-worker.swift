import Foundation

@main @MainActor enum ShareWorkerChecks {
    struct Failed: Error { let message: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failed(message: message) }
    }
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("share-worker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("imports")
        var rootOnMain = false
        let worker = ShareInboxWorker(imports: { rootOnMain = Thread.isMainThread; return root })
        let consumed = await withCheckedContinuation { continuation in
            worker.consume { value in continuation.resume(returning: value) }
        }
        try expect(!rootOnMain, "Inbox filesystem work must execute off the main thread")
        try expect(consumed.urls.isEmpty && consumed.errors.isEmpty, "An empty inbox must consume cleanly")
        print("Share inbox worker background check passed")
        try await overlap(in: base)
        print("Share inbox worker ordered publication check passed")
        try await scopeAndCancellation(in: base)
        print("Share inbox worker scope, cancellation and failure cleanup checks passed")
        try await directoryRecovery(in: base)
        print("Share inbox worker directory recovery and error delivery checks passed")
        try await acknowledgementFailure(in: base)
        print("Share inbox worker acknowledgement error and retry checks passed")
        try await repeatedOpen(in: base)
        print("Share inbox worker simultaneous-open dedup and observer cancellation checks passed")
    }
    static func waitForWorker(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { semaphore.wait(); continuation.resume() }
        }
    }
    static func overlap(in base: URL) async throws {
        let root = base.appendingPathComponent("overlap")
        let files = try ShareImportLedger.commit(into: root, id: UUID().uuidString, names: ["queued.txt"]) { stage in
            try Data("queued".utf8).write(to: stage.appendingPathComponent("queued.txt"))
        }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var first = true
        let worker = ShareInboxWorker(imports: { root }, consumeKeychain: { _ in
            if first { first = false; started.signal(); release.wait() }
            return []
        })
        var publications: [[URL]] = [], order: [String] = [], acknowledgementError: Error?
        worker.consume { value in
            dispatchPrecondition(condition: .onQueue(.main))
            publications.append(value.urls); order.append("consume-before")
        }
        await waitForWorker(started)
        // This acknowledgement is queued while the old consume is still in flight.
        worker.acknowledge(files) { result in
            dispatchPrecondition(condition: .onQueue(.main))
            if case .failure(let error) = result { acknowledgementError = error }
            order.append("acknowledge")
        }
        let last = await withCheckedContinuation { continuation in
            worker.consume { value in
                dispatchPrecondition(condition: .onQueue(.main))
                order.append("consume-after"); continuation.resume(returning: value)
            }
            release.signal()
        }
        try expect(acknowledgementError == nil, "Acknowledgement must succeed")
        try expect(publications == [[]], "An in-flight consume must not republish a URL being acknowledged")
        try expect(order == ["consume-before", "acknowledge", "consume-after"], "Callbacks must preserve persistence order")
        try expect(last.urls.isEmpty && ShareImportLedger.pending(in: root).isEmpty, "Repeated consume must not revive acknowledged imports")
        try expect(!FileManager.default.fileExists(atPath: files[0].path), "Acknowledgement must remove the private copy")
    }

    final class ScopeProbe {
        private let lock = NSLock()
        private var opened: [URL] = [], closed: [URL] = []
        func start(_ url: URL) -> Bool { lock.withLock { opened.append(url) }; return true }
        func stop(_ url: URL) { lock.withLock { closed.append(url) } }
        var counts: (Int, Int) { lock.withLock { (opened.count, closed.count) } }
        var balanced: Bool { lock.withLock { opened == closed } }
        var accessedURLs: [URL] { lock.withLock { opened } }
    }
    static func scopeAndCancellation(in base: URL) async throws {
        let root = base.appendingPathComponent("scoped")
        let original = base.appendingPathComponent("external.txt")
        try Data("external contents".utf8).write(to: original)
        let alias = base.appendingPathComponent("external-container-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        let source = alias.appendingPathComponent("external.txt")
        let probe = ScopeProbe()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = ShareInboxWorker(imports: { root }, consumeKeychain: { _ in
            started.signal(); release.wait(); return []
        }, startAccess: probe.start, stopAccess: probe.stop)
        worker.consume { _ in }
        await waitForWorker(started)
        let cancelled: Result<URL, Error> = await withCheckedContinuation { continuation in
            let token = worker.copyIncoming(source) { result in continuation.resume(returning: result) }
            // Access must be acquired before enqueueing returns, and remain held while queued.
            precondition(probe.counts == (1, 0))
            token.cancel()
            release.signal()
        }
        guard case .failure(let cancellation) = cancelled else { throw Failed(message: "Cancellation before queued copy starts must not import a file") }
        try expect((cancellation as NSError).code == NSUserCancelledError, "Cancellation must be delivered to the caller")
        try expect(probe.balanced, "Cancelled copies must release the original security scope")
        try expect(ShareImportLedger.pending(in: root).isEmpty, "Cancelled copies must not publish a receipt")

        let ordinary = ShareInboxWorker(imports: { root }, startAccess: probe.start, stopAccess: probe.stop)
        let failed: Result<URL, Error> = await withCheckedContinuation { continuation in
            ordinary.copyIncoming(base.appendingPathComponent("missing.txt")) { continuation.resume(returning: $0) }
        }
        guard case .failure = failed else { throw Failed(message: "Missing external files must report a copy error") }
        try expect(probe.balanced, "Failed copies must release security scope")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        try expect(leftovers.isEmpty, "Failed copies must remove their staging directories")
        let successful: Result<URL, Error> = await withCheckedContinuation { continuation in
            ordinary.copyIncoming(source) { continuation.resume(returning: $0) }
        }
        let imported = try successful.get()
        try expect(tryData(imported) == Data("external contents".utf8), "Successful copies must preserve file contents")
        try expect(probe.balanced && probe.counts == (3, 3), "Successful copies must release scope before delivering completion")
        try expect(probe.accessedURLs == [source, base.appendingPathComponent("missing.txt"), source], "Scope acquisition must use the original external URL before resolving aliases")
        try expect(ShareImportLedger.pending(in: root) == [imported], "Imported URLs must match subsequent consumption")

        var stoppedWithoutAccess = false
        let noScope = ShareInboxWorker(imports: { root }, startAccess: { _ in false }, stopAccess: { _ in stoppedWithoutAccess = true })
        let _: Result<URL, Error> = await withCheckedContinuation { continuation in
            noScope.copyIncoming(source) { continuation.resume(returning: $0) }
        }
        try expect(!stoppedWithoutAccess, "A URL without granted scope must not receive stopAccess")
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    static func directoryRecovery(in base: URL) async throws {
        let root = base.appendingPathComponent("directory-imports")
        let inbox = base.appendingPathComponent("Inbox")
        let transaction = inbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try Data().write(to: transaction.appendingPathComponent(".ready"))
        try Data("shared".utf8).write(to: transaction.appendingPathComponent("shared.txt"))
        let broken = inbox.appendingPathComponent("invalid-transaction")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data().write(to: broken.appendingPathComponent(".ready"))
        try Data("retry".utf8).write(to: broken.appendingPathComponent("retry.txt"))
        let worker = ShareInboxWorker(imports: { root }, sharedInbox: { inbox })
        let first = await withCheckedContinuation { continuation in worker.consume { continuation.resume(returning: $0) } }
        let second = await withCheckedContinuation { continuation in worker.consume { continuation.resume(returning: $0) } }
        try expect(first.urls.count == 1 && first.urls == second.urls, "Repeated consumption must return one stable committed import")
        try expect(first.errors.count == 1 && second.errors.count == 1, "Failed imports must report errors on every retry")
        try expect(!FileManager.default.fileExists(atPath: transaction.path), "A committed transaction must clean its source")
        try expect(FileManager.default.fileExists(atPath: broken.appendingPathComponent("retry.txt").path), "Failed transactions must preserve source files for retry")
    }

    static func acknowledgementFailure(in base: URL) async throws {
        let root = base.appendingPathComponent("acknowledgement-failure")
        let files = try ShareImportLedger.commit(into: root, id: UUID().uuidString, names: ["retry.txt"]) { stage in
            try Data("retry".utf8).write(to: stage.appendingPathComponent("retry.txt"))
        }
        let folder = files[0].deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let worker = ShareInboxWorker(imports: { root })
        let failed: Result<Void, Error> = await withCheckedContinuation { continuation in
            worker.acknowledge(files) { continuation.resume(returning: $0) }
        }
        guard case .failure = failed else { throw Failed(message: "Receipt persistence failure must reach the acknowledgement caller") }
        let recovered = await withCheckedContinuation { continuation in worker.consume { continuation.resume(returning: $0) } }
        try expect(recovered.urls == files, "Failed acknowledgement must retain the receipt and release publication suppression")
        try expect(FileManager.default.fileExists(atPath: files[0].path), "Failed acknowledgement must retain the private file")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let retry: Result<Void, Error> = await withCheckedContinuation { continuation in
            worker.acknowledge(files) { continuation.resume(returning: $0) }
        }
        try retry.get()
        try expect(ShareImportLedger.pending(in: root).isEmpty, "Acknowledgement must succeed after persistence is restored")
    }

    static func repeatedOpen(in base: URL) async throws {
        let root = base.appendingPathComponent("repeated-open")
        let source = base.appendingPathComponent("repeat.txt")
        try Data("repeat".utf8).write(to: source)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let scope = ScopeProbe()
        let worker = ShareInboxWorker(imports: { root }, consumeKeychain: { _ in
            started.signal(); release.wait(); return []
        }, startAccess: scope.start, stopAccess: scope.stop)
        worker.consume { _ in }
        await waitForWorker(started)
        var first: Result<URL, Error>?, second: Result<URL, Error>?
        let third: Result<URL, Error> = await withCheckedContinuation { continuation in
            let cancelledObserver = worker.copyIncoming(source) { first = $0 }
            worker.copyIncoming(source) { second = $0 }
            worker.copyIncoming(source) { continuation.resume(returning: $0) }
            cancelledObserver.cancel()
            release.signal()
        }
        guard case .failure(let error)? = first, (error as NSError).code == NSUserCancelledError else {
            throw Failed(message: "A cancelled observer must receive cancellation")
        }
        let imported = try third.get()
        let other = try second?.get()
        try expect(imported == other, "Simultaneous opens must share one transaction without cancelling another observer's demand")
        try expect(ShareImportLedger.pending(in: root) == [imported], "Simultaneous opens must publish only one private copy")
        try expect(scope.balanced && scope.counts == (1, 1), "A coalesced operation must balance one original security scope")
        let later: Result<URL, Error> = await withCheckedContinuation { continuation in
            worker.copyIncoming(source) { continuation.resume(returning: $0) }
        }
        let laterURL = try later.get()
        try expect(laterURL != imported && ShareImportLedger.pending(in: root).count == 2, "A later deliberate open must create a fresh transaction")
        try expect(scope.balanced && scope.counts == (2, 2), "Later opens must acquire and release their own scope")
    }

}
