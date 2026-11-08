import Foundation
import CNative

/// One serialized SQLite connection. Hosts and journal are relational; trust outlives a host profile.
public final class AppStore: PinStore {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        let memory = url.lastPathComponent == ":memory:"
        if !memory { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open_v2(memory ? ":memory:" : url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw RoamError.invalid("无法打开数据库 / Cannot open database")
        }
        sqlite3_busy_timeout(db, 5000)
        // swiftlint:disable:next line_length - the schema is one SQL batch
        try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS hosts(id TEXT PRIMARY KEY, json BLOB NOT NULL); CREATE TABLE IF NOT EXISTS pins(endpoint TEXT PRIMARY KEY, algorithm TEXT NOT NULL, key BLOB NOT NULL); CREATE TABLE IF NOT EXISTS journal(id TEXT PRIMARY KEY, host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE, json BLOB NOT NULL); CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL); PRAGMA user_version=1;")
        if !memory {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            var root = url.deletingLastPathComponent()
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try root.setResourceValues(flags)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            #endif
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw RoamError.invalid("数据库写入失败 / Database write failed") }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw RoamError.invalid("数据库操作失败 / Database operation failed") }
        return result
    }
    private func bind(_ text: String, _ s: OpaquePointer, _ index: Int32) { sqlite3_bind_text(s, index, text, -1, transient) }
    private func bind(_ data: Data, _ s: OpaquePointer, _ index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(data.count), transient) }
    }
    private func data(_ s: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(s, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, column)))
    }
    private func finish(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw RoamError.invalid("无法保存数据 / Cannot save data") }
    }
    public func hosts() throws -> [Host] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT json FROM hosts ORDER BY rowid"); defer { sqlite3_finalize(s) }
        var values: [Host] = []
        while sqlite3_step(s) == SQLITE_ROW { values.append(try decoder.decode(Host.self, from: data(s, 0))) }
        // Keep saved order for tied timestamps and hosts that have never been opened.
        return values.enumerated().sorted {
            let left = $0.element.lastUsedAt ?? .distantPast
            let right = $1.element.lastUsedAt ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }
    /// The saved hosts' ids, without decoding their profiles.
    private func hostIDs() throws -> Set<String> {
        let s = try statement("SELECT id FROM hosts"); defer { sqlite3_finalize(s) }
        var ids = Set<String>()
        while sqlite3_step(s) == SQLITE_ROW { if let id = sqlite3_column_text(s, 0) { ids.insert(String(cString: id)) } }
        return ids
    }
    public func saveHost(_ host: Host) throws {
        lock.lock(); defer { lock.unlock() }
        let validated = try host.validated()
        let s = try statement("INSERT INTO hosts(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json"); defer { sqlite3_finalize(s) }
        bind(validated.id, s, 1); bind(try encoder.encode(validated), s, 2); try finish(s)
    }
    public func deleteHost(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("DELETE FROM hosts WHERE id=?"); defer { sqlite3_finalize(s) }
        bind(id, s, 1); try finish(s)
    }
    public func loadJournal() throws -> SessionJournal {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT json FROM journal ORDER BY rowid"); defer { sqlite3_finalize(s) }
        var records: [SessionRecord] = []
        while sqlite3_step(s) == SQLITE_ROW { records.append(try decoder.decode(SessionRecord.self, from: data(s, 0))) }
        return SessionJournal(records: records)
    }
    public func saveJournal(_ journal: SessionJournal) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM journal")
            let valid = try hostIDs()
            // One prepared insert, reset per record.
            let s = try statement("INSERT INTO journal(id,host_id,json) VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
            for record in journal.records where valid.contains(record.hostID) {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                bind(record.id, s, 1); bind(record.hostID, s, 2); bind(try encoder.encode(record), s, 3); try finish(s)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT json FROM settings WHERE id=1"); defer { sqlite3_finalize(s) }
        if sqlite3_step(s) == SQLITE_ROW { return try decoder.decode(AppSettings.self, from: data(s, 0)) }
        return AppSettings()
    }
    public func saveSettings(_ settings: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("INSERT INTO settings(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json"); defer { sqlite3_finalize(s) }
        bind(try encoder.encode(settings), s, 1); try finish(s)
    }
    public func pin(endpoint: String) throws -> HostPin? {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT algorithm,key FROM pins WHERE endpoint=?"); defer { sqlite3_finalize(s) }
        bind(endpoint, s, 1)
        guard sqlite3_step(s) == SQLITE_ROW, let algorithm = sqlite3_column_text(s, 0) else { return nil }
        return HostPin(endpoint: endpoint, algorithm: String(cString: algorithm), key: data(s, 1))
    }
    public func putIfAbsent(_ pin: HostPin) throws -> HostPin {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("INSERT OR IGNORE INTO pins(endpoint,algorithm,key) VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
        bind(pin.endpoint, s, 1); bind(pin.algorithm, s, 2); bind(pin.key, s, 3); try finish(s)
        guard let winner = try self.pin(endpoint: pin.endpoint) else { throw RoamError.invalid("无法保存服务器指纹") }
        return winner
    }
    public func forgetPin(endpoint: String) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("DELETE FROM pins WHERE endpoint=?"); defer { sqlite3_finalize(s) }
        bind(endpoint, s, 1); try finish(s)
    }
}
