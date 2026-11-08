import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Sendable { case password, key, interactive }
public enum SessionMode: String, Codable, CaseIterable, Sendable { case shell, tmux }
public enum ConnectionPhase: String, Codable, Sendable {
    case connecting, verifying, authenticating, connected, disconnected, authFailed, hostKeyChanged, failed, tmuxMissing
    public var active: Bool { [.connecting, .verifying, .authenticating, .connected].contains(self) }

    /// What a connection that failed with `error` shows: why the login stopped, or plainly that it failed.
    public init(failure error: Error) {
        switch error as? RoamError {
        case .authentication: self = .authFailed
        case .hostKeyChanged: self = .hostKeyChanged
        case .tmuxMissing: self = .tmuxMissing
        case .cancelled, .rejected: self = .disconnected
        default: self = .failed
        }
    }
}
public enum RoamError: Error, LocalizedError, Equatable {
    case invalid(String), transport(String), authentication, cancelled, timeout, hostKeyChanged(String, String), rejected, sessionLimit, tmuxMissing
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .transport(let s): return s
        case .authentication: return "认证失败 / Authentication failed"
        case .cancelled: return "已取消 / Cancelled"
        case .timeout: return "连接超时 / Connection timed out"
        case .hostKeyChanged: return "服务器指纹已变化 / Host key changed"
        case .rejected: return "未信任服务器 / Host not trusted"
        case .sessionLimit: return "每台主机最多 8 个会话 / Maximum 8 sessions per host"
        case .tmuxMissing: return "主机尚未安装 tmux / tmux is not installed"
        }
    }
}

public struct Host: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    public var mode: SessionMode
    public var system: String
    public var plugins: [String]?
    public var keyLabel: String?
    public var savePassword: Bool
    /// Last explicit visit to this host's details, terminal, files or desktop; absent on older installs.
    public var lastUsedAt: Date?
    /// Read-only desktop probe: `yes` / `no` / `nologin` (Android `Host.desktop`).
    public var desktop: String?
    /// When the probe was stored, milliseconds since epoch; older than `DesktopProbe.cacheMs` is stale.
    public var desktopProbedAt: Int64?
    public init(id: String = UUID().uuidString, name: String = "", address: String = "", port: Int = 22,
                username: String = "", auth: AuthMethod = .password, mode: SessionMode = .tmux,
                system: String = "UNKNOWN", plugins: [String]? = nil, keyLabel: String? = nil, savePassword: Bool = false,
                desktop: String? = nil, desktopProbedAt: Int64? = nil, lastUsedAt: Date? = nil) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.auth = auth; self.mode = mode; self.system = system; self.plugins = plugins
        self.keyLabel = keyLabel; self.savePassword = savePassword
        self.lastUsedAt = lastUsedAt
        self.desktop = desktop; self.desktopProbedAt = desktopProbedAt
    }
    public var hostname: String {
        address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
    }
    public var endpoint: String {
        var name = hostname.lowercased(); if name.hasSuffix(".") { name.removeLast() }
        return "[\(name)]:\(port)"
    }
    public func validated() throws -> Host {
        var h = self
        h.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        h.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        h.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.name.isEmpty, h.name.utf16.count <= 80 else { throw RoamError.invalid("名称需为 1–80 个字符") }
        guard !h.address.isEmpty, h.address.utf16.count <= 253,
              !h.address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) || "/\\@".unicodeScalars.contains($0) }) else {
                  throw RoamError.invalid("请输入主机地址，不含协议、路径或空格")
              }
        guard (1...65535).contains(port) else { throw RoamError.invalid("端口必须为 1–65535") }
        guard !h.username.isEmpty, h.username.utf16.count <= 128,
              !h.username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw RoamError.invalid("请输入有效用户名") }
        return h
    }
}

/// Android's `requireValidHostAddress` (roamtty #277): an address typed into the host editor is a hostname, an IPv4
/// address or an IPv6 literal (bracketed or not, with an optional zone), by its syntax alone: saving a host never needs
/// DNS, a network or a server. Hosts saved before this check still load, so they can be repaired. Unlike Android it takes
/// underscores inside a name label (`build_box`).
public func isValidHostAddress(_ address: String) -> Bool {
    if address.isEmpty || address.utf16.count > 253 { return false }
    if address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) { return false }
    if address.contains(":") { return isValidIPv6Literal(address) }
    if address.contains("."), address.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { return isValidIPv4(address) }
    let name = address.hasSuffix(".") ? String(address.dropLast()) : address
    guard !name.isEmpty else { return false }
    return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        guard (1...63).contains(label.count), let first = label.first, let last = label.last, first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
        // Underscores are not in RFC 1123 hostnames, yet internal DNS, container and VM names use them.
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

private func isValidIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { part in
        !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part).map { (0...255).contains($0) } ?? false)
    }
}

