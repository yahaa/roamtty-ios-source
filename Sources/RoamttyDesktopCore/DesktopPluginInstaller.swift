import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Installs roamtty-desktop: download → upload → verify → register (plan §6.3). The host downloads
/// first; when it cannot reach the release, the phone downloads and uploads over SFTP. Either way the
/// unpacked binary must match the SHA-256 pinned in the app. Port of Android `DesktopPluginInstaller`
/// (ssh-core, roamtty #218); the scripts are the same text.
public final class DesktopPluginInstaller {
    /// One pinned build for the host's target. `openh264Url` is Cisco's .bz2 for it, nil when not needed.
    /// A `.zip` `url` is the notarized macOS app: `sha256` is the archive's own, it is unpacked into
    /// ~/.roamtty and its binary linked to ~/.roamtty/bin; `roamtty-desktop install` then starts the agent.
    public struct Build: Equatable, Sendable {
        public let version: String, url: String, sha256: String
        public let openh264Url: String?
        public init(version: String, url: String, sha256: String, openh264Url: String?) {
            self.version = version; self.url = url; self.sha256 = sha256; self.openh264Url = openh264Url
        }
        public var app: Bool { url.hasSuffix(".zip") }
        /// A native Windows host: PowerShell scripts, an .exe, a logon task or service.
        public var windows: Bool { url.hasSuffix(".exe") }

        /// The pinned build of `manifest` for `target` (e.g. linux-x86_64), with its OpenH264 where one is needed.
        public static func pinned(_ manifest: PluginManifest, target: String) -> Build? {
            guard let t = manifest.targets[target] else { return nil }
            let openh264 = PluginManifest.openh264File(target: target, version: manifest.openh264).map { "\(PluginManifest.OPENH264_BASE)/\($0)" }
            return Build(version: manifest.version, url: manifest.url(t), sha256: t.sha256, openh264Url: openh264)
        }
    }

    public enum Step: Sendable, CaseIterable { case hostDownload, phoneDownload, upload, verify, encoderHost, encoderPhone, register, done }
    public enum Reason: Sendable { case download, checksum, encoder, host }
    public enum Result: Equatable, Sendable {
        case installed
        case failed(Reason, detail: String = "")
    }

    public static let FETCH_FAILED = "__ROAMTTY_FETCH_FAILED__"
    public static let SHA_MISMATCH = "__ROAMTTY_SHA_MISMATCH__"

    private let remote: DesktopHost
    private let fetch: (String) throws -> Data
    private let onStep: (Step) -> Void
    private let onLine: (String) -> Void

    /// `fetch` downloads a URL on the phone, following redirects (`HTTPFetch.get`).
    public init(remote: DesktopHost, fetch: @escaping (String) throws -> Data, onStep: @escaping (Step) -> Void = { _ in },
                onLine: @escaping (String) -> Void = { _ in }) {
        self.remote = remote; self.fetch = fetch; self.onStep = onStep; self.onLine = onLine
    }

    private func run(_ script: String, _ timeout: TimeInterval) -> Int? { remote.run(script, timeout: timeout, onLine: onLine) }

