import Foundation

/// What the desktop needs from a logged-in host: the same four operations as Android's `RemoteHost`
/// (ssh-core, roamtty #218), blocking, called from the desktop's own worker thread. The app's
/// implementation sits on `SSHConnection` (RoamttyTransport `SSHDesktopHost`); tests use a local shell.
public protocol DesktopHost: AnyObject {
    /// Sends `script` to `/bin/sh -s` on stdin; output (stdout and stderr) line by line; the exit status, nil on a transport failure.
    func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int?
    /// Runs `command` through the server's configured shell (cmd.exe or PowerShell on native Windows).
    func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int?
    /// SFTP upload; a relative `path` is under the login's home. Fails if the file exists.
    func upload(_ data: Data, to path: String) throws
    /// A long-running command whose stdin/stdout carry the binary protocol; nil when it could not start.
    func openStream(_ command: String) -> DesktopStream?
    /// Ends the login (and with it every channel on it).
    func disconnect()
}

/// One exec channel kept open: `read` takes the command's stdout, `write` feeds its stdin.
public protocol DesktopStream: AnyObject {
    /// Blocks until bytes arrive; empty once the command's output ended or the stream closed.
    func read(maxBytes: Int) -> [UInt8]
    func write(_ bytes: [UInt8]) throws
    /// What the command wrote to stderr so far (bounded).
    var errorOutput: String { get }
    var isClosed: Bool { get }
    /// Set once the command exited.
    var exitStatus: Int? { get }
    func close()
}

/// What the read-only desktop probe saw: `desktop` is yes, no or nologin; `uname` is `uname -sm`;
/// `pluginVersion` the first line of `roamtty-desktop --version`, nil when it is not installed.
public struct HostDesktop: Equatable, Sendable {
    public let desktop: String
    public let uname: String
    public let pluginVersion: String?

    public init(desktop: String, uname: String, pluginVersion: String?) {
        self.desktop = desktop; self.uname = uname; self.pluginVersion = pluginVersion
    }

    /// "roamtty-desktop 0.1.0 proto 1" → 0.1.0
    public var version: String? {
        guard let parts = pluginVersion?.split(separator: " "), parts.count > 1 else { return nil }
        return String(parts[1])
    }

    public var probe: DesktopProbe? { DesktopProbe.decode(desktop) }
}

/// The read-only desktop probe (Android `HostPluginProbe` desktop part + `WindowsDesktop.probeCommand`).
/// Android folds it into the tmux/mosh plugin probe; here it runs on its own so the existing iOS
/// plugin probe stays untouched, with the same markers and the same parse.
public enum DesktopProbeScript {
    public static let DESKTOP = "__ITERMUX_DESKTOP__="
    public static let UNAME = "__ITERMUX_UNAME__="
    public static let DESKTOP_PLUGIN = "__ITERMUX_DESKTOP_PLUGIN__="