private func isValidIPv6Literal(_ address: String) -> Bool {
    let literal = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
    let scoped = literal.split(separator: "%", omittingEmptySubsequences: false)
    if scoped.count > 2 { return false }
    if scoped.count == 2 && (scoped[1].isEmpty || !scoped[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })) { return false }
    let ip = String(scoped[0])
    let doubles = ip.components(separatedBy: "::").count - 1
    if ip.filter({ $0 == ":" }).count < 2 || ip.contains(":::") || doubles > 1 { return false }
    if (ip.hasPrefix(":") && !ip.hasPrefix("::")) || (ip.hasSuffix(":") && !ip.hasSuffix("::")) { return false }
    let groups = ip.split(separator: ":")
    var units = 0
    for (index, group) in groups.enumerated() {
        if group.contains(".") {
            guard index == groups.count - 1, ip.hasSuffix(group), isValidIPv4(String(group)) else { return false }
            units += 2
        } else {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit) else { return false }
            units += 1
        }
    }
    return doubles == 1 ? units < 8 : units == 8
}

public struct Credentials: Sendable {
    public var password: Data?
    public var privateKey: Data?
    public var passphrase: String?
    public init(password: Data? = nil, privateKey: Data? = nil, passphrase: String? = nil) {
        self.password = password; self.privateKey = privateKey; self.passphrase = passphrase
    }
    public mutating func clear() {
        if let count = password?.count { password?.resetBytes(in: 0..<count) }
        if let count = privateKey?.count { privateKey?.resetBytes(in: 0..<count) }
        password = nil; privateKey = nil; passphrase = nil
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var hostID: String
    public var mode: SessionMode
    public var title: String
    public var remoteName: String
    public var number: Int
    /// A tmux session that was already on the server: the app attaches to it beside its other clients and never ends it.
    public var external: Bool
    public init(id: String = UUID().uuidString, hostID: String, mode: SessionMode, title: String = "", remoteName: String? = nil, number: Int = 1, external: Bool = false) {
        self.id = id; self.hostID = hostID; self.mode = mode; self.title = String(title.prefix(80)); self.number = number
        self.remoteName = remoteName ?? "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        self.external = external
    }
    private enum CodingKeys: String, CodingKey { case id, hostID, mode, title, remoteName, number, external }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); hostID = try container.decode(String.self, forKey: .hostID)
        mode = try container.decode(SessionMode.self, forKey: .mode); title = try container.decode(String.self, forKey: .title)
        remoteName = try container.decode(String.self, forKey: .remoteName); number = try container.decode(Int.self, forKey: .number)
        external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }
}

public struct SessionJournal: Sendable {
    public private(set) var records: [SessionRecord]
    public init(records: [SessionRecord] = []) {
        var counts: [String: Int] = [:]; var ids = Set<String>()
        self.records = records.filter {
            guard ids.insert($0.id).inserted, counts[$0.hostID, default: 0] < 8 else { return false }
            counts[$0.hostID, default: 0] += 1; return true
        }
    }
    /// `external` names a tmux session already on the server to attach instead of a new one.
    public mutating func create(hostID: String, mode: SessionMode, title: String = "", external: String? = nil) throws -> SessionRecord {
        let same = records.filter { $0.hostID == hostID }
        guard same.count < 8 else { throw RoamError.sessionLimit }
        let record = SessionRecord(hostID: hostID, mode: external == nil ? mode : .tmux, title: title, remoteName: external,
                                   number: (same.map(\.number).max() ?? 0) + 1, external: external != nil)
        records.append(record); return record
    }
    public mutating func forget(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func removeHost(_ id: String) { records.removeAll { $0.hostID == id } }
}

public struct InputQueue {
    private var items: [Data] = []
    public private(set) var generation = 0
    public init() {}
    public mutating func enqueue(_ data: Data) -> Bool {
        guard data.count <= 256 * 1024, items.count < 64 else { return false }
        items.append(data); return true
    }
    public mutating func pop() -> Data? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func reset() { items.removeAll(keepingCapacity: true); generation += 1 }
}

public enum AppTheme: String, Codable, CaseIterable { case system, dark, light }
public struct AppSettings: Codable, Equatable {
    public var theme: AppTheme = .dark
    public var language = AppSettings.defaultLanguage()
    public var font = "JetBrainsMono-Regular"
    public var fontSize = 13.0
    public var showHiddenFiles = false
    public var toolboxPinned = false
    public var downloadBookmark: Data?
    public var fileSort: RemoteFileSort = .name
    public var fileSortDescending = false
    public var codeWrap = false
    public var codeFontSize = 13.0
    /// How long a left desktop stays connected: 5, 10 or 30 minutes.
    public var desktopKeepAliveMinutes = 10
    /// Show the network stats overlay (also toggled in 操作).
    public var desktopShowStats = false
    /// Where the network figures sit, as fractions of the room the picture leaves them: 0, 0 is the top left.
    public var desktopStatsX = 0.0
    public var desktopStatsY = 0.0
    /// Per-host desktop prefs, keyed by host id (mode/quality/fps/lock).
    public var desktopHosts: [String: DesktopHostSettings] = [:]
    /// Debug: replace the pinned plugin base URL.
    public var desktopPluginBaseUrl = ""
    /// Which agent notifications come (设置 → 通知).
    public var agentNotifications = AgentNotifications.all
    public init() {}