    public func install(_ build: Build) -> Result {
        if build.windows { return installWindows(build) }
        if run(#"mkdir -p "$HOME/.roamtty/bin" "$HOME/.roamtty/desktop""#, 15) != 0 { return .failed(.host, detail: "mkdir") }
        onStep(.hostDownload)
        let hostStatus = run(build.app ? Self.hostAppScript(build) : Self.hostDownloadScript(build), 60)
        if hostStatus != 0 && build.app {
            onStep(.phoneDownload)
            let zip: Data
            do { zip = try fetch(build.url) } catch { return .failed(.download, detail: "\(error)") }
            let got = PluginManifest.sha256Hex(zip)
            if got != build.sha256 { return .failed(.checksum, detail: got) }
            onStep(.upload)
            let part = ".roamtty/bin/.roamtty-desktop-\(UUID().uuidString).zip"
            do { try remote.upload(zip, to: part) } catch { return .failed(.host, detail: "\(error)") }
            onStep(.verify)
            if run(Self.placeAppScript("$HOME/\(part)", sha: build.sha256), 30) != 0 { return .failed(.checksum) }
        } else if hostStatus != 0 {
            onStep(.phoneDownload)
            let packed: Data
            do { packed = try fetch(build.url) } catch { return .failed(.download, detail: "\(error)") }
            let binary: [UInt8]
            do { binary = try Gzip.decompress(Array(packed)) } catch { return .failed(.checksum, detail: "gzip") }
            let got = PluginManifest.sha256Hex(Data(binary))
            if got != build.sha256 { return .failed(.checksum, detail: got) }
            onStep(.upload)
            let part = ".roamtty/bin/.roamtty-desktop-\(UUID().uuidString).part"
            do { try remote.upload(Data(binary), to: part) } catch { return .failed(.host, detail: "\(error)") }
            onStep(.verify)
            if run(Self.placeScript("$HOME/\(part)", sha: build.sha256), 15) != 0 { return .failed(.checksum) }
        }
        if let url = build.openh264Url {
            onStep(.encoderHost)
            if run(#"exec 2>&1; "$HOME/.roamtty/bin/roamtty-desktop" install"#, 30) != 0 {
                onStep(.encoderPhone)
                let packed: Data
                do { packed = try fetch(url) } catch { return .failed(.encoder, detail: "\(error)") }
                let part = ".roamtty/desktop/openh264-\(UUID().uuidString).bz2"
                do { try remote.upload(packed, to: part) } catch { return .failed(.host, detail: "\(error)") }
                // The plugin unpacks it and loads only Cisco's own build (it checks the hash).
                let status = run(#"exec 2>&1; f="$HOME/"# + part + #""; "$HOME/.roamtty/bin/roamtty-desktop" install --openh264 "$f"; s=$?; rm -f "$f"; exit $s"#, 30)
                if status != 0 { return .failed(.encoder) }
            }
        }
        onStep(.register)
        // macOS: (re)load the LaunchAgent; it runs in the GUI session, where TCC permissions apply.
        if build.app && !registerAgent() { return .failed(.host, detail: "agent") }
        onStep(.done)
        return .installed
    }

    /// macOS: reloads the installed plugin's LaunchAgent in the GUI session; false when it did not come up.
    public func registerAgent() -> Bool { run(#"exec 2>&1; "$HOME/.roamtty/bin/roamtty-desktop" install"#, 30) == 0 }

    private func ps(_ script: String, _ timeout: TimeInterval) -> Int? {
        remote.runCommand(PowerShell.command(script), timeout: timeout, onLine: onLine)
    }

    private func installWindows(_ build: Build) -> Result {
        if ps(WindowsDesktop.mkdirScript, 15) != 0 { return .failed(.host, detail: "mkdir") }
        onStep(.hostDownload)
        if ps(WindowsDesktop.hostDownloadScript(url: build.url, sha: build.sha256), 60) != 0 {
            onStep(.phoneDownload)
            let exe: Data
            do { exe = try fetch(build.url) } catch { return .failed(.download, detail: "\(error)") }
            let got = PluginManifest.sha256Hex(exe)
            if got != build.sha256 { return .failed(.checksum, detail: got) }
            onStep(.upload)
            // Windows OpenSSH's SFTP starts in the user's profile.
            let part = ".roamtty/bin/roamtty-desktop-\(UUID().uuidString).part"
            do { try remote.upload(exe, to: part) } catch { return .failed(.host, detail: "\(error)") }
            onStep(.verify)
            let windowsPart = part.replacingOccurrences(of: "/", with: "\\")
            if ps(WindowsDesktop.placeScript(#""$env:USERPROFILE\"# + windowsPart + "\"", sha: build.sha256), 30) != 0 {
                return .failed(.checksum)
            }
        }
        onStep(.encoderHost)
        var status = ps(WindowsDesktop.installScript(), 60)
        if status == 3, let url = build.openh264Url {
            onStep(.encoderPhone)
            let packed: Data
            do { packed = try fetch(url) } catch { return .failed(.encoder, detail: "\(error)") }
            let part = ".roamtty/desktop/openh264-\(UUID().uuidString).bz2"
            do { try remote.upload(packed, to: part) } catch { return .failed(.host, detail: "\(error)") }
            status = ps(WindowsDesktop.installScript(uploaded: part.replacingOccurrences(of: "/", with: "\\")), 60)
        }
        onStep(.register)
        if status != 0 { return .failed(status == 3 ? .encoder : .host, detail: "install \(status.map(String.init) ?? "nil")") }
        onStep(.done)
        return .installed
    }

    /// Checks `path` against `sha` and renames it into place atomically; the checksum tool differs by system.
    public static func placeScript(_ path: String, sha: String) -> String {
        """
        exec 2>&1
        f="\(path)"
        got=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null) | cut -d' ' -f1)
        if [ "$got" != "\(sha)" ]; then echo \(SHA_MISMATCH) "$got"; rm -f "$f"; exit 4; fi
        chmod 755 "$f" && mv -f "$f" "$HOME/.roamtty/bin/roamtty-desktop"
        """
    }

    /// Checks the archive `path` against `sha`, unpacks the app into ~/.roamtty and links its binary.
    public static func placeAppScript(_ path: String, sha: String) -> String {
        """
        exec 2>&1
        f="\(path)"
        got=$( (shasum -a 256 "$f" 2>/dev/null || sha256sum "$f" 2>/dev/null) | cut -d' ' -f1)
        if [ "$got" != "\(sha)" ]; then echo \(SHA_MISMATCH) "$got"; rm -f "$f"; exit 4; fi
        d="$HOME/.roamtty"
        rm -rf "$d/.app-new" && mkdir -p "$d/.app-new" && ditto -x -k "$f" "$d/.app-new" || { rm -f "$f"; exit 5; }
        rm -f "$f"
        rm -rf "$d/Roamtty Desktop.app" && mv "$d/.app-new/Roamtty Desktop.app" "$d/" && rm -rf "$d/.app-new"
        mkdir -p "$d/bin" && ln -sf "$d/Roamtty Desktop.app/Contents/MacOS/roamtty-desktop" "$d/bin/roamtty-desktop"
        """
    }

    public static func hostAppScript(_ build: Build) -> String {
        let url = build.url.replacingOccurrences(of: "'", with: "")
        return """
        exec 2>&1
        f="$HOME/.roamtty/bin/.roamtty-desktop.zip"
        if ! curl -fsSL --max-time 20 '\(url)' -o "$f" || [ ! -s "$f" ]; then rm -f "$f"; echo \(FETCH_FAILED); exit 3; fi
        """ + "\n" + placeAppScript("$f", sha: build.sha256)
    }

    public static func hostDownloadScript(_ build: Build) -> String {
        let url = build.url.replacingOccurrences(of: "'", with: "")
        return """
        exec 2>&1
        f="$HOME/.roamtty/bin/.roamtty-desktop.part"
        fetch() {
          if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 10 '\(url)'
          elif command -v wget >/dev/null 2>&1; then wget -q -T 10 -O - '\(url)'
          else return 9; fi
        }
        if ! fetch | gzip -dc > "$f" 2>/dev/null || [ ! -s "$f" ]; then rm -f "$f"; echo \(FETCH_FAILED); exit 3; fi
        """ + "\n" + placeScript("$f", sha: build.sha256)
    }
}

/// Downloads on the phone (the installer's fallback), following redirects; 15 s to connect, 30 s idle.
public enum HTTPFetch {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    public static func get(_ url: String) throws -> Data {
        guard let u = URL(string: url) else { throw Failure(description: "bad url") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: Result<Data, Error> = .failure(Failure(description: "no response")) }
        let box = Box()
        let task = session.dataTask(with: URLRequest(url: u, timeoutInterval: 15)) { data, response, error in
            if let error { box.result = .failure(error) } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.result = .failure(Failure(description: "HTTP \(http.statusCode)"))
            } else { box.result = .success(data ?? Data()) }
            done.signal()
        }
        task.resume()
        done.wait()
        return try box.result.get()
    }
}
