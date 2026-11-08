import Foundation

/// A synchronous presentation sink. The decoder serializes all presentation calls on the sink's
/// video executor, and all AVCC conversions on its conversion executor (off the UI thread on iOS).
/// Existing sinks can keep the default immediate executors and unconditional readiness.
public protocol DesktopVideoDisplay: AnyObject {
    /// `rendered` belongs to this submission, including its decoder generation. Call it only
    /// after a successful enqueue; retaining the closure does not make `present` asynchronous.
    func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8], rendered: @escaping (Int64) -> Void)
    func flush()
    func scheduleVideoWork(_ work: @escaping () -> Void)
    /// Runs one conversion pass. A serial background queue keeps Annex-B parsing and copying off the
    /// presentation executor; passes never overlap, as the decoder starts the next only after one ends.
    func scheduleConversionWork(_ work: @escaping () -> Void)
    var isReadyForMoreVideo: Bool { get }
    func notifyWhenReadyForVideo(_ work: @escaping () -> Void)
    func cancelVideoReadinessNotification()
}

public extension DesktopVideoDisplay {
    func scheduleVideoWork(_ work: @escaping () -> Void) { work() }
    func scheduleConversionWork(_ work: @escaping () -> Void) { work() }
    var isReadyForMoreVideo: Bool { true }
    func notifyWhenReadyForVideo(_ work: @escaping () -> Void) { work() }
    func cancelVideoReadinessNotification() {}
}

/// A bounded inbox precedes conversion AND display scheduling. At most four access units and
/// 8 MiB of Annex-B data (including the units converting and presenting) are retained. Units are
/// converted in submission order by one conversion pass at a time, then presented in that order by
/// one drain at a time; incoming SSH/UDP calls never queue a closure per frame.
/// Overload invalidates the entire dependent GOP and waits for a fresh keyframe, keeping the
/// last picture on screen: only reset/detach flush the display.
public final class DesktopVideoDecoder: DesktopVideoSink, @unchecked Sendable {
    public weak var session: DesktopSession?
    public weak var display: DesktopVideoDisplay?
    /// A submitted unit, until it is presented; `avcc` is set once it is converted.
    private struct Entry {
        let id: UInt64
        let video: Video
        var avcc: [UInt8]?
    }
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var nextID: UInt64 = 0
    private var pendingBytes = 0, activeBytes = 0
    private var active = false, scheduled = false, draining = false, waiting = false
    private var scheduling = false
    /// The unit a conversion pass is working on, and whether an invalidation dropped it from `pending`
    /// while it converts: its bytes still count against the limits until the pass lets go of it.
    private var converting: (id: UInt64, bytes: Int)?
    private var convertingDetached = false
    private var conversionRunning = false
    private var flushNeeded = false
    private var generation: UInt64 = 0
    private var awaitingRender: [Int64: UInt64] = [:]
    private var size = (0, 0)
    private var ready = false
    private var _name = ""
    private var _decoded: Int64 = 0
    /// Configure before attaching. Runs on the conversion executor, never concurrently.
    public var makeAvcc: (([UInt8], Int) -> [UInt8])? = H264.avcc
    private let frameLimit = 4, byteLimit = 8 * 1024 * 1024

    public var decoderName: String { locked { _name } }
    public var decodedFrames: Int64 { locked { _decoded } }
    public init(name: String = "pending") { _name = name }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func attach(name: String) {
        locked { _name = name; ready = true; invalidate(flush: false) }
        kick()
        session?.needKeyframe()
    }
    public func detach() {
        locked { ready = false; invalidate() }
        kick()
    }
    /// Called only while holding the state lock. The active conversion and presentation check their
    /// generation before use; a reset during a callback is drained as a flush before the next frame.
    private func invalidate(flush: Bool = true) {
        generation &+= 1
        size = (0, 0); pending.removeAll(); pendingBytes = 0
        if converting != nil { convertingDetached = true }
        awaitingRender.removeAll(); waiting = false
        flushNeeded = flushNeeded || flush
    }
    /// Units retained and their bytes, including a conversion that no longer belongs to `pending`.
    private var retained: (count: Int, bytes: Int) {
        let detached = convertingDetached ? (converting?.bytes ?? 0) : 0
        return (pending.count + (active ? 1 : 0) + (convertingDetached ? 1 : 0), pendingBytes + activeBytes + detached)
    }