    /// A first launch follows the phone's language: Chinese for Chinese, English otherwise. A saved choice wins.
    public static func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    private enum CodingKeys: String, CodingKey {
        case theme, language, font, fontSize, showHiddenFiles, toolboxPinned, downloadBookmark
        case fileSort, fileSortDescending, codeWrap, codeFontSize
        case desktopKeepAliveMinutes, desktopShowStats, desktopStatsX, desktopStatsY, desktopHosts, desktopPluginBaseUrl, agentNotifications
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = AppTheme(rawValue: try values.decodeIfPresent(String.self, forKey: .theme) ?? "") ?? .dark
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? AppSettings.defaultLanguage()
        font = try values.decodeIfPresent(String.self, forKey: .font) ?? "JetBrainsMono-Regular"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        toolboxPinned = try values.decodeIfPresent(Bool.self, forKey: .toolboxPinned) ?? false
        downloadBookmark = try values.decodeIfPresent(Data.self, forKey: .downloadBookmark)
        fileSort = RemoteFileSort(rawValue: try values.decodeIfPresent(String.self, forKey: .fileSort) ?? "") ?? .name
        fileSortDescending = try values.decodeIfPresent(Bool.self, forKey: .fileSortDescending) ?? false
        codeWrap = try values.decodeIfPresent(Bool.self, forKey: .codeWrap) ?? false
        codeFontSize = min(22, max(9, try values.decodeIfPresent(Double.self, forKey: .codeFontSize) ?? 13))
        // Desktop keys are best-effort: a bad value must not fail the whole settings blob (launch path).
        let keep = (try? values.decodeIfPresent(Int.self, forKey: .desktopKeepAliveMinutes)) ?? 10
        desktopKeepAliveMinutes = [5, 10, 30].contains(keep) ? keep : 10
        desktopShowStats = (try? values.decodeIfPresent(Bool.self, forKey: .desktopShowStats)) ?? false
        desktopStatsX = min(1, max(0, (try? values.decodeIfPresent(Double.self, forKey: .desktopStatsX)) ?? 0))
        desktopStatsY = min(1, max(0, (try? values.decodeIfPresent(Double.self, forKey: .desktopStatsY)) ?? 0))
        desktopHosts = (try? values.decodeIfPresent([String: DesktopHostSettings].self, forKey: .desktopHosts)) ?? [:]
        desktopPluginBaseUrl = (try? values.decodeIfPresent(String.self, forKey: .desktopPluginBaseUrl)) ?? ""
        agentNotifications = AgentNotifications(rawValue: (try? values.decodeIfPresent(String.self, forKey: .agentNotifications)) ?? "") ?? .all
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(theme, forKey: .theme)
        try values.encode(language, forKey: .language)
        try values.encode(font, forKey: .font)
        try values.encode(fontSize, forKey: .fontSize)
        try values.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try values.encode(toolboxPinned, forKey: .toolboxPinned)
        try values.encodeIfPresent(downloadBookmark, forKey: .downloadBookmark)
        try values.encode(fileSort, forKey: .fileSort)
        try values.encode(fileSortDescending, forKey: .fileSortDescending)
        try values.encode(codeWrap, forKey: .codeWrap)
        try values.encode(codeFontSize, forKey: .codeFontSize)
        try values.encode(desktopKeepAliveMinutes, forKey: .desktopKeepAliveMinutes)
        try values.encode(desktopShowStats, forKey: .desktopShowStats)
        try values.encode(desktopStatsX, forKey: .desktopStatsX)
        try values.encode(desktopStatsY, forKey: .desktopStatsY)
        try values.encode(desktopHosts, forKey: .desktopHosts)
        try values.encode(desktopPluginBaseUrl, forKey: .desktopPluginBaseUrl)
        try values.encode(agentNotifications, forKey: .agentNotifications)
    }
}

/// Per-host desktop preferences stored in `AppSettings.desktopHosts`.
public struct DesktopHostSettings: Codable, Equatable, Sendable {
    public var pointerMode = "touch" // touch | mouse
    public var quality = "auto"
    public var fps = 60
    public var lockOnClose = false
    /// 声音: the host's sound on the phone, on unless switched off for this host.
    public var audio = true
    public init() {}

    private enum CodingKeys: String, CodingKey { case pointerMode, quality, fps, lockOnClose, audio }

    /// Fields added later are missing from settings saved before them: they keep their defaults, or the
    /// whole map (every host's preferences) would fail to decode.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pointerMode = try values.decodeIfPresent(String.self, forKey: .pointerMode) ?? "touch"
        quality = try values.decodeIfPresent(String.self, forKey: .quality) ?? "auto"
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        lockOnClose = try values.decodeIfPresent(Bool.self, forKey: .lockOnClose) ?? false
        audio = try values.decodeIfPresent(Bool.self, forKey: .audio) ?? true
    }
}
