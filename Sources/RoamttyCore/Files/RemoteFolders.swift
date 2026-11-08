import Foundation

/// The launch picker uses SSH exec, so hosts without an SFTP subsystem still work.
public struct RemoteFolders: Equatable, Sendable {
    public let home: String
    public let path: String
    public let folders: [String]
    public var display: String { Self.displayPath(path, home: home) }
    public var directory: RemoteDirectory {
        RemoteDirectory(path: path, entries: folders.map {
            RemoteEntry(name: $0, path: joinRemotePath(directory: path, name: $0), isDirectory: true)
        })
    }

    // [[:cntrl:]] rather than a byte range: in UTF-8 locales bash (macOS /bin/sh) matches
    // [\001-\037] by collation order, which skips newline and tab.
    public static func script(_ directory: String) throws -> String {
        guard StartDirectory.isSupported(directory) else { throw RoamError.invalid("Unsupported folder path") }
        let normalized = StartDirectory.normalize(directory)
        let target: String
        if normalized == "~" {
            target = "\"$HOME\""
        } else if normalized.hasPrefix("~/") {
            target = "\"$HOME\"/" + RemoteCommands.shellQuote(String(normalized.dropFirst(2)))
        } else {
            target = RemoteCommands.shellQuote(normalized)
        }
        return #"""
        cd -- \#(target) 2>/dev/null || exit 3
        safe_path() {
          case "$1" in *[[:cntrl:]]*) return 1 ;; esac
        }
        safe_path "$HOME" || exit 3
        path=$(pwd -P && printf '.') || exit 3
        path=${path%.}
        path=${path%?}
        safe_path "$path" || exit 3
        printf '%s\n' "$HOME" "$path"
        n=0
        for f in *; do
          [ -d "$f" ] || continue
          safe_path "$f" || continue
          printf '%s\n' "$f"
          n=$((n + 1)); [ "$n" -ge 500 ] && break
        done
        exit 0
        """#
    }

    public static func parse(_ output: String) -> RemoteFolders? {
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2, lines.prefix(2).allSatisfy({ $0.hasPrefix("/") && StartDirectory.isSupported($0) }) else { return nil }
        var seen = Set<String>()
        let folders = lines.dropFirst(2).filter {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "*" && !$0.contains("/") && StartDirectory.isSupported($0) && seen.insert($0).inserted
        }.sorted { $0.lowercased() < $1.lowercased() }
        var home = lines[0]
        while home.hasSuffix("/") { home.removeLast() }
        return RemoteFolders(home: home.isEmpty ? "/" : home, path: lines[1], folders: folders)
    }

    public static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}
