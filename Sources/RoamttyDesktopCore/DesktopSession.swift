import Foundation
import Dispatch

/// What logging in gave: a host to run the desktop on, or why not.
public enum DesktopLogin {
    case host(DesktopHost)
    /// The credentials could not be read (Android: 无法读取凭据…).
    case noCredentials
    /// The host refused or could not be reached; `connecting` when the login dropped midway (a live
    /// desktop then recovers instead of failing). `message` is the SSH layer's own, nil for 无法连接服务器.
    case failed(message: String?, connecting: Bool)
}

/// Where VIDEO frames go: the VideoToolbox decoder on iOS (phase 3), a recorder in tests. The decoder calls
/// back `DesktopSession.decoded`, `rendered` and `needKeyframe`.
public protocol DesktopVideoSink: AnyObject {
    func submit(_ video: Video)
    func reset()
    var decoderName: String { get }
    var decodedFrames: Int64 { get }
}

public extension DesktopVideoSink {
    func reset() {}
}

/// The cursor the plugin reports, in native pixels of the selected display; `shape` nil until its image came.
public struct RemoteCursor: Equatable, Sendable {
    public let x: Int, y: Int, visible: Bool
    public let shape: CursorImage?
}

/// RGBA pixels, row by row, and the hot spot.
public struct CursorImage: Equatable, Sendable {
    public let width: Int, height: Int, hotX: Int, hotY: Int
    public let rgba: [UInt8]
}

/// What the network badge and the statistics show.
public struct DesktopStats: Equatable, Sendable {
    public var rttMs: Int?
    public var fps = 0, kbps = 0, width = 0, height = 0
    public var frames: Int64 = 0
    public var decoder = "", link = "SSH", encoder = ""
    /// UDP only: share of shards lost before FEC, frames FEC rebuilt, frames lost outright.
    public var lossPercent: Double?
    public var fecRecovered: Int64 = 0, lostFrames: Int64 = 0
    /// Where the last second's frames spent their time, host to screen.
    public var latency: LatencyMeter.Latency?
    /// Sound waiting to be heard on the phone, while sound plays.
    public var audioMs: Int?
    public init() {}
}

/// One host's desktop (plan §4.1): its own SSH login, the plugin's `serve` on an exec channel, frames to
/// the video sink, input from the page. It outlives the page: `pause` keeps it for the keep-alive time
/// without pictures, and a dropped link is resumed with the session token for up to 30 s.
///
/// Port of Android `DesktopConnection` (roamtty #218) without the Android parts: coroutines become one
/// worker thread for the attempt loop plus a reader, a writer and a 250 ms ticker per stream; every
/// callback goes out on `callbackQueue` in order. The SSH login, the phone's downloads, the UDP socket and
/// the video decoder are injected, so the whole flow runs in tests against a local shell or a fake host.
/// What `NWPathMonitor` said, as `DesktopSession.networkChanged` needs it.
public enum NetworkChange: Sendable, Equatable {
    /// Another interface carries the traffic, or there is one again after none.
    case newInterface
    /// The same interface, something else about the path changed.
    case pathUpdate

    /// `previous` and `current`: the interface the default route uses ("wifi:en0"), nil while there is
    /// none. Nil for the first report: that is the network the session already uses.
    public static func between(_ previous: String??, _ current: String?) -> NetworkChange? {
        guard let previous else { return nil }
        return previous == current ? .pathUpdate : .newInterface
    }
}

public final class DesktopSession: @unchecked Sendable {
    public struct Config: Sendable {
        public var hostName: String
        /// The SSH host's address; UDP goes there unless `udpHostOverride` is set.
        public var address: String
        /// The phone's screen: its long edge caps the encode size.
        public var clientWidth: Int, clientHeight: Int, clientDpi: Int
        public var fps = 60
        public var quality = "auto"
        public var lockOnClose = false
        /// The host's sound on the phone (sent only by plugins that can).
        public var audio = true
        public var keepAliveMinutes = 5
        public var udpHostOverride = ""
        /// Test only: drop this share of datagrams on both ends.
        public var testLoss = 0.0
        public var english = false

        public init(hostName: String, address: String, clientWidth: Int, clientHeight: Int, clientDpi: Int) {
            self.hostName = hostName; self.address = address
            self.clientWidth = clientWidth; self.clientHeight = clientHeight; self.clientDpi = clientDpi
        }
    }

    /// Android's constants, shortened in tests.
    public struct Timings: Sendable {
        public var recoverLimitMs: Int64 = 30_000
        public var recoverRetryMs: Int64 = 1000
        public var needsRetryMs: Int64 = 1500
        public var nologinRetryMs: Int64 = 1000
        public var notLoggedInRetryMs: Int64 = 1000
        public var tickMs: Int64 = 250
        public var exitWaitMs: Int64 = 3000
        public init() {}
    }

    public static let POOR_MS: Int64 = 300

    public let config: Config
    private let manifest: PluginManifest
    private let login: () -> DesktopLogin
    private let fetch: (String) throws -> Data
    private let makeUdp: (String, Int) throws -> UdpTransport
    private let timings: Timings
    private let callbackQueue: DispatchQueue
    /// The decoder; the session owns it, as Android's connection owns its `VideoDecoder`.
    public var video: DesktopVideoSink?
    /// The sound player; the session feeds it AUDIO frames while sound is on and the page is shown.
    public var audio: DesktopAudioSink?

