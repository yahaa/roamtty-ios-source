import XCTest
@testable import RoamttyDesktopCore

/// Android `UdpPluginIntegrationTest`: this client against the real plugin on loopback. Needs a built
/// plugin and an X display with OpenH264 installed under HOME: ROAMTTY_DESKTOP_BIN, ROAMTTY_DESKTOP_HOME,
/// DISPLAY. Skipped otherwise.
final class UdpPluginIntegrationTests: XCTestCase {
    struct Fixture { let bin: String, home: String, display: String }

    static func fixture() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        guard let bin = env["ROAMTTY_DESKTOP_BIN"], let home = env["ROAMTTY_DESKTOP_HOME"], let display = env["DISPLAY"],
              FileManager.default.isExecutableFile(atPath: bin) else { throw XCTSkip("plugin fixture not configured") }
        return Fixture(bin: bin, home: home, display: display)
    }

    final class Serve {
        let stream: ProcessStream
        let hello: Hello
        private let lock = NSLock()
        private var _sshVideo = 0
        var sshVideo: Int { lock.lock(); defer { lock.unlock() }; return _sshVideo }

        init(_ f: Fixture) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: f.bin)
            p.arguments = ["serve", "--proto", "1", "--client", "1280x720@160"]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = f.home; env["DISPLAY"] = f.display; env["ROAMTTY_DESKTOP_TEST"] = "1"
            env.removeValue(forKey: "SSH_CLIENT")
            p.environment = env
            _ = LocalShellHost.ignoreSigpipe
            stream = try ProcessStream(p)
            var parser = FrameParser()
            var hello: Hello?
            while hello == nil {
                let bytes = stream.read(maxBytes: 4096)
                guard !bytes.isEmpty else { throw XCTSkip("serve ended: \(stream.errorOutput)") }
                parser.push(bytes)
                if case .hello(let line)? = parser.next() {
                    guard case .ready(let h) = DesktopProtocol.parseStart(line) else { throw XCTSkip("serve failed: \(line)") }
                    hello = h
                }
            }
            self.hello = hello!
            let leftover = parser
            Thread.detachNewThread { [self] in
                var parser = leftover
                while true {
                    while case .frame(let f)? = parser.next() { if f.type == DesktopProtocol.VIDEO { lock.lock(); _sshVideo += 1; lock.unlock() } }
                    let bytes = stream.read(maxBytes: 65536)
                    if bytes.isEmpty { return }
                    parser.push(bytes)
                }
            }
        }

        func send(_ frame: [UInt8]) { try? stream.write(frame) }
        func stop() { stream.close(); stream.kill() }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(Int64, Date)] = []
        private var lost = 0
        func add(_ f: Int64) { lock.lock(); frames.append((f, Date())); lock.unlock() }
        func lose() { lock.lock(); lost += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    private func waitFor(_ seconds: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > end { XCTFail("timed out: \(what)"); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func link(_ s: Serve, frames: Counter, keyframeOnLoss: Bool = false) throws -> UdpLink {
        let udp = try XCTUnwrap(s.hello.udp)
        let transport = try UdpSocketTransport(host: "127.0.0.1", port: udp.port)
        final class Ref: @unchecked Sendable { var link: UdpLink? }
        let ref = Ref()
        let l = UdpLink(key: udp.key, transport: transport, onFrame: { f in
            guard f.type == DesktopProtocol.VIDEO, case .video(let v)? = DesktopProtocol.decode(f) else { return }
            frames.add(v.frame)
            ref.link?.send(DesktopProtocol.ack(frame: v.frame, recvUs: 0, decodedUs: 0), reliable: false)
        }, onVideoLost: {
            frames.lose()
            if keyframeOnLoss { ref.link?.send(DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME), reliable: true) }
        })
        ref.link = l
        l.start()
        return l
    }

    func testVideoOverUdpWithLossFallbackAndRoaming() throws {
        let f = try Self.fixture()
        // Something to type into, under the pointer (no window manager: focus follows the pointer), so the
        // screen changes and frames keep coming. Android's CI display had one already.
        let xterm = try typingTarget(f)
        defer { xterm?.terminate() }
        let s = try Serve(f)
        defer { s.stop() }
        let udp = try XCTUnwrap(s.hello.udp)
        XCTAssertTrue((60000..<61000).contains(udp.port))
        let frames = Counter()
        let link = try link(s, frames: frames, keyframeOnLoss: true)
        defer { link.close() }
        waitFor(5, "first video over UDP") { frames.count > 0 }
        XCTAssertTrue(link.alive)

        // 5% loss each way: typing keeps the screen changing; FEC and resends carry it.
        s.send(DesktopProtocol.config(["debug_loss": 0.05]))
        link.dropRate = 0.05
        Thread.sleep(forTimeInterval: 0.3)
        let before = frames.count
        let typed = "UDP_LOSS_\(UInt64(Date().timeIntervalSince1970 * 1e6))"
        link.send(DesktopProtocol.abs(display: 0, x: 100, y: 100), reliable: false)
        for i in 0..<60 { link.send(DesktopProtocol.text("\(typed.prefix(4))\(i) "), reliable: true); Thread.sleep(forTimeInterval: 0.08) }
        Thread.sleep(forTimeInterval: 0.8)
        let got = frames.count - before
        print("loss run: frames=\(got) lost=\(link.lostMessages) fec=\(link.fecRecovered) nacks=\(link.nacks) loss=\(link.loss) rtt=\(String(describing: link.rttMs))")
        XCTAssertGreaterThanOrEqual(got, 30, "frames kept coming under loss")
        XCTAssertTrue(link.loss == 0 || (0.02...0.25).contains(link.loss), "measured loss \(link.loss)")
        XCTAssertGreaterThan(link.fecRecovered, 0, "FEC rebuilt some frames")
        XCTAssertLessThanOrEqual(link.lostMessages * 10, Int64(got), "few frames lost")

        // UDP blocked: after ~3 s the host sends video down the SSH channel instead.
        link.dropRate = 1.0
        s.send(DesktopProtocol.config(["debug_loss": 0.0]))
        let sshBefore = s.sshVideo
        let blockedAt = Date()
        waitFor(8, "fallback to SSH") {
            if Date().timeIntervalSince(blockedAt) > 3.5 { s.send(DesktopProtocol.text("x")) }
            return s.sshVideo > sshBefore
        }
        print("fallback after \(Int(Date().timeIntervalSince(blockedAt) * 1000)) ms")
        XCTAssertFalse(link.alive, "3 s of silence: the phone side is not alive either")
        // Unblocked: back on UDP.
        link.dropRate = 0
        let udpBefore = frames.count
        waitFor(4, "back on UDP") { s.send(DesktopProtocol.text("y")); Thread.sleep(forTimeInterval: 0.15); return frames.count > udpBefore }

        // A network change: new socket, the host follows within a second.
        Thread.sleep(forTimeInterval: 0.5)
        let roamFrom = frames.count
        let t0 = Date()
        link.rebind()
        link.send(DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME), reliable: true)
        waitFor(3, "video after rebind") { frames.count > roamFrom }
        let roamMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("roam recovered in \(roamMs) ms")
        XCTAssertLessThanOrEqual(roamMs, 1000)

        // SSH closes: the desktop keeps going on UDP.
        s.stream.close()
        Thread.sleep(forTimeInterval: 0.5)
        let afterClose = frames.count
        link.send(DesktopProtocol.text("z"), reliable: true)
        waitFor(3, "video after the SSH channel closed") { frames.count > afterClose }
        XCTAssertFalse(s.stream.isClosed, "serve keeps running on UDP")
    }

    /// Prefer real xterm (Android CI); fall back to xfce4-terminal / x-terminal-emulator on this Linux box.
    private func typingTarget(_ f: Fixture) throws -> Process? {
        let candidates: [(String, [String])] = [
            ("/usr/bin/xterm", ["-geometry", "100x30+0+0", "-e", "cat"]),
            ("/usr/bin/xfce4-terminal", ["--disable-server", "--geometry=100x30+0+0", "-x", "cat"]),
            ("/usr/bin/x-terminal-emulator", ["--disable-server", "--geometry=100x30+0+0", "-x", "cat"])
        ]
        guard let (path, args) = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.0) }) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment; env["DISPLAY"] = f.display; proc.environment = env
        try proc.run()
        Thread.sleep(forTimeInterval: 0.7)
        return proc
    }

    private func busyTypingTarget(_ f: Fixture) throws -> Process? {
        let script = "while :; do head -c 4000 /dev/urandom | base64; done"
        let candidates: [(String, [String])] = [
            ("/usr/bin/xterm", ["-geometry", "160x50+0+0", "-e", "sh", "-c", script]),
            ("/usr/bin/xfce4-terminal", ["--disable-server", "--geometry=160x50+0+0", "-x", "sh", "-c", script]),
            ("/usr/bin/x-terminal-emulator", ["--disable-server", "--geometry=160x50+0+0", "-x", "sh", "-c", script])
        ]
        guard let (path, args) = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.0) }) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment; env["DISPLAY"] = f.display; proc.environment = env
        try proc.run()
        Thread.sleep(forTimeInterval: 0.5)
        return proc
    }

    private func pointer(_ display: String) -> (Int, Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["xdotool", "getmouselocation"]
        var env = ProcessInfo.processInfo.environment; env["DISPLAY"] = display; p.environment = env
        let out = Pipe(); p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let x = Int(parts[0].dropFirst(2)), let y = Int(parts[1].dropFirst(2)) else { return nil }
        return (x, y)
    }

    /// Pointer moves are plain datagrams (the newest wins): they still reach the desktop.
    func testPointerMovesOverUdp() throws {
        let f = try Self.fixture()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xdotool") else { throw XCTSkip("no xdotool") }
        let s = try Serve(f)
        defer { s.stop() }
        let frames = Counter()
        let link = try link(s, frames: frames)
        defer { link.close() }
        waitFor(5, "first video over UDP") { frames.count > 0 }
        let abs = DesktopProtocol.abs(display: 0, x: 100, y: 100)
        link.send(abs, reliable: UdpLink.reliable(abs))
        waitFor(2, "absolute move") { pointer(f.display).map { $0 == (100, 100) } ?? false }
        let rel = DesktopProtocol.rel(dx: 10, dy: 5)
        for _ in 0..<10 { link.send(rel, reliable: UdpLink.reliable(rel)); Thread.sleep(forTimeInterval: 0.016) }
        waitFor(2, "relative moves (at \(String(describing: pointer(f.display))))") { pointer(f.display).map { $0 == (200, 150) } ?? false }
    }

    /// No loss on the way: the phone asks for nothing again, whatever the pacing and the frame sizes.
    func testNoNacksWithoutLoss() throws {
        let f = try Self.fixture()
        // A busy screen: big frames, split into many shards and paced out.
        guard let xterm = try busyTypingTarget(f) else { throw XCTSkip("no terminal emulator") }
        defer { xterm.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        let s = try Serve(f)
        defer { s.stop() }
        let frames = Counter()
        let link = try link(s, frames: frames)
        defer { link.close() }
        waitFor(5, "first video over UDP") { frames.count > 0 }
        let (f0, n0) = (frames.count, link.nacks)
        Thread.sleep(forTimeInterval: 6)
        let got = frames.count - f0
        let nacks = link.nacks - n0
        print("no-loss run: frames=\(got) nacks=\(nacks) fec=\(link.fecRecovered) lost=\(link.lostMessages) loss=\(link.loss)")
        XCTAssertGreaterThanOrEqual(got, 30, "frames came")
        XCTAssertLessThanOrEqual(nacks * 50, Int64(got), "NACKs without loss")
    }
}

