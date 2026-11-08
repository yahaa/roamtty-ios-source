// Behavioral port of Roamtty Android's RemoteFiles, RemotePaths and RemoteFileContent helpers.
import Foundation

public struct RemoteEntry: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64?
    public var mtime: Int64
    public var permissions: UInt32
    public var id: String { path }
    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64? = nil, mtime: Int64 = 0, permissions: UInt32 = 0) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.size = size; self.mtime = mtime; self.permissions = permissions
    }
    public var kind: RemoteFileKind { remoteFileKind(name: name, isDirectory: isDirectory, permissions: permissions) }
}

public struct RemoteDirectory: Codable, Equatable, Sendable {
    public var path: String
    public var entries: [RemoteEntry]
    /// Entries left out because their names are not UTF-8: a lossy name would point at another file.
    public var unreadableNames: Int
    public init(path: String, entries: [RemoteEntry], unreadableNames: Int = 0) { self.path = path; self.entries = entries; self.unreadableNames = unreadableNames }
}

public func joinRemotePath(directory: String, name: String) -> String {
    let base = directory.removingTrailingSlashes
    return base + "/" + name
}

public func parentRemotePath(_ path: String) -> String {
    let trimmed = path.removingTrailingSlashes
    guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
    return String(trimmed[..<slash])
}

public func isValidRemoteDirectory(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf16.count <= 4096 && !path.containsPathControl
}

public func validWorkingDirectory(_ output: String?) -> String? {
    guard let output else { return nil }
    var scalars = output.unicodeScalars
    if scalars.last == "\n" { scalars.removeLast() }
    if scalars.last == "\r" { scalars.removeLast() }
    let path = String(scalars)
    return isValidRemoteDirectory(path) ? path : nil
}

/// Where a path printed in the terminal points: absolute as it is, "~/" from the SFTP home (a relative SFTP path), and
/// anything else from the shell's `directory`. Nil when a relative path has no directory to start from.
public func resolveTerminalPath(directory: String?, path: String) -> String? {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~/") {
        let rest = String(path.dropFirst(2).drop { $0 == "/" })
        return rest.isEmpty ? nil : rest
    }
    if path.hasPrefix("~") { return nil } // Another user's home: "~bob/x" needs a lookup SFTP cannot do.
    guard let directory, isValidRemoteDirectory(directory) else { return nil }
    return joinRemotePath(directory: directory, name: path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
}

public func isSafeRemoteEntryName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.containsPathControl
}

/// The path as typed into a terminal, quoted for the shell; nil when it holds a control character, which a terminal
/// would act on (Ctrl-U clears the line, CR submits it) however the shell quotes it.
public func terminalPathText(_ path: String) -> String? {
    guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
    return RemoteCommands.shellQuote(path)
}

public func isSafeRemoteDeletePath(_ path: String) -> Bool {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, path.utf16.count <= 4096,
          !path.containsPathControl, !path.removingTrailingSlashes.isEmpty else { return false }
    return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
}

public func remoteEntryPrecedes(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
    return lhs.name.lowercased() < rhs.name.lowercased()
}

/// Exact, prefix, substring and ordered abbreviation ranks, in that order.
public func remoteNameMatchRank(name: String, query: String) -> Int? {
    func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[\\p{Cc}\\p{Zs}]+", with: " ", options: .regularExpression)
    }
    func rank(_ value: String, _ needle: String) -> Int? {
        if value == needle { return 0 }
        if value.hasPrefix(needle) { return 1 }
        if value.contains(needle) { return 2 }
        var remaining = value.unicodeScalars[...]
        for scalar in needle.unicodeScalars {
            guard let found = remaining.firstIndex(of: scalar) else { return nil }
            remaining = remaining[remaining.index(after: found)...]
        }
        return 3
    }
    // An empty query matches every name. The file list asks about each of its entries, so a name is normalized only
    // once there is a query to compare it with.
    let needle = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
    if needle.isEmpty { return 0 }
    let value = normalize(name)
    if value == needle { return 0 }
    if let result = rank(value, needle) { return result }
    let terms = needle.split(whereSeparator: \.isWhitespace)
    guard terms.count > 1 else { return nil }
    var result = 2
    for term in terms {
        guard let part = rank(value, String(term)) else { return nil }
        result = max(result, part)
    }
    return result
}

public struct RemotePathSearch: Equatable, Sendable {
    public var directory: String
    public var name: String
    public init(directory: String, name: String) { self.directory = directory; self.name = name }
}

