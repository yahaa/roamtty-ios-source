#if canImport(AVFoundation)
import AVFoundation
import RoamttyDesktopCore

/// The host's sound (AUDIO frames, Android `AudioPlayer`): each Opus packet goes through AudioToolbox's
/// decoder (`AVAudioConverter`) onto an `AVAudioEngine` player node, behind a Varispeed unit that
/// `AudioJitter`'s rate drives. The engine starts with the first packet and `stop` lets it and the
/// audio session go. The session mixes with other apps' sound, as Android's track does.
/// This file is AVFoundation-only and is **not compiled or verified on Linux**.
final class DesktopAudioPlayer: DesktopAudioSink, @unchecked Sendable {
    /// The last full second of decoded sound: the left channel's RMS level (of 32767) and its zero crossings.
    struct Level: Equatable { var rms = 0, crossings = 0 }

    private let queue = DispatchQueue(label: "roamtty.desktop.audio", qos: .userInteractive)
    private let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let opus: AVAudioFormat
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var varispeed: AVAudioUnitVarispeed?
    private var converter: AVAudioConverter?
    private var jitter = AudioJitter()
    /// Test only: decode and measure, but play at volume 0 (a simulator plays through the Mac's speakers).
    private let muted: Bool

    private let lock = NSLock()
    /// The end of what was scheduled, on the player's timeline (frames since `play`); only on `queue`.
    private var scheduledEnd: Int64 = 0
    private var _packets: Int64 = 0, _dropped: Int64 = 0, _cushions: Int64 = 0, _queuedMs = 0, _targetMs = 0
    private var _level = Level()
    private var sumSquares = 0.0, crossings = 0, samples = 0, lastLeft: Float = 0

    init(muted: Bool = false) {
        self.muted = muted
        var d = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: UInt32(AudioJitter.packetMs * 48), mBytesPerFrame: 0,
                                            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        opus = AVAudioFormat(streamDescription: &d)!
    }

    var packets: Int64 { lock.withLock { _packets } }
    var queuedMs: Int { lock.withLock { _queuedMs } }
    var dropped: Int64 { lock.withLock { _dropped } }
    var cushions: Int64 { lock.withLock { _cushions } }
    /// The backlog the jitter buffer aims for now.
    var targetMs: Int { lock.withLock { _targetMs } }
    var level: Level { lock.withLock { _level } }
    var rate: Double { queue.sync { jitter.rate } }

    func submit(_ audio: Audio) { queue.async { self.play(audio) } }

    func stop() { queue.async { self.teardown() } }

    private func play(_ audio: Audio) {
        if engine?.isRunning != true {
            // First packet, or an interruption (a call) stopped the engine: start over.
            teardown()
            guard start() else { return }
        }
        guard let node, let converter, let varispeed else { return }
        let (backlogFrames, dry) = backlog(node)
        let backlogMs = Int(backlogFrames * 1000 / 48_000)
        let decision = jitter.arrive(nowMs: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000), seq: audio.seq,
                                     backlogMs: backlogMs, ranDry: dry)
        if decision == .drop { lock.withLock { _dropped += 1 }; return }
        if case .play(let cushionMs) = decision, cushionMs > 0,
           let silence = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(cushionMs * 48)) {
            silence.frameLength = silence.frameCapacity
            schedule(silence, on: node)
            lock.withLock { _cushions += 1 }
        }
        guard let decoded = decode(audio.packet, with: converter) else { return }
        schedule(decoded, on: node)
        varispeed.rate = Float(jitter.rate)
        measure(decoded)
        lock.withLock {
            _packets += 1
            _queuedMs = Int((scheduledEnd - (rendered(node) ?? scheduledEnd)) * 1000 / 48_000)
            _targetMs = jitter.targetMs
        }
    }

    private func start() -> Bool {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Short output buffers: the player's render position, which the backlog is read from, moves in their steps.
            try? s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
            let e = AVAudioEngine(), n = AVAudioPlayerNode(), v = AVAudioUnitVarispeed()
            e.attach(n); e.attach(v)
            e.connect(n, to: v, format: pcm)
            e.connect(v, to: e.mainMixerNode, format: pcm)
            if muted { e.mainMixerNode.outputVolume = 0 }
            e.prepare()
            try e.start()
            n.play()
            engine = e; node = n; varispeed = v
            converter = AVAudioConverter(from: opus, to: pcm)
            jitter = AudioJitter()
            scheduledEnd = 0
            return converter != nil
        } catch {
            NSLog("RoamttyDesktop: audio did not start: \(error)")
            teardown()
            return false
        }
    }

    private func teardown() {
        node?.stop()
        engine?.stop()
        let wasRunning = engine != nil
        engine = nil; node = nil; varispeed = nil; converter = nil
        scheduledEnd = 0
        lock.withLock { _queuedMs = 0 }
        if wasRunning { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Frames the player has taken so far: where its render position is, before the mixer, Varispeed
    /// and the output device. (The buffers' played-back callbacks come after the device's own latency,
    /// which read as a backlog that was never there and held the rate at +3%.)
    private func rendered(_ node: AVAudioPlayerNode) -> Int64? {
        guard let t = node.lastRenderTime, t.isSampleTimeValid, let p = node.playerTime(forNodeTime: t) else { return nil }
        return p.sampleTime
    }

    /// What is scheduled and not yet taken, and whether the player ran past the end of it since the
    /// last packet. The player's time keeps running through an underrun, so the end moves up to it.
    private func backlog(_ node: AVAudioPlayerNode) -> (Int64, Bool) {
        guard let r = rendered(node) else { return (scheduledEnd, false) }
        if r >= scheduledEnd {
            let dry = scheduledEnd > 0
            scheduledEnd = r
            return (0, dry)
        }
        return (scheduledEnd - r, false)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        scheduledEnd += Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func decode(_ packet: ArraySlice<UInt8>, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(packet.count))
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(AudioJitter.packetMs * 48 * 2)) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 {
            if let error { NSLog("RoamttyDesktop: opus decode failed: \(error)") }
            return nil
        }
        return out
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let left = buffer.floatChannelData?[0] else { return }
        lock.withLock {
            for i in 0..<Int(buffer.frameLength) {
                let v = left[i]
                sumSquares += Double(v * 32767) * Double(v * 32767)
                if (v >= 0) != (lastLeft >= 0) { crossings += 1 }
                lastLeft = v
                samples += 1
                if samples == 48_000 {
                    _level = Level(rms: Int((sumSquares / 48_000).squareRoot()), crossings: crossings)
                    sumSquares = 0; crossings = 0; samples = 0
                }
            }
        }
    }
}
#endif