    // Observers: called on `callbackQueue`, in order.
    public var onPhase: ((DesktopPhase) -> Void)?
    /// Fresh capability results let the host list replace stale desktop availability, including on retry.
    public var onProbe: ((HostDesktop) -> Void)?
    public var onLog: (([String]) -> Void)?
    public var onHello: ((Hello) -> Void)?
    public var onStats: ((DesktopStats) -> Void)?
    public var onCursor: ((RemoteCursor?) -> Void)?
    public var onRemoteClipboard: ((String) -> Void)?
    /// One-off messages for the page, e.g. 请在本机解锁; nil clears it.
    public var onNotice: ((String?) -> Void)?
    public var onVideoSize: ((Int, Int) -> Void)?
    /// Whether the host can send its sound: known with the hello, false after STATE `audio: unavailable`.
    public var onAudioAvailable: ((Bool) -> Void)?
    /// The desktop ended (closed, failed or kicked) and is no longer active.
    public var onEnded: ((DesktopSession) -> Void)?

    private let lock = NSRecursiveLock()
    private let wake = NSCondition()
    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // Serialize transport media delivery with pause/resume and stream publication. No state
    // lock is held across a sink callback; synchronous reentry on this executor is supported.
    /// How long a UDP link may hear nothing after a path update before it gets a new socket: the host
    /// answers our heartbeats (four a second), so a working link is never this quiet.
    static let pathUpdateQuietUs: Int64 = 1_500_000
    private let mediaQueue = DispatchQueue(label: "roamtty.desktop.media")
    private let mediaKey = DispatchSpecificKey<Bool>()
    private func mediaSync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: mediaKey) == true { return body() }
        return mediaQueue.sync(execute: body)
    }
    private var desiredPaused = false
    private var _phase: DesktopPhase = .idle
    private var _log: [String] = []
    private var _hello: Hello?
    private var _stats = DesktopStats()
    private var _cursor: RemoteCursor?
    private var _videoSize = (0, 0)
    private var _display = 0
    private var _viewOnly = false
    private var _fps: Int, _quality: String, _lockOnClose: Bool, _audio: Bool
    private var _audioAvailable: Bool?
    private var audioPacketsSeen: Int64 = 0
    private var _failure: DesktopText?

    private var running = false
    private var closing = false
    private var kicked = false
    private var everConnected = false
    private var agentReloaded = false
    private var serviceInstallTried = false
    private var _windowsHost = false
    private var host: DesktopHost?
    private var stream: DesktopStream?
    private var outgoing: OutQueue?
    private var link: UdpLink?
    private var sessionId: String?
    private var resumeToken: String?
    private var keepAliveGeneration = 0

    private var lastVideoFrame: Int64 = -1
    private var brokenUntilKey = false
    private var lastKeyAskMs: Int64 = 0
    private var keyAskPending = false
    private var received: [Int64: Int64] = [:]
    private var shapes: [UInt64: CursorImage] = [:]
    private var pingSentUs: Int64 = 0
    private var pingAnswered = true
    private var pingResetAtUs: Int64 = 0
    private var missedPings = 0
    private var smoothedRtt = -1.0
    private var rttSamples = 0
    private var goodSinceMs: Int64 = 0
    private var frameWindow = 0
    private var byteWindow: Int64 = 0
    private var statsAtMs: Int64 = 0
    public private(set) var inputsSent = 0
    public private(set) var inputsDropped = 0
    private let latency = LatencyMeter()

    /// `login` opens the desktop's own SSH login (called again for every attempt); `fetch` downloads on the
    /// phone (`HTTPFetch.get`); `makeUdp` opens a UDP socket to (host, port).
    public init(config: Config, manifest: PluginManifest, timings: Timings = Timings(),
                callbackQueue: DispatchQueue = DispatchQueue(label: "roamtty.desktop.callbacks"),
                login: @escaping () -> DesktopLogin,
                fetch: @escaping (String) throws -> Data = HTTPFetch.get,
                makeUdp: @escaping (String, Int) throws -> UdpTransport = { try UdpSocketTransport(host: $0, port: $1) }) {
        self.config = config; self.manifest = manifest; self.timings = timings; self.callbackQueue = callbackQueue
        self.login = login; self.fetch = fetch; self.makeUdp = makeUdp
        _fps = config.fps; _quality = config.quality; _lockOnClose = config.lockOnClose; _audio = config.audio
        mediaQueue.setSpecific(key: mediaKey, value: true)
    }

    // MARK: State

    public var phase: DesktopPhase { sync { _phase } }
    public var log: [String] { sync { _log } }
    public var hello: Hello? { sync { _hello } }
    public var stats: DesktopStats { sync { _stats } }
    public var display: Int { sync { _display } }
    public var viewOnly: Bool { sync { _viewOnly } }
    public var fps: Int { sync { _fps } }
    public var quality: String { sync { _quality } }
    public var lockOnClose: Bool { sync { _lockOnClose } }
    public var audioOn: Bool { sync { _audio } }
    /// Nil until the host said; false when it has no sound to send (an older plugin, or no audio server).
    public var audioAvailable: Bool? { sync { _audioAvailable } }
    /// Why the last attempt failed, in both languages (the phase carries it in the configured one).
    public var failure: DesktopText? { sync { _failure } }
    /// The host runs Windows (known once the probe answered): the NeedsAction card shows the service hint.
    public var windowsHost: Bool { sync { _windowsHost } }
    public var active: Bool { sync { if case .idle = _phase { return false }; if case .failed = _phase { return false }; return true } }
    /// Whether frames go over UDP right now.
    public var onUdp: Bool { sync { link?.alive ?? false } }

    private func text(_ t: DesktopText) -> String { t.text(english: config.english) }

    private func setPhase(_ p: DesktopPhase) {
        sync {
            let next: DesktopPhase
            if case .connected(let poor, _) = p { next = .connected(poor: poor, paused: desiredPaused) } else { next = p }
            if _phase != next { _phase = next; callbackQueue.async { self.onPhase?(next) } }
        }
        wakeAll()
    }

    private func line(_ s: String) {
        let snapshot: [String] = sync { _log.append(s); if _log.count > 200 { _log.removeFirst(_log.count - 200) }; return _log }
        callbackQueue.async { self.onLog?(snapshot) }
    }

    private func updateStats(_ change: (inout DesktopStats) -> Void) {
        let s: DesktopStats = sync { change(&_stats); return _stats }
        callbackQueue.async { self.onStats?(s) }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func nowUs() -> Int64 { UdpLink.monotonicUs() }

    /// Sleeps up to `ms`, waking early on `close`.
    private func pause(ms: Int64) {
        let until = Date().addingTimeInterval(Double(ms) / 1000)
        wake.lock()
        while !sync({ closing }) && Date() < until { _ = wake.wait(until: until) }
        wake.unlock()
    }

    private func wakeAll() { wake.lock(); wake.broadcast(); wake.unlock() }

    // MARK: Attempt loop

    public func start() {
        let go: Bool = sync {
            if running { return false }
            running = true; closing = false; kicked = false; agentReloaded = false; serviceInstallTried = false
            return true
        }
        guard go else { return }
        setPhase(.connecting(step: .login))
        let t = Thread { [self] in runLoop() }
        t.name = "roamtty.desktop.\(config.hostName)"
        t.start()
    }

    private enum Outcome: Equatable {
        case closed, kicked, needs, streamed
        case failed(DesktopText)
        case dropped(DesktopText?)
    }

    private func fail(_ t: DesktopText) {
        sync { _failure = t }
        setPhase(.failed(message: text(t)))
    }

    private func runLoop() {
        var recoveringSince: Int64?
        while !sync({ closing }) {
            let outcome = attempt()
            switch outcome {
            case .closed: setPhase(.idle)
            case .kicked: fail(.openedElsewhere)
            case .failed(let t): fail(t)
            case .dropped(let t):
                if !sync({ everConnected }) { fail(t ?? .cannotConnect); break }
                let since = recoveringSince ?? Self.nowMs()
                recoveringSince = since
                if Self.nowMs() - since > timings.recoverLimitMs { fail(.lostOver30s); break }
                setPhase(.recovering(sinceMs: since))
                pause(ms: timings.recoverRetryMs)
                continue
            case .streamed: recoveringSince = nil
            case .needs: pause(ms: timings.needsRetryMs); continue
            }
            if case .streamed = outcome, !sync({ closing }) {
                // The stream ran and ended by itself: try to get it back right away.
                let now = Self.nowMs()
                recoveringSince = now
                setPhase(.recovering(sinceMs: now))
                continue
            }
            break
        }
        if sync({ closing }), !{ if case .failed = phase { return true }; return false }() { setPhase(.idle) }
        let ended: Bool = sync { running = false; return !active }
        if ended { callbackQueue.async { self.onEnded?(self) } }
    }

    private func attempt() -> Outcome {
        let result = login()
        let remote: DesktopHost
        switch result {
        case .noCredentials: return .failed(.cannotReadCredentials)
        case .failed(let message, let connecting):
            if sync({ closing }) { return .closed }
            // A login that never got through is the host saying no, unless a live desktop is recovering.
            if sync({ everConnected }) || connecting { return .dropped(message.map(DesktopText.raw)) }
            return .failed(message.map(DesktopText.raw) ?? .cannotReachServer)
        case .host(let h): remote = h
        }
        let alreadyClosing: Bool = sync { if closing { return true }; host = remote; return false }
        if alreadyClosing { remote.disconnect(); return .closed }
        let outcome = loggedIn(remote)
        remote.disconnect()
        sync { host = nil }
        return sync({ closing }) ? .closed : outcome
    }

    private func probeDesktop(_ remote: DesktopHost) -> HostDesktop? {
        let found = DesktopProbeScript.probe(remote)
        if let found { callbackQueue.async { self.onProbe?(found) } }
        return found
    }

    private func loggedIn(_ remote: DesktopHost) -> Outcome {
        var probe = probeDesktop(remote)
        if probe?.uname.hasPrefix("Windows") == true { sync { _windowsHost = true } }
        while probe?.desktop == "nologin" && !sync({ closing }) {
            setPhase(.needsAction(needs: ["not-logged-in"]))
            pause(ms: timings.nologinRetryMs)
            if sync({ closing }) { break }
            probe = probeDesktop(remote)
        }
        if sync({ closing }) { return .closed }
        guard let probe else { return .failed(.cannotProbe) }
        if probe.desktop == "no" { return .failed(.noDesktop) }
        guard let targetName = PluginManifest.targetFor(probe.uname), let build = DesktopPluginInstaller.Build.pinned(manifest, target: targetName) else {
            return .failed(.unsupportedSystem)
        }
        let windows = targetName.hasPrefix("windows-")
        sync { _windowsHost = windows }
        if probe.version != manifest.version, let failed = install(remote, targetName, build) { return failed }
        var tries = 0
        while !sync({ closing }) && tries < 3 {
            tries += 1
            // While waiting on the user's permission, the guide stays up between tries.
            let showStart: Bool = sync { if everConnected { return false }; if case .needsAction = _phase { return false }; return true }
            if showStart { setPhase(.connecting(step: .start)) }
            guard let s = remote.openStream(serveCommand()) else { return .dropped(nil) }
            sync { stream = s }
            var parser = FrameParser()
            var first: String?
            reading: while true {
                let bytes = s.read(maxBytes: 64 * 1024)
                if bytes.isEmpty { break }
                parser.push(bytes)
                switch parser.next() {
                case .hello(let l): first = l; break reading
                case .tooLong: break reading
                default: continue
                }
            }
            guard let first else {
                let deadline = Self.nowMs() + timings.exitWaitMs
                while !s.isClosed && Self.nowMs() < deadline { Thread.sleep(forTimeInterval: 0.03) }
                let status = s.exitStatus
                let errors = s.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                s.close()
                if !errors.isEmpty { line(String(errors.suffix(500))) }
                if status == 127 || status == WindowsDesktop.NOT_FOUND {
                    if let failed = install(remote, targetName, build) { return failed }
                    continue
                }
                if let status, s.isClosed { return .failed(.pluginStartFailedCode(status)) }
                return .dropped(nil)
            }
            switch DesktopProtocol.parseStart(first) {
            case .failed(let code, let detail, _, _):
                s.close()
                switch code {
                case "encoder_failed", "proto_unsupported":
                    if let failed = install(remote, targetName, build) { return failed }
                case "no_desktop": return .failed(.noDesktop)
                case "not_logged_in":
                    // Someone is at the Mac's console, so the agent itself is gone (an upgrade that raced
                    // launchd unloaded it): load it again once instead of waiting.
                    if targetName.hasPrefix("macos-") && probe.desktop == "yes" && !sync({ agentReloaded }) {
                        sync { agentReloaded = true }
                        line(text(.restartingAgent))
                        let ok = DesktopPluginInstaller(remote: remote, fetch: fetch, onLine: { [weak self] in self?.line($0) }).registerAgent()
                        if ok { tries -= 1; continue }
                    }
                    // Windows: the plugin is current but runs as a logon task. An install over an
                    // administrator's login sets the service up, which serves the sign-in screen.
                    if windows && !sync({ serviceInstallTried }) {
                        sync { serviceInstallTried = true }
                        if let failed = install(remote, targetName, build) { return failed }
                        tries -= 1; continue
                    }
                    setPhase(.needsAction(needs: ["not-logged-in"]))
                    pause(ms: timings.notLoggedInRetryMs)
                default: return .failed(.pluginError(detail ?? code))
                }
            case .ready(let hello):
                let outcome = runStream(s, hello, parser: parser)
                if outcome != .needs { return outcome }
                // Every 1.5 s until the user allowed it on the host (plan §4.3: then it connects by itself).
                tries = 0
                pause(ms: timings.needsRetryMs)
            }
        }
        return sync({ closing }) ? .closed : .failed(.pluginStartFailed)
    }

    /// The `serve` command line, with the resume token once a stream ran.
    public func serveCommand() -> String {
        let (session, token, windows) = sync { (sessionId, resumeToken, _windowsHost) }
        // Resume tokens are base64: no quotes or spaces to escape in either shell.
        var resume = ""
        if let session, let token {
            let clean = String(token.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "+/=".unicodeScalars.contains($0) })
            resume = " --resume \(session) --token \(clean)"
        }
        let client = "\(max(config.clientWidth, config.clientHeight))x\(min(config.clientWidth, config.clientHeight))@\(config.clientDpi)"
        let args = "--proto \(DesktopProtocol.supported.upperBound) --client \(client)\(resume)"
        return windows ? WindowsDesktop.serveCommand(args) : "\"$HOME/.roamtty/bin/roamtty-desktop\" serve \(args)"
    }

    /// Installs or upgrades the pinned plugin; nil once it is in place, else why not.
    private func install(_ remote: DesktopHost, _ targetName: String, _ build: DesktopPluginInstaller.Build) -> Outcome? {
        setPhase(.connecting(step: .install))
        line(text(.installing(version: build.version, target: targetName)))
        let installer = DesktopPluginInstaller(remote: remote, fetch: fetch,
            onStep: { [weak self] step in guard let self else { return }; self.line(self.text(.step(step))) },
            onLine: { [weak self] l in if !l.hasPrefix("__ROAMTTY_") { self?.line(l) } })
        switch installer.install(build) {
        case .installed: return nil
        case .failed(let reason, _): return .failed(DesktopText.installFailure(reason))
        }
    }

    // MARK: Stream

    /// Frames for the SSH channel, written in order by the stream's writer thread.
    private final class OutQueue {
        private let cond = NSCondition()
        private var items: [[UInt8]] = []
        private var closed = false
        func send(_ b: [UInt8]) { cond.lock(); if !closed { items.append(b); cond.signal() }; cond.unlock() }
        func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
        /// Everything queued, or nil once closed.
        func take() -> [[UInt8]]? {
            cond.lock(); defer { cond.unlock() }
            while items.isEmpty && !closed { cond.wait() }
            if closed { return nil }
            let out = items; items.removeAll(); return out
        }
    }

    /// Runs `body` every `intervalMs` on its own thread until `stop`.
    private final class Ticker: @unchecked Sendable {
        private let cond = NSCondition()
        private var stopped = false
        init(intervalMs: Int64, _ body: @escaping () -> Void) {
            let t = Thread { [self] in
                cond.lock()
                while !stopped {
                    cond.unlock()
                    body()
                    cond.lock()
                    if stopped { break }
                    _ = cond.wait(until: Date().addingTimeInterval(Double(intervalMs) / 1000))
                }
                cond.unlock()
            }
            t.name = "roamtty.desktop.ticker"
            t.start()
        }
        func stop() { cond.lock(); stopped = true; cond.broadcast(); cond.unlock() }
    }

    private func runStream(_ s: DesktopStream, _ hello: Hello, parser initial: FrameParser) -> Outcome {
        sync { _hello = hello }
        callbackQueue.async { self.onHello?(hello) }
        if !hello.needs.isEmpty {
            setPhase(.needsAction(needs: hello.needs))
            s.close()
            sync { stream = nil }
            return sync({ closing }) ? .closed : .needs
        }
        let queue = OutQueue()
        updateStats { $0.encoder = hello.hardware }
        let canAudio = hello.audio.contains("opus")
        mediaSync {
            video?.reset()
            let first: [String: Any] = sync {
                sessionId = hello.session; resumeToken = hello.resumeToken
                if !hello.displays.indices.contains(_display) { _display = max(0, hello.displays.firstIndex { $0.primary } ?? 0) }
                lastVideoFrame = -1; brokenUntilKey = true
                _audioAvailable = canAudio
                var config: [String: Any] = ["display": _display, "fps": _fps, "quality": _quality, "lock_on_close": _lockOnClose]
                if canAudio && _audio { config["audio"] = true }
                return config
            }
            queue.send(DesktopProtocol.config(first))
            if sync({ _viewOnly }) { queue.send(DesktopProtocol.req(DesktopProtocol.REQ_VIEW_ONLY_ON)) }
            if sync({ desiredPaused }) { queue.send(DesktopProtocol.req(DesktopProtocol.REQ_PAUSE)) }
            // Publication and initial pause intent share the media executor with pause/resume.
            sync { outgoing = queue }
        }
        startUdp(hello, queue)
        callbackQueue.async { self.onAudioAvailable?(canAudio) }
        if !sync({ everConnected }) { setPhase(.connecting(step: .firstFrame)) }
        sync {
            pingSentUs = 0; pingAnswered = true; pingResetAtUs = 0; missedPings = 0; smoothedRtt = -1; rttSamples = 0
            statsAtMs = Self.nowMs()
        }
        latency.reset()

        let writer = Thread {
            while let batch = queue.take() {
                do { for b in batch { try s.write(b) } } catch { s.close(); break }
            }
        }
        writer.name = "roamtty.desktop.writer"
        writer.start()
        let ticker = Ticker(intervalMs: timings.tickMs) { [weak self] in self?.tick() }

        var parser = initial
        reading: while !sync({ closing }) {
            while let item = parser.next() {
                guard case .frame(let f) = item else { break reading }
                if let m = DesktopProtocol.decode(f) { handle(m) }
                if sync({ kicked || closing }) { break reading }
            }
            let bytes = s.read(maxBytes: 256 * 1024)
            if bytes.isEmpty { break }
            parser.push(bytes)
        }
        // The SSH channel is gone but UDP still carries the desktop: keep going on it alone, as the host
        // does, until UDP falls silent too.
        if !sync({ closing || kicked }) && sync({ link?.alive ?? false }) {
            sync { outgoing = nil }
            while !sync({ closing || kicked }) && sync({ link?.alive ?? false }) { pause(ms: 200) }
        }
        let l: UdpLink? = sync { outgoing = nil; stream = nil; let l = link; link = nil; return l }
        queue.close()
        ticker.stop()
        s.close()
        l?.close()
        updateStats { $0.link = "SSH"; $0.lossPercent = nil }
        audio?.stop()
        sync { inputsSent = 0; inputsDropped = 0 }
        if sync({ kicked }) { return .kicked }
        if sync({ closing }) { return .closed }
        return .streamed
    }

    /// Opens the host's UDP offer; the link sends its own port so a host firewall can let replies in.
    private func startUdp(_ hello: Hello, _ queue: OutQueue) {
        guard let offer = hello.udp else { return }
        let address = config.udpHostOverride.isEmpty ? config.address : config.udpHostOverride
        guard let transport = try? makeUdp(address, offer.port) else { return }
        let l = UdpLink(key: offer.key, transport: transport,
                        onFrame: { [weak self] f in if let m = DesktopProtocol.decode(f) { self?.handle(m) } },
                        onVideoLost: { [weak self] in self?.askKeyframe() },
                        log: { [weak self] in self?.line($0) })
        if config.testLoss > 0 { l.dropRate = config.testLoss; queue.send(DesktopProtocol.config(["debug_loss": config.testLoss])) }
        l.start()
        sync { link = l }
        queue.send(DesktopProtocol.config(["udp_client_port": l.localPort]))
    }

    /// At most one keyframe request a second: a lost frame on UDP otherwise asks for each one after it.
    /// A request inside that second waits for it rather than vanishing, or a still screen would stay broken.
    private func askKeyframe() {
        let now = Self.nowMs()
        let go: Bool = sync {
            if now - lastKeyAskMs < 1000 { keyAskPending = true; return false }
            keyAskPending = false; lastKeyAskMs = now; return true
        }
        if go { send(DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME)) }
    }

    /// The decoder lost its place (phase 3 calls this).
    public func needKeyframe() { askKeyframe() }

    private func tick() {
        let now = Self.nowMs()
        let nowUs = Self.nowUs()
        if sync({ keyAskPending }) { askKeyframe() }
        var ping: Int64? = sync {
            if pingAnswered && pingResetAtUs != 0 && nowUs >= pingResetAtUs { pingSentUs = 0; pingResetAtUs = 0 }
            if pingSentUs == 0 { pingAnswered = false; pingSentUs = nowUs; return nowUs }
            return nil
        }
        if let p = ping { send(DesktopProtocol.ping(p)) }
        // A ping unanswered past 300 ms is sent again (UDP may have dropped it); two in a row, or a slow
        // answer, is a poor link. Five clean seconds restore it.
        ping = sync {
            let waiting = (!pingAnswered && pingSentUs != 0) ? (nowUs - pingSentUs) / 1000 : 0
            if waiting > Self.POOR_MS { missedPings += 1; pingSentUs = nowUs; return nowUs }
            return nil
        }
        if let p = ping { send(DesktopProtocol.ping(p)) }
        let (l, rtt, missed) = sync { (link, (smoothedRtt >= 0 && rttSamples >= 3) ? Int(smoothedRtt) : 0, missedPings) }
        // On UDP the link itself says it: heartbeats answer every 250 ms, so 700 ms without a datagram is
        // a stall; heavy loss counts too. Lost pings there are just loss.
        let bad: Bool
        if let l, l.alive { bad = l.silentUs > 700_000 || l.loss > 0.25 || Int64(rtt) > Self.POOR_MS } else { bad = missed >= 2 || Int64(rtt) > Self.POOR_MS }
        let newPhase: DesktopPhase? = sync {
            if bad { goodSinceMs = 0 } else if goodSinceMs == 0 { goodSinceMs = now }
            guard case .connected(let wasPoor, let paused) = _phase else { return nil }
            let poor = bad || (wasPoor && now - goodSinceMs < 5000)
            return poor != wasPoor ? .connected(poor: poor, paused: paused) : nil
        }
        if let newPhase { setPhase(newPhase) }
        let window: (Double, Int, Int64)? = sync {
            guard now - statsAtMs >= 1000 else { return nil }
            let w = (Double(now - statsAtMs) / 1000, frameWindow, byteWindow)
            frameWindow = 0; byteWindow = 0; statsAtMs = now
            return w
        }
        if let (seconds, frames, bytes) = window {
            let udp = l?.alive ?? false
            let taken = latency.take()
            let sink = video
            let sound = audio
            let audioMs: Int? = sync {
                guard let sound, sound.packets != audioPacketsSeen else { return nil }
                audioPacketsSeen = sound.packets
                return sound.queuedMs
            }
            updateStats { s in
                s.fps = Int(Double(frames) / seconds)
                s.kbps = Int(Double(bytes) * 8 / 1000 / seconds)
                s.decoder = sink?.decoderName ?? s.decoder
                s.frames = sink?.decodedFrames ?? s.frames
                s.link = udp ? "UDP" : "SSH"
                s.lossPercent = udp ? (l?.loss ?? 0) * 100 : nil
                s.fecRecovered = l?.fecRecovered ?? 0
                s.lostFrames = l?.lostMessages ?? 0
                // A still screen sends no frames: the last measured second stands.
                s.latency = taken ?? s.latency
                s.audioMs = audioMs
            }
        }
    }

    /// Frames from either transport; UDP's arrive on its receive thread.
    private func handle(_ m: ServerMessage) {
        switch m {
        case .video, .audio: mediaSync { handleMediaOrControl(m) }
        default: handleMediaOrControl(m)
        }
    }

    private func handleMediaOrControl(_ m: ServerMessage) {
        switch m {
        case .video(let v):
            guard !sync({ desiredPaused || closing }) else { return }
            // Both transports may deliver around a switch: older frames than the newest are stale.
            enum Verdict { case stale, broken, ok }
            let verdict: Verdict = sync {
                if v.frame <= lastVideoFrame { return .stale }
                // A frame lost on UDP breaks every frame after it that refers back to it: decoding them
                // smeared the picture into stripes. Hold the last good picture until a keyframe.
                if !v.keyframe && lastVideoFrame >= 0 && v.frame != lastVideoFrame + 1 { brokenUntilKey = true }
                lastVideoFrame = v.frame
                if v.keyframe { brokenUntilKey = false }
                return brokenUntilKey ? .broken : .ok
            }
            if verdict == .stale { return }
            if verdict == .broken { askKeyframe(); return }
            let now = Self.nowUs()
            let sizeChanged: Bool = sync {
                received[v.frame] = now
                frameWindow += 1
                byteWindow += Int64(v.data.count)
                let changed = _videoSize != (v.width, v.height)
                _videoSize = (v.width, v.height)
                return changed
            }
            latency.onReceived(frame: v.frame, captureUs: v.captureUs, encodedUs: v.encodedUs, recvUs: now)
            if sizeChanged { callbackQueue.async { self.onVideoSize?(v.width, v.height) } }
            if stats.width != v.width || stats.height != v.height { updateStats { $0.width = v.width; $0.height = v.height } }
            video?.submit(v)
        case .cursorShape(let hash, let w, let h, let hx, let hy, let rgba):
            let c: RemoteCursor? = sync {
                if w > 0 && h > 0 { shapes[hash] = CursorImage(width: w, height: h, hotX: hx, hotY: hy, rgba: rgba) }
                guard let c = _cursor else { return nil }
                _cursor = RemoteCursor(x: c.x, y: c.y, visible: c.visible, shape: c.shape ?? shapes[hash])
                return _cursor
            }
            if let c { callbackQueue.async { self.onCursor?(c) } }
        case .cursorPos(let x, let y, let visible, let shape):
            let c: RemoteCursor = sync { _cursor = RemoteCursor(x: x, y: y, visible: visible, shape: shapes[shape]); return _cursor! }
            callbackQueue.async { self.onCursor?(c) }
        case .state(let st):
            if st.kicked { let s: DesktopStream? = sync { kicked = true; return stream }; s?.close(); wakeAll() }
            if let clip = st.clip { callbackQueue.async { self.onRemoteClipboard?(clip) } }
            if let needs = st.needs, !needs.isEmpty { setPhase(.needsAction(needs: needs)) }
            if let locked = st.locked {
                let notice = locked ? text(.unlockOnComputer) : nil
                callbackQueue.async { self.onNotice?(notice) }
            }
            if let e = st.error { line(e) }
            if let timing = st.timing { latency.onHostTiming(timing) }
            if let a = st.audio {
                line("host audio \(a): \(JSONValue.string(st.json["detail"]))")
                sync { _audioAvailable = false }
                audio?.stop()
                callbackQueue.async { self.onAudioAvailable?(false) }
            }
        case .audio(let a):
            let play: Bool = sync {
                _audio && !desiredPaused && !closing
            }
            if play { audio?.submit(a) }
        case .ping(let t1):
            let now = Self.nowUs()
            send(DesktopProtocol.pong(t1, now, now))
        case .pong(let t1, let t2, let t3):
            let now = Self.nowUs()
            latency.onPong(t1: t1, t2: t2, t3: t3, t4: now)
            let rtt: Int? = sync {
                guard t1 == pingSentUs && !pingAnswered else { return nil }
                pingAnswered = true
                missedPings = 0
                let rtt = Int((now - t1) / 1000)
                smoothedRtt = smoothedRtt < 0 ? Double(rtt) : smoothedRtt * 0.75 + Double(rtt) * 0.25
                rttSamples += 1
                // The next ping goes a second after this one left.
                pingResetAtUs = now + Int64(max(0, 1000 - rtt)) * 1000
                return rtt
            }
            if let rtt { updateStats { $0.rttMs = rtt } }
        }
    }

    /// The decoder output `frame` at `decodedUs` (monotonic µs): ACK it, and the desktop is up.
    public func decoded(frame: Int64, decodedUs: Int64) {
        latency.onDecoded(frame: frame, decodedUs: decodedUs)
        let recv: Int64 = sync {
            let r = received.removeValue(forKey: frame) ?? decodedUs
            // Frames that never decode are forgotten in batches, not by rebuilding the table for every frame.
            if received.count > 240 { received = received.filter { $0.key >= frame - 120 } }
            return r
        }
        send(DesktopProtocol.ack(frame: frame, recvUs: recv, decodedUs: decodedUs))
        // Only a desktop on its way up: a frame the decoder still held after a kick or a failure (UDP keeps
        // them coming until the link closes) must not bring a dead connection back to life.
        let up: Bool = sync {
            switch _phase {
            case .connecting, .recovering:
                everConnected = true
                return true
            default: return false
            }
        }
        if up { setPhase(.connected(poor: false, paused: sync { desiredPaused })) }
    }

    /// Presentation timestamp (monotonic µs); iOS approximates it with actual layer enqueue.
    public func rendered(frame: Int64, renderedUs: Int64) { latency.onRendered(frame: frame, renderedUs: renderedUs) }

    // MARK: Page input

    /// Sends a frame to the host: over UDP while it is alive (resent until acknowledged when it must arrive), else SSH.
    public func send(_ bytes: [UInt8]) {
        let (l, q) = sync { (link, outgoing) }
        if let l, l.alive { l.send(bytes, reliable: UdpLink.reliable(bytes)) } else { q?.send(bytes) }
    }

    public func input(_ bytes: [UInt8]) {
        let drop: Bool = sync { if _viewOnly { inputsDropped += 1; return true }; inputsSent += 1; return false }
        if !drop { send(bytes) }
    }

    public func setViewOnly(_ on: Bool) {
        sync { _viewOnly = on }
        send(DesktopProtocol.req(on ? DesktopProtocol.REQ_VIEW_ONLY_ON : DesktopProtocol.REQ_VIEW_ONLY_OFF))
    }
    public func setQuality(_ value: String) { sync { _quality = value }; send(DesktopProtocol.config(["quality": value])) }
    public func setFps(_ value: Int) { sync { _fps = value }; send(DesktopProtocol.config(["fps": value])) }
    public func setDisplay(_ index: Int) { sync { _display = index }; send(DesktopProtocol.config(["display": index])) }
    public func setLockOnClose(_ on: Bool) { sync { _lockOnClose = on }; send(DesktopProtocol.config(["lock_on_close": on])) }
    /// 声音: asking again after the host said it has none lets it try once more (a device plugged in since).
    public func setAudio(_ on: Bool) {
        let (known, retry): (Bool, Bool) = sync {
            _audio = on
            let retry = on && _audioAvailable == false && (_hello?.audio.contains("opus") ?? false)
            if retry { _audioAvailable = true }
            return (_audioAvailable != nil, retry)
        }
        if !on { audio?.stop() }
        if retry { callbackQueue.async { self.onAudioAvailable?(true) } }
        if known { send(DesktopProtocol.config(["audio": on])) }
    }

    // MARK: Lifecycle

    /// The page went away: no pictures, the link kept for the keep-alive time.
    public func pause() {
        let generation: Int = mediaSync {
            let generation = sync { desiredPaused = true; keepAliveGeneration += 1; return keepAliveGeneration }
            send(DesktopProtocol.req(DesktopProtocol.REQ_PAUSE))
            video?.reset()
            audio?.stop()
            if case .connected(let poor, _) = phase { setPhase(.connected(poor: poor, paused: true)) }
            return generation
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(config.keepAliveMinutes * 60)) { [weak self] in
            guard let self, self.sync({ self.keepAliveGeneration == generation }) else { return }
            self.close()
        }
    }

    public func resume() {
        mediaSync {
            sync { desiredPaused = false; keepAliveGeneration += 1; brokenUntilKey = true; lastKeyAskMs = 0 }
            if case .connected(let poor, _) = phase { setPhase(.connected(poor: poor, paused: false)) }
            send(DesktopProtocol.req(DesktopProtocol.REQ_RESUME))
            askKeyframe()
        }
        // Only a desktop that ended quietly (keep-alive over) starts again by itself; a failed one, e.g.
        // taken over by another device, waits for 重试.
        if !sync({ running }), case .idle = phase { start() }
    }

    /// A new network. On UDP: a new socket and three heartbeats now, plus a keyframe. On SSH: drop the old
    /// socket instead of waiting for keepalives; the loop resumes it.
    ///
    /// `.pathUpdate` is something else about the same network (a VPN's interface, the radio, DNS): iOS
    /// reports those too, and a new socket for each moved the port every 3-25 s on mobile data, losing
    /// what was on its way each time. Then only a UDP link that hears nothing for `pathUpdateQuietUs`
    /// gets a new socket (Wi-Fi to another Wi-Fi keeps the interface but not the socket's address); SSH
    /// is left to its pings.
    public func networkChanged(_ change: NetworkChange = .newInterface) {
        let (ok, l, s, h) = sync { (everConnected && !closing, link, stream, host) }
        guard ok else { return }
        if change == .pathUpdate {
            guard let l, l.alive else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int(Self.pathUpdateQuietUs))) { [weak self] in
                guard let self, self.sync({ self.link === l && !self.closing }), l.silentUs >= Self.pathUpdateQuietUs else { return }
                self.line("network changed, UDP silent, rebinding")
                l.rebind()
                self.sync { self.lastKeyAskMs = 0 }
                self.askKeyframe()
            }
            return
        }
        if let l, l.alive {
            line("network changed, rebinding UDP")
            l.rebind()
            sync { lastKeyAskMs = 0 }
            askKeyframe()
            return
        }
        s?.close()
        h?.disconnect()
    }

    public func close() {
        let (s, l, h, wasRunning): (DesktopStream?, UdpLink?, DesktopHost?, Bool) = sync {
            closing = true; keepAliveGeneration += 1
            return (stream, link, host, running)
        }
        s?.close()
        l?.close()
        h?.disconnect()
        mediaSync { video?.reset(); audio?.stop() }
        wakeAll()
        if !wasRunning {
            setPhase(.idle)
            callbackQueue.async { self.onEnded?(self) }
        }
    }

    /// Test only: drop this share of UDP datagrams on the phone side (1.0 blocks UDP).
    func testUdpDrop(_ rate: Double) { sync { link }?.dropRate = rate }
}