public func remotePathSearch(directory: String, query: String) -> RemotePathSearch {
    guard let slash = query.lastIndex(of: "/") else { return RemotePathSearch(directory: directory, name: query) }
    let prefix = String(query[...slash])
    let path = prefix.hasPrefix("/") ? prefix : prefix.hasPrefix("~/") ? String(prefix.dropFirst(2)) : directory.isEmpty ? prefix : directory + "/" + prefix
    var parts: [String] = []
    for part in path.split(separator: "/") {
        if part == "." { continue }
        if part == ".." {
            if let last = parts.last, last != ".." { parts.removeLast() } else if !path.hasPrefix("/") { parts.append("..") }
        } else { parts.append(String(part)) }
    }
    return RemotePathSearch(directory: (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/"), name: String(query[query.index(after: slash)...]))
}

public struct RemoteSearchDirectories: Equatable, Sendable {
    public var directories: [RemoteDirectory]
    public var limited: Bool
    public var unreadable: Bool
}

public func resolveRemoteSearchDirectories(directory: String, prefix: String, showHidden: Bool, maxDirectories: Int = 32,
                                           listDirectory: (String) async throws -> RemoteDirectory) async throws -> RemoteSearchDirectories {
    guard maxDirectories > 0 else { throw RoamError.invalid("Directory read limit must be positive") }
    try Task.checkCancellation()
    let base = try await listDirectory(prefix.hasPrefix("/") ? "/" : prefix.hasPrefix("~/") ? "" : directory)
    let parts = (prefix.hasPrefix("~/") ? String(prefix.dropFirst(2)) : prefix).split(separator: "/").filter { $0 != "." }
    var directories = [base], reads = 1, limited = false, unreadable = false
    for part in parts {
        try Task.checkCancellation()
        let paths: [String]
        if part == ".." { paths = directories.map { parentRemotePath($0.path) }.unique } else {
            let matches = directories.flatMap { parent in
                parent.entries.compactMap { entry -> (path: String, name: String, rank: Int)? in
                    guard entry.isDirectory, showHidden || !entry.name.hasPrefix("."),
                          let rank = remoteNameMatchRank(name: entry.name, query: String(part)) else { return nil }
                    return (joinRemotePath(directory: parent.path, name: entry.name), entry.name, rank)
                }
            }
            paths = matches.sorted { $0.rank == $1.rank ? $0.name.lowercased() < $1.name.lowercased() : $0.rank < $1.rank }.map(\.path).unique
        }
        var next: [RemoteDirectory] = []
        for path in paths {
            try Task.checkCancellation()
            if reads >= maxDirectories { limited = true; break }
            reads += 1
            do {
                next.append(try await listDirectory(path))
            } catch is CancellationError {
                throw CancellationError()
            } catch RoamError.cancelled {
                throw RoamError.cancelled
            } catch {
                try Task.checkCancellation()
                unreadable = true
            }
        }
        var seen = Set<String>()
        directories = next.filter { seen.insert($0.path).inserted }
        if directories.isEmpty { break }
    }
    return RemoteSearchDirectories(directories: directories, limited: limited, unreadable: unreadable)
}

/// Reserve originals first, so a generated suffix never takes a later file's basename.
public func downloadNames(paths: [String]) -> [String: String] {
    func basename(_ path: String) -> String { String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "") }
    var reserved = Set(paths.map { basename($0).lowercased() }), used = Set<String>(), suffix: [String: Int] = [:], result: [String: String] = [:]
    for path in paths {
        var name = basename(path)
        if !used.insert(name.lowercased()).inserted {
            let key = name.lowercased()
            let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 } ?? name.endIndex
            let stem = String(name[..<dot]), ext = String(name[dot...])
            var number = suffix[key] ?? 2
            repeat { name = "\(stem) (\(number))\(ext)"; number += 1 } while !reserved.insert(name.lowercased()).inserted
            suffix[key] = number; used.insert(name.lowercased())
        }
        result[path] = name
    }
    return result
}

public enum RemoteFileKind: String, Codable, CaseIterable, Sendable {
    case directory, text, code, config, image, audio, video, archive, pdf, document, spreadsheet, presentation, executable, file
}

