// Port of Roamtty Android's LoopbackUrl and ListeningPort (roamtty #275): pages a server serves on its own loopback,
// and the ports it listens on.
import Foundation

/// A web page on the server, by the address the server reaches it at: usually its own loopback, as a dev server prints
/// it (`http://localhost:5173/`, `127.0.0.1`, `0.0.0.0` or `[::1]`). Only plain http: a dev server's TLS certificate
/// would not be trusted on the phone anyway.
public struct LoopbackUrl: Equatable, Hashable, Sendable, Identifiable {
    public let host: String
    public let port: Int
    public let rest: String
    public init(host: String, port: Int, rest: String) { self.host = host; self.port = port; self.rest = rest }
    public var id: String { "\(host):\(port)\(rest)" }

    /// Where the server connects: a name it resolves itself, as dev servers on `localhost` may listen on IPv6 only.
    public var target: String {
        if host == "localhost" || host == "0.0.0.0" { return "localhost" }
        if host.hasPrefix("[") && host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }

    /// Where the phone's tunnel answers: it listens on 127.0.0.1 alone, so another loopback address the server
    /// uses (`127.0.0.2`, `127.0.0.53`) is asked for there; names and IPv6 go by `localhost`.
    public var tunnelHost: String { host.hasPrefix("127.") ? "127.0.0.1" : "localhost" }

    /// The same page through a tunnel on the phone's `localPort`.
    public func through(_ localPort: Int) -> String { "http://\(tunnelHost):\(localPort)\(rest)" }

    /// What the address bar shows: the server's address, as the terminal printed it, without the scheme.
    public var display: String { "\(host):\(port)\(rest == "/" ? "" : rest)" }

    public static func parse(_ url: String) -> LoopbackUrl? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("http://") else { return nil }
        let afterScheme = text.dropFirst(7)
        let lower = afterScheme.lowercased()
        var host: String?
        if let named = ["localhost", "0.0.0.0", "[::1]"].first(where: { lower.hasPrefix($0) }) {
            host = named
        } else if lower.hasPrefix("127.") {
            let candidate = lower.prefix { $0.isNumber || $0 == "." }
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 4, parts.allSatisfy({ (1...3).contains($0.count) }) { host = String(candidate) }
        }
        guard let host else { return nil }
        var tail = afterScheme.dropFirst(host.count)
        var port = 80
        if tail.first == ":" {
            let digits = tail.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard (1...5).contains(digits.count), let value = Int(digits), (1...65535).contains(value) else { return nil }
            port = value
            tail = tail.dropFirst(1 + digits.count)
        }
        if let first = tail.first, !"/?#".contains(first) { return nil }
        let rest = tail.isEmpty ? "/" : tail.hasPrefix("/") ? String(tail) : "/" + tail
        return LoopbackUrl(host: host, port: port, rest: rest)
    }

    /// `url` as loaded through a tunnel on `localPort`, back in terms of the server's address: its `host` (as
    /// `through` named it on the phone) and `port`; nil for other pages.
    public static func fromTunnel(_ url: String, localPort: Int, port: Int, host: String? = nil) -> LoopbackUrl? {
        guard let page = parse(url), page.port == localPort else { return nil }
        let server = host.flatMap { LoopbackUrl(host: $0, port: port, rest: "/").tunnelHost == page.host ? $0 : nil }
        return LoopbackUrl(host: server ?? page.host, port: port, rest: page.rest)
    }
}

/// A TCP port something on the server listens on: the listening process's command line and folder when the login may
/// see them (`pid` nil otherwise: another user's process, root's or a container's).
public struct ListeningPort: Equatable, Hashable, Sendable, Identifiable {
    public let port: Int
    public let address: String
    public let pid: Int?
    public let command: String
    public let directory: String
    public init(port: Int, address: String, pid: Int?, command: String, directory: String) {
        self.port = port; self.address = address; self.pid = pid; self.command = command; self.directory = directory
    }
    public var id: Int { port }

    /// The page a tap opens: the port as the server reaches it.
    public var url: LoopbackUrl {
        let host = Self.isWildcard(address) ? "localhost" : address.contains(":") ? "[\(address)]" : address
        return LoopbackUrl(host: host, port: port, rest: "/")
    }