/// The whole `DesktopSession` against the real plugin: probe, serve, UDP upgrade, the 3 s fallback to
/// SSH and back, and a resume with the session token. Same fixture as above; the "host" is a local shell.
final class DesktopSessionPluginTests: XCTestCase {
    func testRealPluginEndToEnd() throws {
        let f = try UdpPluginIntegrationTests.fixture()
        let host = LocalShellHost(home: URL(fileURLWithPath: f.home), environment: ["DISPLAY": f.display, "ROAMTTY_DESKTOP_TEST": "1"])
        let decoder = InstantDecoder()
        let hellos = Box<[Hello]>([])
        let lock = NSLock()
        var config = DesktopSession.Config(hostName: "local", address: "127.0.0.1", clientWidth: 720, clientHeight: 1280, clientDpi: 160)
        config.fps = 30
        let s = DesktopSession(config: config, manifest: try PluginManifest.bundled(), login: { .host(host) },
                               fetch: { _ in throw URLError(.notConnectedToInternet) })
        decoder.session = s
        s.video = decoder
        s.onHello = { h in lock.lock(); hellos.value.append(h); lock.unlock() }
        defer { s.close() }
        s.start()
        XCTAssertTrue(waitUntil(15) { if case .connected = s.phase { return true }; return false }, "phase \(s.phase), log \(s.log)")
        XCTAssertTrue(waitUntil(5) { s.onUdp }, "UDP upgrade")
        XCTAssertTrue(waitUntil(3) { s.stats.link == "UDP" })
        XCTAssertFalse(host.commands.first?.contains("--resume") ?? true)

        // Block UDP on the phone side: 3 s later the session is back on SSH and frames keep coming.
        s.testUdpDrop(1.0)
        let blockedAt = Date()
        XCTAssertTrue(waitUntil(6) { !s.onUdp })
        let fallback = Date().timeIntervalSince(blockedAt)
        print("session fallback after \(Int(fallback * 1000)) ms")
        XCTAssertGreaterThan(fallback, 2.5)
        let framesAtFallback = decoder.all.count
        // Typing changes the screen; the plugin's own fallback sends the video over SSH.
        for i in 0..<20 { s.input(DesktopProtocol.text("ssh\(i) ")); Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(waitUntil(8) { decoder.all.count > framesAtFallback }, "video over SSH after the fallback")
        XCTAssertTrue(waitUntil(3) { s.stats.link == "SSH" })
        // Unblocked: UDP again.
        s.testUdpDrop(0)
        XCTAssertTrue(waitUntil(5) { s.onUdp }, "back on UDP")

        // The SSH link drops while UDP is blocked: the session resumes with its token.
        s.testUdpDrop(1.0)
        XCTAssertTrue(waitUntil(6) { !s.onUdp })
        s.networkChanged()
        XCTAssertTrue(waitUntil(15) { host.commands.count >= 2 && { if case .connected = s.phase { return true }; return false }() },
                      "resumed: \(s.phase) \(host.commands)")
        let resume = try XCTUnwrap(host.commands.last)
        let first = try XCTUnwrap(hellos.value.first)
        XCTAssertTrue(resume.contains("--resume \(first.session) --token "), resume)
        lock.lock(); let sessions = hellos.value.map(\.session); lock.unlock()
        print("sessions: \(sessions)")
        XCTAssertEqual(sessions.last, first.session, "the plugin kept the desktop session")
    }
}
