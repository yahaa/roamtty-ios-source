import Foundation
import Combine
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// At most one desktop per host (Android `DesktopRegistry`), held by the app model so it outlives the page.
@MainActor final class DesktopStore: ObservableObject {
    @Published private(set) var controllers: [String: DesktopController] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    subscript(_ hostID: String) -> DesktopController? { controllers[hostID] }
    func put(_ c: DesktopController) {
        controllers[c.host.id] = c
        subscriptions[c.host.id] = c.$phase.removeDuplicates().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    func remove(_ hostID: String) {
        let removed = controllers.removeValue(forKey: hostID)
        subscriptions[hostID] = nil
        removed?.close()
        objectWillChange.send()
    }
    var live: [DesktopController] {
        controllers.values.filter {
            switch $0.phase {
            case .connected, .recovering, .connecting, .needsAction: return true
            default: return false
            }
        }
    }
    func networkChanged(_ change: NetworkChange) { controllers.values.forEach { $0.session.networkChanged(change) } }
}

/// One host's desktop on the main actor: owns the `DesktopSession`, the VideoToolbox decoder and the page model.
@MainActor final class DesktopController: ObservableObject {
    let host: Host
    let session: DesktopSession
    let decoder: DesktopVideoDecoder
    let page: DesktopPageModel
    /// Where the network figures sit and their drag, shared by the overlay and the touch view.
    let statsBox = DesktopStatsBox()
    let display: VideoToolboxDisplay
    let audio: DesktopAudioPlayer
    /// Nil until the host said; false when it has no sound to send.
    @Published private(set) var audioAvailable: Bool?
    #if DEBUG
    /// Test only (ROAMTTY_DESKTOP_AUDIO_PROBE=1): what the player decoded, for the live UI test.
    @Published private(set) var audioProbe = ""
    /// Test only (ROAMTTY_DESKTOP_INPUT_PROBE=1): the last gesture actions, for the live gesture UI test.
    @Published private(set) var inputProbe = ""
    private let inputProbeOn = ProcessInfo.processInfo.environment["ROAMTTY_DESKTOP_INPUT_PROBE"] == "1"
    private var inputProbeLog: [String] = []
    private var inputProbeCount = 0
    /// A new gesture: the probe shows only what it sends, and what follows it (inertia, a waiting click).
    func probeGestureStarted() {
        guard inputProbeOn else { return }
        inputProbeLog.removeAll()
        inputProbe = "#\(inputProbeCount) "
    }
    func probeInput(_ action: GestureAction) {
        guard inputProbeOn else { return }
        let token: String
        switch action {
        case .moveTo(let x, let y): token = "m\(x),\(y)"
        case .button(let b, let down): token = "b\(b)\(down ? "d" : "u")"
        case .wheel(let dx, let dy): token = "w\(dx),\(dy)"
        case .view(let v): token = String(format: "z%.2f", v.zoom)
        case .swipe(let d): token = "s\(d)"
        case .feedback(let f): token = "f\(f)"
        }
        probeToken(token)
    }
    func probeToken(_ token: String) {
        guard inputProbeOn else { return }
        // Moves and wheel steps come many at a time: one token stands for a run of them.
        if let last = inputProbeLog.last, last.first == token.first, "mwz".contains(token.first!) {
            inputProbeLog[inputProbeLog.count - 1] = token
        } else {
            inputProbeLog.append(token)
        }
        inputProbeCount += 1
        if inputProbeLog.count > 60 { inputProbeLog.removeFirst(inputProbeLog.count - 60) }
        inputProbe = "#\(inputProbeCount) " + inputProbeLog.joined(separator: " ")
    }
    #endif
    @Published private(set) var phase: DesktopPhase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var stats = DesktopStats()
    @Published private(set) var hello: Hello?
    @Published private(set) var cursor: RemoteCursor?
    @Published var notice: String?
    @Published private(set) var videoSize = (0, 0)
    @Published var clipNote: String?
    /// The gesture view's zoom and pan; the picture and the cursor are drawn where it puts them.
    @Published var viewport: Viewport?
    private(set) var prefs: DesktopHostSettings
    private let onEnded: (DesktopController) -> Void
    private let onPrefs: (DesktopHostSettings) -> Void

    var windowsHost: Bool {
        #if DEBUG
        if layoutFixture { return fixtureWindowsHost }
        #endif
        return session.windowsHost
    }
    var active: Bool { session.active }
    var viewOnly: Bool { session.viewOnly }
    var quality: String { session.quality }
    var fps: Int { session.fps }
    var lockOnClose: Bool { session.lockOnClose }
    var audioOn: Bool { session.audioOn }
    var displayIndex: Int { session.display }
    /// Input and the cursor are in the display's native pixels; the video is often scaled down from
    /// them (a 4K screen arrives 1920 wide). Before the hello, the video size stands in.
    var remoteSize: (Int, Int) {
        if let d = hello?.displays, d.indices.contains(displayIndex) { return (d[displayIndex].width, d[displayIndex].height) }
        return videoSize
    }