public func remoteFileKind(name: String, isDirectory: Bool = false, permissions: UInt32 = 0) -> RemoteFileKind {
    if isDirectory { return .directory }
    let name = name.lowercased(), ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? ""
    if ["dockerfile", "makefile", "gemfile", "rakefile", "justfile"].contains(name) { return .code }
    if name.hasPrefix(".env") || [".gitignore", ".gitattributes", ".editorconfig", ".bashrc", ".zshrc"].contains(name) { return .config }
    if ["readme", "license", "licence", "notice", "changelog", "authors"].contains(name) { return .text }
    let groups: [(RemoteFileKind, String)] = [
        (.text, "txt md markdown rst log csv tsv"), (.config, "json yaml yml toml xml ini conf cfg properties env lock"),
        (.code, "sh bash zsh fish py js jsx ts tsx java kt kts c h cpp hpp cs go rs rb php swift dart lua sql html css scss vue svelte gradle ps1 bat"),
        (.image, "png jpg jpeg gif webp bmp heic heif avif svg ico tif tiff"), (.audio, "mp3 wav flac ogg m4a aac opus"),
        (.video, "mp4 mkv mov avi webm m4v"), (.archive, "zip tar gz bz2 xz 7z rar tgz zst jar"), (.pdf, "pdf"),
        (.document, "doc docx odt rtf epub"), (.spreadsheet, "xls xlsx ods"), (.presentation, "ppt pptx odp"), (.executable, "apk exe msi deb rpm appimage")]
    for (kind, extensions) in groups where extensions.split(separator: " ").contains(Substring(ext)) { return kind }
    return permissions & 0o111 != 0 ? .executable : .file
}

public let textPreviewBytes = 256 * 1024
public let imagePreviewBytes = 8 * 1024 * 1024

public struct RemoteFileContent: Equatable, Sendable {
    public var data: Data
    public var size: Int64?
    public var truncated: Bool
    public init(data: Data, size: Int64?, truncated: Bool) { self.data = data; self.size = size; self.truncated = truncated }
    public var text: String? { decodeText() }

    /// Strict Unicode decoding drops only a valid incomplete final character of a bounded prefix.
    public func decodeText() -> String? {
        let bytes = Array(data)
        var scalars = String.UnicodeScalarView()
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            let little = bytes[0] == 0xff
            func unit(_ i: Int) -> UInt32 { little ? UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 : UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) }
            var i = 2
            while i < bytes.count {
                guard i + 1 < bytes.count else { if truncated { break }; return nil }
                let first = unit(i); i += 2
                var value = first
                if (0xd800...0xdbff).contains(first) {
                    guard i + 1 < bytes.count else { if truncated { break }; return nil }
                    let second = unit(i)
                    guard (0xdc00...0xdfff).contains(second) else { return nil }
                    value = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00; i += 2
                } else if (0xdc00...0xdfff).contains(first) { return nil }
                guard let scalar = Unicode.Scalar(value) else { return nil }; scalars.append(scalar)
            }
        } else {
            var i = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
            while i < bytes.count {
                let lead = bytes[i], width: Int, mask: UInt8
                switch lead {
                case 0...0x7f: width = 1; mask = 0x7f
                case 0xc2...0xdf: width = 2; mask = 0x1f
                case 0xe0...0xef: width = 3; mask = 0x0f
                case 0xf0...0xf4: width = 4; mask = 0x07
                default: return nil
                }
                var value = UInt32(lead & mask)
                let available = min(width, bytes.count - i)
                for j in 1..<available {
                    let byte = bytes[i + j]
                    guard (0x80...0xbf).contains(byte) else { return nil }
                    if j == 1 && ((lead == 0xe0 && byte < 0xa0) || (lead == 0xed && byte > 0x9f) || (lead == 0xf0 && byte < 0x90) || (lead == 0xf4 && byte > 0x8f)) { return nil }
                    value = value << 6 | UInt32(byte & 0x3f)
                }
                guard available == width else { if truncated { break }; return nil }
                guard let scalar = Unicode.Scalar(value) else { return nil }; scalars.append(scalar); i += width
            }
        }
        guard !scalars.contains(where: { ($0.value < 32 && ![9, 10, 12, 13].contains($0.value)) || $0.value == 127 }) else { return nil }
        return String(scalars)
    }
}

private extension String {
    var removingTrailingSlashes: String { var result = self; while result.hasSuffix("/") { result.removeLast() }; return result }
    var containsPathControl: Bool { unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 } }
}
private extension Array where Element == String {
    var unique: [String] { var seen = Set<String>(); return filter { seen.insert($0).inserted } }
}