    public func submit(_ video: Video) {
        var ask = false
        locked {
            guard ready else { return }
            if retained.count >= frameLimit || retained.bytes + video.data.count > byteLimit {
                // Drop frames, not the picture: flushing here blanks the screen on every main-thread stall.
                invalidate(flush: false); ask = true
            }
            guard retained.bytes + video.data.count <= byteLimit else { return }
            if size == (0, 0) || (video.keyframe && size != (video.width, video.height)) {
                guard video.keyframe else { return }
                let headers = H264.spsPps(video.data, offset: video.offset)
                guard headers.sps != nil, headers.pps != nil else { ask = true; return }
                size = (video.width, video.height)
            }
            pending.append(Entry(id: nextID, video: video)); nextID &+= 1; pendingBytes += video.data.count
        }
        if ask { session?.needKeyframe() }
        convert()
        kick()
    }

    /// Starts a conversion pass unless one runs. A pass converts every unconverted unit in order, then
    /// hands each to the drain; the pass that sees nothing left to do is the one that clears the flag.
    private func convert() {
        let start = locked { () -> Bool in
            guard !conversionRunning, pending.contains(where: { $0.avcc == nil }) else { return false }
            conversionRunning = true; return true
        }
        guard start else { return }
        let pass: () -> Void = { [weak self] in self?.conversionPass() }
        if let display { display.scheduleConversionWork(pass) } else { pass() }
    }

    private func conversionPass() {
        while true {
            let job: (id: UInt64, video: Video)? = locked {
                guard let entry = pending.first(where: { $0.avcc == nil }) else { conversionRunning = false; return nil }
                converting = (entry.id, entry.video.data.count); convertingDetached = false
                return (entry.id, entry.video)
            }
            guard let job else { return }
            let avcc = makeAvcc?(job.video.data, job.video.offset) ?? []
            locked {
                if let index = pending.firstIndex(where: { $0.id == job.id }) { pending[index].avcc = avcc }
                converting = nil; convertingDetached = false
            }
            kick()
        }
    }

    private func kick() {
        let owner = locked { () -> Bool in
            guard !scheduling else { return false }
            scheduling = true; return true
        }
        guard owner else { return }
        // Trampoline for legacy immediate executors: a bounded batch may request another
        // batch inline, but must not accumulate stack frames under continuous input.
        while true {
            let go = locked { () -> Bool in
                guard !scheduled, !draining, !waiting, flushNeeded || pending.first?.avcc != nil else {
                    scheduling = false; return false
                }
                scheduled = true; return true
            }
            guard go else { return }
            // iOS schedules one coalesced main task; test/non-UI sinks may drain inline.
            if let display { display.scheduleVideoWork { [weak self] in self?.drain() } } else { drain() }
        }
    }