    init(host: Host, session: DesktopSession, prefs: DesktopHostSettings, showStats: Bool, english: Bool,
         onPrefs: @escaping (DesktopHostSettings) -> Void,
         onEnded: @escaping (DesktopController) -> Void) {
        self.host = host; self.session = session; self.prefs = prefs
        self.onPrefs = onPrefs; self.onEnded = onEnded
        decoder = DesktopVideoDecoder(name: "VideoToolbox")
        display = VideoToolboxDisplay()
        display.decoder = decoder
        decoder.display = display
        decoder.session = session
        session.video = decoder
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        audio = DesktopAudioPlayer(muted: environment["ROAMTTY_DESKTOP_AUDIO_MUTE"] == "1")
        #else
        audio = DesktopAudioPlayer()
        #endif
        session.audio = audio
        page = DesktopPageModel(pointerMode: prefs.pointerMode == "mouse" ? .mouse : .touch,
                                showStats: showStats, english: english)
        session.onPhase = { [weak self] p in Task { @MainActor in self?.phase = p } }
        session.onLog = { [weak self] l in Task { @MainActor in self?.log = l } }
        session.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
        session.onHello = { [weak self] h in Task { @MainActor in self?.hello = h } }
        session.onCursor = { [weak self] c in Task { @MainActor in self?.cursor = c } }
        session.onNotice = { [weak self] n in Task { @MainActor in self?.notice = n } }
        session.onVideoSize = { [weak self] w, h in Task { @MainActor in self?.videoSize = (w, h) } }
        session.onAudioAvailable = { [weak self] a in Task { @MainActor in self?.audioAvailable = a } }
        session.onRemoteClipboard = { [weak self] text in
            Task { @MainActor in
                UIPasteboard.general.string = text
                self?.clipNote = self?.page.clipReceivedNote(length: text.count)
            }
        }
        session.onEnded = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.active else { return }
                self.decoder.close()
                self.audio.stop()
                self.onEnded(self)
            }
        }
        decoder.attach(name: "VideoToolbox")
        #if DEBUG
        if environment["ROAMTTY_DESKTOP_AUDIO_PROBE"] == "1" {
            _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let audio = self.audio, level = audio.level
                    self.audioProbe = "audio rms=\(level.rms) crossings=\(level.crossings) packets=\(audio.packets) dropped=\(audio.dropped) "
                        + "queued=\(audio.queuedMs) target=\(audio.targetMs) cushions=\(audio.cushions) rate=\(Int((audio.rate * 1000).rounded()))"
                }
            }
        }
        #endif
    }

    func start() { session.start() }
    func close() { session.close() }
    func pause() { session.pause() }
    #if DEBUG
    private var layoutFixture = false
    private var fixtureWindowsHost = false
    private var fixtureRecoverySequence = false
    func configureLayoutFixture(status: String? = nil, english: Bool = false) {
        layoutFixture = true
        fixtureRecoverySequence = status == "recovery-sequence"
        switch status {
        case "login": phase = .connecting(step: .login)
        case "install": phase = .connecting(step: .install)
        case "start": phase = .connecting(step: .start)
        case "first-frame": phase = .connecting(step: .firstFrame)
        case "needs-screen-recording": phase = .needsAction(needs: ["screen-recording"])
        case "needs-accessibility": phase = .needsAction(needs: ["accessibility"])
        case "needs-windows":
            fixtureWindowsHost = true
            phase = .needsAction(needs: ["not-logged-in"])
        case "failed": phase = .failed(message: DesktopText.noDesktop.text(english: english))
        case "recovering": phase = .recovering(sinceMs: Int64(Date().timeIntervalSince1970 * 1000) - 3_000)
        case "poor-network": phase = .connected(poor: true)
        default: phase = .connected()
        }
        if status == nil || status == "connected" || status == "recovering" || status == "stats" || status == "poor-network" || fixtureRecoverySequence { videoSize = (1280, 720) }
        if status == "stats" || status == "poor-network" {
            stats.link = "UDP"; stats.rttMs = 15; stats.fps = 60; stats.kbps = 2400
            stats.width = 1920; stats.height = 1246; stats.encoder = "videotoolbox"
            stats.lossPercent = 0; stats.latency = .init(captureMs: 2, convertMs: 1, encodeMs: 3,
                                                      networkMs: 15, decodeMs: 1, renderMs: 0, totalMs: 22)
        }
        log = [DesktopText.step(.hostDownload).text(english: english),
               DesktopText.installing(version: "0.8.2", target: "linux-x86_64").text(english: english)]
    }
    #endif
    func resume() {
        #if DEBUG
        if layoutFixture {
            if videoSize.0 > 0 { display.showLayoutFixture() }
            return
        }
        #endif
        session.resume()
    }
    func input(_ bytes: [UInt8]) {
        #if DEBUG
        if inputProbeOn, bytes.count == 5, Int(bytes[0]) == DesktopProtocol.ACTION { probeToken("a\(bytes[4])") }
        // Existing rail actions drive real in-place phase transitions in the isolated UI fixture.
        if fixtureRecoverySequence {
            if bytes == DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS) {
                phase = .recovering(sinceMs: Int64(Date().timeIntervalSince1970 * 1000))
            } else if bytes == DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP) {
                phase = .connected()
            }
            return
        }
        #endif
        session.input(bytes)
    }
    func send(_ bytes: [UInt8]) { session.send(bytes) }

    func setViewOnly(_ on: Bool) { objectWillChange.send(); session.setViewOnly(on) }
    func setQuality(_ q: String) { objectWillChange.send(); session.setQuality(q); prefs.quality = q; onPrefs(prefs) }
    func setFps(_ f: Int) { objectWillChange.send(); session.setFps(f); prefs.fps = f; onPrefs(prefs) }
    func setDisplay(_ i: Int) { objectWillChange.send(); session.setDisplay(i) }
    func setLockOnClose(_ on: Bool) { objectWillChange.send(); session.setLockOnClose(on); prefs.lockOnClose = on; onPrefs(prefs) }
    func setAudio(_ on: Bool) { objectWillChange.send(); session.setAudio(on); prefs.audio = on; onPrefs(prefs) }
    func setPointerMode(_ mode: PointerMode) {
        page.pointerMode = mode
        prefs.pointerMode = mode == .mouse ? "mouse" : "touch"
        onPrefs(prefs)
    }
    func setShowStats(_ on: Bool) { page.showStats = on }
}
