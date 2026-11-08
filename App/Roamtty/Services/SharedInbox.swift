import Foundation

@MainActor enum SharedInbox {
    nonisolated private static var imports: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let name = ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"],
           name.hasPrefix("UI-"), !name.contains("/"), !name.contains("\\") {
            // Keep each test's recovered queue separate from previous runs and real imports.
            return documents.appendingPathComponent("UITestImports", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
        #endif
        return documents.appendingPathComponent("Imports", isDirectory: true)
    }
    private static let worker = ShareInboxWorker(imports: { imports }, sharedInbox: {
        ShareInboxStore.groupContainer?.appendingPathComponent("Inbox", isDirectory: true)
    }, consumeKeychain: { root in
        var errors: [Error] = []
        _ = ShareInboxStore.consume(into: root) { errors.append($0) }
        return errors
    })

    static func consume(completion: @escaping @MainActor (ShareInboxWorker.Consumption) -> Void) {
        worker.consume(completion: completion)
    }
    @discardableResult static func copyIncoming(_ url: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) -> ShareInboxCancellation {
        worker.copyIncoming(url, completion: completion)
    }
    static func acknowledge(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.acknowledge(urls) { continuation.resume(with: $0) }
        }
    }
}