    private func drain() {
        locked { scheduled = false; draining = true }
        var processed = 0
        while true {
            let flush = locked { () -> Bool in
                if flushNeeded { flushNeeded = false; return true }; return false
            }
            if flush { display?.cancelVideoReadinessNotification(); display?.flush() }
            let hasWork = locked { pending.first?.avcc != nil }
            if hasWork, let display, !display.isReadyForMoreVideo {
                locked { waiting = true; draining = false }
                display.notifyWhenReadyForVideo { [weak self] in
                    guard let self else { return }
                    self.locked { self.waiting = false }
                    self.kick()
                }
                // Reset/overflow may have happened just before waiting was set.
                let reset = locked { () -> Bool in
                    if flushNeeded { waiting = false; return true }; return false
                }
                if reset { kick() }
                return
            }
            // The next unit in order, once converted; an unconverted one ends the drain until its pass kicks it.
            let next: (Video, [UInt8], UInt64)? = locked {
                if flushNeeded { return nil }
                guard let entry = pending.first, let avcc = entry.avcc else { draining = false; return nil }
                pending.removeFirst(); pendingBytes -= entry.video.data.count
                active = true; activeBytes = entry.video.data.count
                return (entry.video, avcc, generation)
            }
            guard let (v, avcc, token) = next else {
                if locked({ draining }) { continue }
                kick(); return
            }
            let valid = locked { () -> Bool in
                guard ready, generation == token else { return false }
                _decoded += 1
                awaitingRender[v.frame] = token
                if awaitingRender.count > 120 {
                    for frame in awaitingRender.keys.sorted().dropLast(120) { awaitingRender.removeValue(forKey: frame) }
                }
                return true
            }
            if valid {
                // ACK/decoded must precede even a synchronous display callback. The callback
                // reports layer enqueue, not physical scan-out, on AVSampleBufferDisplayLayer.
                let now = UdpLink.monotonicUs()
                session?.decoded(frame: v.frame, decodedUs: now)
                if locked({ ready && generation == token }) {
                    if let display {
                        display.present(frame: v.frame, keyframe: v.keyframe, width: v.width, height: v.height,
                                        annexB: v.data, offset: v.offset, avcc: avcc, rendered: { [weak self, frame = v.frame] renderedUs in
                            self?.didRender(frame: frame, generation: token, renderedUs: renderedUs)
                        })
                    } else { didRender(frame: v.frame, generation: token, renderedUs: now) }
                }
            }
            locked { active = false; activeBytes = 0 }
            processed += 1
            if processed == frameLimit {
                locked { draining = false }
                kick() // At most four presentations before yielding the UI executor.
                return
            }
        }
    }

    /// The submission-bound `rendered` closure of `present` lands here. On iOS the timestamp
    /// measures actual layer enqueue, not physical scan-out.
    private func didRender(frame: Int64, generation token: UInt64, renderedUs: Int64) {
        let current = locked { () -> Bool in
            guard generation == token, awaitingRender[frame] == token else { return false }
            awaitingRender.removeValue(forKey: frame)
            return true
        }
        if current { session?.rendered(frame: frame, renderedUs: renderedUs) }
    }
    public func reset() {
        locked { invalidate() }
        kick()
        session?.needKeyframe()
    }
    public func close() {
        detach()
        // Keep the weak display until the serialized flush executes. Queued work captures
        // the decoder weakly, so closing never extends either object's lifetime.
        session = nil
    }
}

/// The frame rate and picture quality choices of the desktop page.
public enum DesktopPreferences {
    public static let qualities = ["auto", "smooth", "clear", "original"]
    public static let fpsOptions = [30, 60, 90, 120]
}

/// Whether a host's stored `system` has a pinned plugin build (Android `desktopSupported`).
public enum DesktopSupport {
    public static func osSupported(_ system: String, targets: Set<String>) -> Bool {
        switch system.uppercased() {
        case "MACOS": return targets.contains("macos-universal")
        case "WINDOWS": return targets.contains { $0.hasPrefix("windows-") }
        default:
            // Linux and its distros: any linux-* target.
            return targets.contains { $0.hasPrefix("linux-") } && system.uppercased() != "UNKNOWN" && system.uppercased() != "OTHER"
        }
    }

    public static func osSupported(_ system: String, manifest: PluginManifest) -> Bool {
        osSupported(system, targets: Set(manifest.targets.keys))
    }

    /// The `DesktopButton.derive` `os` argument: MACOS / WINDOWS / LINUX.
    public static func buttonOS(_ system: String) -> String {
        switch system.uppercased() {
        case "MACOS": return "MACOS"
        case "WINDOWS": return "WINDOWS"
        default: return "LINUX"
        }
    }
}