    /// `command` as a person reads it: programs and scripts by their file name, without their folders. A path may
    /// hold spaces (`/Applications/Visual Studio Code.app/…`): it runs on to the last word with a slash before an option.
    public var shortCommand: String {
        let words = command.split(separator: " ").map(String.init)
        var shown: [String] = []
        var index = 0
        while index < words.count {
            guard words[index].hasPrefix("/") else { shown.append(words[index]); index += 1; continue }
            var end = index
            for later in (index + 1)..<max(index + 1, words.count) {
                if words[later].hasPrefix("-") || words[later].hasPrefix("/") { break }
                if words[later].contains("/") { end = later }
            }
            let path = words[index...end].joined(separator: " ")
            shown.append(path.hasSuffix("/") ? path : String(path[path.index(after: path.lastIndex(of: "/")!)...]))
            index = end + 1
        }
        return shown.joined(separator: " ")
    }

    /// POSIX sh: `HOME\t<home>` then one `PORT\t<address:port>\t<pid>\t<cwd>\t<command line>` line per listening
    /// socket. Linux reads `ss` and /proc; macOS reads `lsof` and `ps`, which list only the login's own processes.
    public static let script = #"""
        set -f
        printf 'HOME\t%s\n' "$HOME"
        emit() {
          cmd=; cwd=
          if [ -n "$2" ]; then
            if [ -r "/proc/$2/cmdline" ]; then
              cmd=$(tr '\000\t\n' '   ' < "/proc/$2/cmdline" 2>/dev/null)
              cwd=$(readlink "/proc/$2/cwd" 2>/dev/null)
            else
              cmd=$(ps -o command= -p "$2" 2>/dev/null | tr '\t\n' '  ')
              cwd=$(lsof -a -p "$2" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
            fi
          fi
          printf 'PORT\t%s\t%s\t%s\t%s\n' "$1" "$2" "$cwd" "$cmd"
        }
        if command -v ss >/dev/null 2>&1; then
          ss -ltnp 2>/dev/null | while IFS= read -r line; do
            case $line in State*|'') continue ;; esac
            set -- $line
            emit "$4" "$(printf '%s\n' "$line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
          done
        elif command -v lsof >/dev/null 2>&1; then
          lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | while IFS= read -r line; do
            case $line in p*) pid=${line#p} ;; n*) emit "${line#n}" "$pid" ;; esac
          done
        else
          exit 3
        fi
        """#

    /// Where Linux starts handing out ports for outgoing and unnamed sockets (macOS: 49152).
    public static let ephemeralPorts = 32768

    /// `script`'s output, one entry per port: the login's own processes first, then the rest, each by port. Folders
    /// under the home show as `~/…`. Ports from `ephemeralPorts` up are left out: editors and agents hold dozens there
    /// for their own use, and dev servers pick fixed, lower ones.
    public static func parse(_ lines: [String]) -> [ListeningPort] {
        let homeLine = lines.first { $0.hasPrefix("HOME\t") }
        var home = homeLine.map { String($0.dropFirst(5)) } ?? ""
        while home.hasSuffix("/") { home.removeLast() }
        var sockets: [ListeningPort] = []
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, fields[0] == "PORT" else { continue }
            let local = fields[1]
            guard let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]), (1..<ephemeralPorts).contains(port) else { continue }
            var address = String(local[..<colon])
            if address.hasPrefix("[") { address.removeFirst() }
            if address.hasSuffix("]") { address.removeLast() }
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            var directory = fields[3]
            if !home.isEmpty && (directory == home || directory.hasPrefix(home + "/")) { directory = "~" + directory.dropFirst(home.count) }
            sockets.append(ListeningPort(port: port, address: address, pid: Int(fields[2]), command: fields[4].trimmingCharacters(in: .whitespaces), directory: directory))
        }
        var order: [Int] = [], byPort: [Int: [ListeningPort]] = [:]
        for socket in sockets {
            if byPort[socket.port] == nil { order.append(socket.port) }
            byPort[socket.port, default: []].append(socket)
        }
        let merged = order.map { port -> ListeningPort in
            let same = byPort[port]!
            let known = same.first { $0.pid != nil } ?? same[0]
            // One reachable from the server's loopback, the way the page will be asked for.
            let address = same.first { isWildcard($0.address) }?.address
                ?? same.first { $0.address.hasPrefix("127.") }?.address
                ?? same.first { $0.address == "::1" }?.address
                ?? known.address
            return ListeningPort(port: known.port, address: address, pid: known.pid, command: known.command, directory: known.directory)
        }
        return merged.sorted { ($0.pid == nil ? 1 : 0, $0.port) < ($1.pid == nil ? 1 : 0, $1.port) }
    }

    static func isWildcard(_ address: String) -> Bool { address == "*" || address == "0.0.0.0" || address == "::" || address.isEmpty }
}