    /// Read-only: a graphical session this user owns. Linux: an X or Wayland socket of the user's
    /// (Xorg as the user, Xvfb, a compositor) or a logind x11/wayland session. macOS: someone at the console.
    public static let script = #"""
    d=no
    case "$(uname -s 2>/dev/null)" in
      Darwin) if who 2>/dev/null | grep -q console; then d=yes; else d=nologin; fi ;;
      Linux)
        for s in /tmp/.X11-unix/X* "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-[0-9]*; do [ -S "$s" ] && [ -O "$s" ] && d=yes; done
        if [ $d = no ] && command -v loginctl >/dev/null 2>&1; then
          u=$(id -u)
          for i in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$u" '$2==u{print $1}'); do
            case "$(loginctl show-session "$i" -p Type --value 2>/dev/null)" in x11|wayland) d=yes ;; esac
          done
        fi ;;
    esac
    printf '__ITERMUX_DESKTOP__=%s\n' "$d"
    printf '__ITERMUX_UNAME__=%s\n' "$(uname -sm 2>/dev/null)"
    printf '__ITERMUX_DESKTOP_PLUGIN__=%s\n' "$("$HOME/.roamtty/bin/roamtty-desktop" --version 2>/dev/null | head -n 1)"
    exit 0
    """#

    public static func parse(_ output: String?) -> HostDesktop? {
        guard let output else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ prefix: String) -> String? { lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
        guard let desktop = value(DESKTOP), ["yes", "no", "nologin"].contains(desktop) else { return nil }
        let plugin = value(DESKTOP_PLUGIN).flatMap { $0.hasPrefix("roamtty-desktop ") ? $0 : nil }
        return HostDesktop(desktop: desktop, uname: value(UNAME) ?? "", pluginVersion: plugin)
    }

    /// POSIX shells first; a host without one may still answer through PowerShell.
    public static func probe(_ host: DesktopHost, timeout: TimeInterval = 20) -> HostDesktop? {
        var out: [String] = []
        _ = host.run(script, timeout: timeout) { out.append($0) }
        if let found = parse(out.joined(separator: "\n")) { return found }
        out.removeAll()
        _ = host.runCommand(WindowsDesktop.probeCommand, timeout: timeout) { out.append($0) }
        return parse(out.joined(separator: "\n"))
    }
}

/// PowerShell's `-EncodedCommand`: the script as base64 UTF-16LE, so neither cmd.exe nor PowerShell parses it.
public enum PowerShell {
    public static func command(_ script: String, interactive: Bool = false) -> String {
        let options = interactive ? "-NoExit" : "-NoProfile -NonInteractive -OutputFormat Text"
        var utf16 = Data()
        for unit in script.utf16 { utf16.append(UInt8(unit & 0xFF)); utf16.append(UInt8(unit >> 8)) }
        return "powershell.exe -NoLogo \(options) -EncodedCommand " + utf16.base64EncodedString()
    }
}

/// Remote desktop on hosts whose OpenSSH shell is cmd.exe or PowerShell; port of Android `WindowsDesktop`.
public enum WindowsDesktop {
    private static let BIN = #"$env:USERPROFILE\.roamtty\bin"#
    private static let TASK = "Roamtty Desktop"
    /// The plugin's Windows service (installed by an administrator): the sign-in and lock screens too.
    public static let SERVICE = "RoamttyDesktop"
    /// What an administrator runs once on the PC to install the service (the hint's 复制命令 copies this).
    public static let SERVICE_INSTALL = #"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install"#
    /// cmd's "is not recognized as a command": the plugin is not installed.
    public static let NOT_FOUND = 9009

    /// Read-only: the console's signed-in user, the CPU architecture and the plugin's version line. With the
    /// plugin's service running there is a desktop even when nobody is signed in: the sign-in screen. So there
    /// is for an administrator's login, whose install sets the service up.
    public static let probeCommand: String = PowerShell.command("""
    $d = 'no'
    try {
      $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
      if ($u -and ($u -split '\\\\')[-1] -eq $env:USERNAME) { $d = 'yes' } else { $d = 'nologin' }
    } catch {}
    if ((Get-Service \(SERVICE) -ErrorAction SilentlyContinue).Status -eq 'Running') { $d = 'yes' }
    # An administrator's login can install the service, which then shows the sign-in screen.
    if ($d -eq 'nologin' -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $d = 'yes' }
    '\(DesktopProbeScript.DESKTOP)' + $d
    '\(DesktopProbeScript.UNAME)Windows ' + $env:PROCESSOR_ARCHITECTURE
    $p = "\(BIN)\\roamtty-desktop.exe"; $v = ''
    if (Test-Path $p) { $v = (& $p --version 2>$null | Select-Object -First 1) }
    '\(DesktopProbeScript.DESKTOP_PLUGIN)' + $v
    """)

    /// `serve` through cmd /c, whichever shell sshd runs: PowerShell would not pass a binary stream through.
    public static func serveCommand(_ args: String) -> String {
        #"cmd /c ""%USERPROFILE%\.roamtty\bin\roamtty-desktop.exe" serve "# + args + "\""
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Stops a running agent (its exe is locked while it runs), checks `path` against `sha`, moves it into place.
    public static func placeScript(_ path: String, sha: String) -> String {
        """
        $b = "\(BIN)"; $f = \(path)
        $h = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
        if ($h -ne \(quote(sha))) { '\(DesktopPluginInstaller.SHA_MISMATCH) ' + $h; Remove-Item -Force $f; exit 4 }
        schtasks /End /TN \(quote(TASK)) 2>$null | Out-Null
        Stop-Process -Name roamtty-desktop -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Move-Item -Force $f "$b\\roamtty-desktop.exe"
        exit 0
        """
    }

    /// The host downloads the exe itself with Windows' own curl.exe (20 s at most).
    public static func hostDownloadScript(url: String, sha: String) -> String {
        """
        $b = "\(BIN)"; New-Item -ItemType Directory -Force $b | Out-Null
        $f = "$b\\roamtty-desktop.part"
        curl.exe -fsSL --max-time 20 -o $f \(quote(url))
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $f)) { Remove-Item -Force -ErrorAction SilentlyContinue $f; '\(DesktopPluginInstaller.FETCH_FAILED)'; exit 3 }
        """ + "\n" + placeScript(#""$b\roamtty-desktop.part""#, sha: sha)
    }

    public static let mkdirScript = #"New-Item -ItemType Directory -Force "$env:USERPROFILE\.roamtty\bin", "$env:USERPROFILE\.roamtty\desktop" | Out-Null; exit 0"#

    /// OpenH264 (fetched by the plugin itself, or from `uploaded`) and the logon task (or the service when elevated).
    public static func installScript(uploaded: String? = nil) -> String {
        #"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install"# +
            (uploaded.map { #" --openh264 "$env:USERPROFILE\"# + $0 + "\"" } ?? "") + "; exit $LASTEXITCODE"
    }
}
