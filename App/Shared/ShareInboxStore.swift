import Foundation
#if canImport(Security)
import Security
#endif

/// Cancellation and publication have one ordering: once cancelled, no ready record can be written.
final class ShareInboxCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var published = false
    private let onCancel: (() -> Void)?
    init(onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    @discardableResult func cancel() -> Bool {
        lock.lock()
        guard !published else { lock.unlock(); return false }
        let notify = !cancelled
        cancelled = true
        lock.unlock()
        // Observer cancellation may take another lock; never invoke it while holding ours.
        if notify { onCancel?() }
        return true
    }
    func check() throws {
        if isCancelled { throw NSError(domain: "RoamttyShare", code: NSUserCancelledError) }
    }
    func publish(_ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw NSError(domain: "RoamttyShare", code: NSUserCancelledError) }
        try operation(); published = true
    }
}

/// Durable import ledger. Empty receipts prevent interrupted source cleanup from replaying uploaded files.
enum ShareImportLedger {
    private struct Receipt: Codable { let id: String; var names: [String] }
    private static let lock = NSRecursiveLock()
    private static func failure(_ message: String) -> NSError { NSError(domain: "RoamttyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != ".ready" && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static func receipt(in folder: URL) -> Receipt? {
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              let data = try? Data(contentsOf: folder.appendingPathComponent(".ready")),
              let value = try? JSONDecoder().decode(Receipt.self, from: data), value.id == folder.lastPathComponent,
              value.names.count <= 20, value.names.allSatisfy(safeName), Set(value.names).count == value.names.count else { return nil }
        return value
    }
    private static func pending(_ value: Receipt, folder: URL) -> [URL] {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        return value.names.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func pending(in root: URL) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { folder in
            receipt(in: folder).map { pending($0, folder: folder) } ?? []
        }
    }
    @discardableResult static func commit(into root: URL, id: String, names: [String], cancellation: ShareInboxCancellation? = nil, writeContents: (URL) throws -> Void) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        try cancellation?.check()
        guard UUID(uuidString: id) != nil else { throw failure("Invalid shared transaction") }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(id, isDirectory: true)
        if let existing = receipt(in: folder) { return pending(existing, folder: folder) }
        guard !names.isEmpty, names.count <= 20, names.allSatisfy(safeName), Set(names).count == names.count else { throw failure("Invalid shared file names") }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw failure("An existing import could not be verified; it was left untouched") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stage.path)
        #endif
        try writeContents(stage)
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: stage.appendingPathComponent($0).path) }) else { throw failure("Shared content is incomplete") }
        #if os(iOS)
        if let members = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let member as URL in members {
                guard (try member.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw failure("Shared symbolic links are not supported") }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: member.path)
            }
        }
        #endif
        let value = Receipt(id: id, names: names)
        try write(value, in: stage)
        // Same-volume directory rename publishes files and receipt together.
        if let cancellation {
            try cancellation.publish { try FileManager.default.moveItem(at: stage, to: folder) }
        } else {
            try FileManager.default.moveItem(at: stage, to: folder)
        }
        return pending(value, folder: folder)
    }
    static func acknowledge(_ urls: [URL], in root: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let groups = Dictionary(grouping: urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }) { $0.deletingLastPathComponent() }
        for (folder, files) in groups {
            guard folder.deletingLastPathComponent().path == base.path, var value = receipt(in: folder) else { continue }
            let acknowledged = Set(files.map(\.lastPathComponent)).intersection(value.names)
            guard !acknowledged.isEmpty else { continue }
            value.names.removeAll { acknowledged.contains($0) }
            // Persist the remaining queue before removing uploaded private copies.
            try write(value, in: folder)
            for name in acknowledged { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }
    private static func write(_ value: Receipt, in folder: URL) throws {
        let url = folder.appendingPathComponent(".ready")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
}

#if canImport(Security)
/// Device-only Keychain fallback for profiles without the App Group entitlement.
enum ShareInboxStore {
    private static let service = "com.roamtty.share-inbox"
    private static let chunkSize = 64 * 1024
    private static let maximumBytes = 64 * 1024 * 1024
    private struct Item: Codable { let name: String; let count: Int; let size: Int }
    private struct Manifest: Codable { let id: String; let created: Date; let items: [Item] }
    private struct Account { let name: String; let created: Date? }
    static var groupContainer: URL? {
        guard Bundle.main.object(forInfoDictionaryKey: "RoamttyAppGroupEnabled") as? String == "YES" else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.roamtty.shared")
    }
    private static func query(_ account: String? = nil) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RoamttySharedKeychainGroup") as? String, !group.isEmpty, !group.contains("$(") else { throw failure("Shared inbox is unavailable") }
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group, kSecAttrSynchronizable as String: false]
        if let account { value[kSecAttrAccount as String] = account }
        return value
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: service, code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func write(_ data: Data, account: String) throws {
        var value = try query(account)
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw failure("Unable to save shared content") }
    }
    private static func read(_ account: String) throws -> Data {
        var value = try query(account); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw failure("Shared content is incomplete") }
        return data
    }
    @discardableResult private static func remove(_ account: String) -> Bool {
        guard let value = try? query(account) else { return false }
        let status = SecItemDelete(value as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    private static func absent(_ account: String) -> Bool {
        guard let value = try? query(account) else { return false }
        return SecItemCopyMatching(value as CFDictionary, nil) == errSecItemNotFound
    }
    private static func accounts() throws -> [Account] {
        var value = try query(); value[kSecReturnAttributes as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?; let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw failure("Unable to read shared inbox") }
        return (result as? [[String: Any]] ?? []).compactMap { value in
            guard let name = value[kSecAttrAccount as String] as? String else { return nil }
            return Account(name: name, created: value[kSecAttrCreationDate as String] as? Date)
        }
    }
    @discardableResult static func save(directory: URL, cancellation: ShareInboxCancellation) throws -> String {
        try cancellation.check()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty, files.count <= 20 else { throw failure("Share between 1 and 20 files") }
        let id = UUID().uuidString
        var written: [String] = []; var items: [Item] = []; var total = 0
        do {
            for (index, url) in files.enumerated() {
                try cancellation.check()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= maximumBytes - total else { throw failure("Shared files must total 64 MiB or less") }
                total += size
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var chunks = 0; var actual = 0
                while try autoreleasepool(invoking: { () throws -> Bool in
                    try cancellation.check()
                    guard let bytes = try file.read(upToCount: chunkSize), !bytes.isEmpty else { return false }
                    actual += bytes.count
                    guard actual <= size else { throw failure("Shared file changed while copying") }
                    let account = "\(id)/\(index)/\(chunks)"
                    try write(bytes, account: account); written.append(account); chunks += 1
                    return true
                }) { }
                guard actual == size else { throw failure("Shared file changed while copying") }
                items.append(Item(name: url.lastPathComponent, count: chunks, size: size))
            }
            let manifest = try JSONEncoder().encode(Manifest(id: id, created: Date(), items: items))
            try cancellation.publish { try write(manifest, account: id + "/ready") }
        } catch { for account in written { remove(account) }; throw error }
        return id
    }
    static func consume(into root: URL, reportError: (Error) -> Void = { _ in }) -> [URL] {
        consume(into: root, transactionID: nil, reportError: reportError)
    }
    private static func consume(into root: URL, transactionID: String?, reportError: (Error) -> Void = { _ in }) -> [URL] {
        let records: [Account]
        do { records = try accounts() } catch { reportError(error); return ShareImportLedger.pending(in: root) }
        let names = records.map(\.name)
        for account in names where account.hasSuffix("/ready") && (transactionID == nil || account == transactionID! + "/ready") {
            do {
                let data = try read(account)
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                guard UUID(uuidString: manifest.id) != nil, account == manifest.id + "/ready", !manifest.items.isEmpty, manifest.items.count <= 20 else { throw failure("Invalid shared transaction") }
                try ShareImportLedger.commit(into: root, id: manifest.id, names: manifest.items.map(\.name)) { stage in
                    var total = 0
                    for (index, item) in manifest.items.enumerated() {
                        guard item.count >= 0, item.count <= maximumBytes / chunkSize, item.size >= 0, item.size <= maximumBytes - total else { throw failure("Invalid shared content") }
                        total += item.size
                        let url = stage.appendingPathComponent(item.name)
                        try Data().write(to: url, options: .withoutOverwriting)
                        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                        var size = 0
                        for chunk in 0..<item.count {
                            let bytes = try read("\(manifest.id)/\(index)/\(chunk)")
                            guard bytes.count <= chunkSize, bytes.count <= item.size - size else { throw failure("Invalid shared content size") }
                            size += bytes.count; try file.write(contentsOf: bytes)
                        }
                        guard size == item.size else { throw failure("Incomplete shared content") }
                        try file.synchronize()
                    }
                }
                // Local receipt owns recovery. Removing publication first makes interrupted
                // source cleanup leave only orphan chunks, never a broken ready entry.
                if remove(account) { for member in names where member.hasPrefix(manifest.id + "/") && member != account { remove(member) } }
            } catch { reportError(error) /* Keep the source transaction and any committed import untouched. */ }
        }
        if transactionID == nil { cleanupOrphans(records) }
        return ShareImportLedger.pending(in: root)
    }
    #if DEBUG
    /// Runs only for an explicit device-validation request and never consumes other inbox transactions.
    static func runDeviceSelfTest() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ShareInboxValidation-" + UUID().uuidString, isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let imports = base.appendingPathComponent("imports", isDirectory: true)
        var transaction: String?
        defer {
            if let transaction, let records = try? accounts() { for item in records where item.name.hasPrefix(transaction + "/") { remove(item.name) } }
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let expected = Data((0..<(chunkSize * 2 + 37)).map { UInt8($0 % 251) })
        try expected.write(to: source.appendingPathComponent("chunked.bin"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let id = try save(directory: source, cancellation: ShareInboxCancellation()); transaction = id
        let files = consume(into: imports, transactionID: id)
        guard files.count == 2, let chunked = files.first(where: { $0.lastPathComponent == "chunked.bin" }), let empty = files.first(where: { $0.lastPathComponent == "empty.txt" }),
              try Data(contentsOf: chunked) == expected, try Data(contentsOf: empty).isEmpty else { throw failure("Shared Keychain round-trip did not preserve fixture contents") }
        guard ShareImportLedger.pending(in: imports).count == 2 else { throw failure("Shared imports did not survive rediscovery") }
        try ShareImportLedger.acknowledge([chunked], in: imports)
        guard ShareImportLedger.pending(in: imports) == [empty] else { throw failure("Shared import acknowledgement did not preserve the remaining file") }
        try ShareImportLedger.acknowledge([empty], in: imports)
        guard consume(into: imports, transactionID: id).isEmpty else { throw failure("Completed shared imports were replayed") }
        let cancelled = ShareInboxCancellation(); cancelled.cancel()
        do {
            _ = try save(directory: source, cancellation: cancelled)
            throw failure("Cancelled shared transaction was published")
        } catch let error as NSError where error.code == NSUserCancelledError { }
        return "Shared Keychain: 3 data chunks plus empty file preserved; rediscovery, acknowledgement and cancellation passed"
    }
    #endif
    private static func cleanupOrphans(_ records: [Account]) {
        let groups = Dictionary(grouping: records) { String($0.name.split(separator: "/").first ?? "") }
        let cutoff = Date().addingTimeInterval(-86_400)
        for (id, members) in groups {
            guard UUID(uuidString: id) != nil, !members.contains(where: { $0.name == id + "/ready" }),
                  members.allSatisfy({ $0.created.map { $0 < cutoff } == true }), absent(id + "/ready") else { continue }
            for member in members { remove(member.name) }
        }
    }
}
#endif
