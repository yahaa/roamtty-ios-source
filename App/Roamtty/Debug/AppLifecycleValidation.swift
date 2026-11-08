#if DEBUG
import Foundation
import UIKit
import MachO
import SwiftTerm
import RoamttyCore
import RoamttyTransport

/// Opt-in Debug probe for the whole app on a disposable SSH fixture: it opens and closes real shell and tmux
/// sessions, the file browser and the host page through `AppModel`, with the screens on display, then checks that
/// every runtime, terminal view, terminal model and SSH connection went, and how far the footprint and frame times
/// moved. Run via `scripts/run-memory-validation.py --app`; the report is Documents/AppLifecycleValidation/report.json.
@MainActor enum AppLifecycleValidation {
    private static var started = false
    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
    /// Frame gaps on the main thread while it watches: a hitch is a frame later than twice the display's interval.
    /// It counts callbacks the busy main thread missed, while the render server may still have shown those frames,
    /// so it reads higher than Instruments' Animation Hitches, which is the measure to trust.
    private final class FrameWatch: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private(set) var frames = 0, hitches = 0, longest: CFTimeInterval = 0, hitchTime: CFTimeInterval = 0
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common); self.link = link
        }
        @objc private func tick(_ link: CADisplayLink) {
            defer { last = link.timestamp }
            guard last > 0 else { return }
            let gap = link.timestamp - last, interval = max(link.duration, 1.0 / 120)
            frames += 1; longest = max(longest, gap)
            if gap > interval * 2 { hitches += 1; hitchTime += gap - interval }
        }
        func stop() -> [String: Any] {
            link?.invalidate(); link = nil
            return ["frames": frames, "hitches": hitches, "longestFrameMilliseconds": longest * 1000,
                    "hitchMilliseconds": hitchTime * 1000]
        }
    }

    static func runIfRequested(model: AppModel) async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--app-lifecycle-validation") else { return }
        started = true
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppLifecycleValidation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks: [[String: Any]] = []
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var status = "running"
        func save() {
            let report: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "kind": "opt-in Debug app lifecycle regression", "startedAt": startedAt, "status": status,
                "passed": status == "finished" && checks.allSatisfy { $0["passed"] as? Bool ?? true },
                "device": UIDevice.current.model, "system": UIDevice.current.systemVersion, "checks": checks,
                // So addresses in an attached Instruments trace (which misses the launch's image loads) symbolicate.
                "mainImageSlide": String(format: "0x%lx", _dyld_get_image_vmaddr_slide(0))]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        save()
        do {
            let host = try await installFixture(model)
            try? await Task.sleep(for: .seconds(3))
            checks.append(["name": "baseline", "footprintMiB": footprint(), "terminalCensus": TerminalCensus.live]); save()
            // ROAMTTY_LIFECYCLE_ONLY (shell, tmux, host, idle, terminal; comma separated) runs only those, to keep a trace small.
            let only = ProcessInfo.processInfo.environment["ROAMTTY_LIFECYCLE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
            func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
            for mode in [SessionMode.shell, .tmux] where wanted(mode.rawValue) {
                checks.append(try await sessionCycles(model, host: host, mode: mode, cycles: 6)); save()
            }
            if wanted("host") { checks.append(try await hostPageCycles(model, host: host, cycles: 8)); save() }
            if wanted("idle") { checks.append(try await idleWithSessions(model, host: host)); save() }
            if wanted("terminal") { checks.append(try await idleTerminal(model, host: host)); save() }
            model.path = []
            try? await Task.sleep(for: .seconds(3))
            checks.append(["name": "after_all", "footprintMiB": footprint(), "terminalCensus": TerminalCensus.live,
                           "runtimes": model.runtimes.count, "records": model.records.count,
                           "sshBlocksReclaimed": SSHConnection.reclaimedNativeBlocks]); save()
            status = "finished"
        } catch {
            checks.append(["name": "error", "passed": false, "error": String(describing: error)])
            status = "failed"
        }
        checks.append(["name": "finished", "finishedAt": ISO8601DateFormatter().string(from: Date())])
        save()
    }

    private static func footprint() -> UInt64 { Diagnostics.footprintMiB() ?? 0 }

    /// The fixture becomes a saved host with its password, and its key is pinned once it matches the fingerprint
    /// given, so no screen asks to trust it.
    private static func installFixture(_ model: AppModel) async throws -> Host {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["ROAMTTY_TEST_HOST"], let user = env["ROAMTTY_TEST_USERNAME"],
              let password = env["ROAMTTY_TEST_PASSWORD"], let fingerprint = env["ROAMTTY_TEST_FINGERPRINT"],
              env["ROAMTTY_STORAGE_NAME"] == "AppLifecycleValidation", let store = model.store else {
            throw RoamError.invalid("Validation needs an explicit disposable fixture and its own storage")
        }
        let host = Host(id: "lifecycle-fixture", name: "Lifecycle fixture", address: address,
                        port: Int(env["ROAMTTY_TEST_PORT"] ?? "22") ?? 22, username: user, auth: .password, mode: .tmux, savePassword: true)
        try store.saveHost(host)
        try model.vault.save(data: Data(password.utf8), hostID: host.id, purpose: .password)
        model.hosts = try store.hosts()
        // Older runs' cards go, so every cycle starts from the same list.
        for record in model.records { model.forceDeleteSession(record) }
        let ssh = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: store) { prompt in
            if case .verifyHost(let received) = prompt { return fingerprint.split(separator: ",").contains { $0 == received.fingerprint } ? ["verified"] : nil }
            return nil
        }
        try await performInBackground { try ssh.connect(); ssh.disconnect() }
        return host
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
    private static func tail(_ runtime: SessionRuntime) -> String {
        String(decoding: runtime.terminalView.getTerminal().getBufferTailAsData(maxBytes: 8192), as: UTF8.self)
    }

    /// Opens a session on screen, floods it with output, visits its file browser, closes it, and checks it all went.
    private static func sessionCycles(_ model: AppModel, host: Host, mode: SessionMode, cycles: Int) async throws -> [String: Any] {
        var runtimes: [Weak<SessionRuntime>] = [], views: [Weak<TerminalView>] = [], terminals: [Weak<Terminal>] = []
        var connections: [Weak<SSHConnection>] = []
        var footprints: [UInt64] = [], floods: [[String: Any]] = [], connectSeconds: [Double] = []
        for cycle in 0..<cycles {
            do {
                let before = Set(model.records.map(\.id))
                let start = ProcessInfo.processInfo.systemUptime
                model.launch(host, mode: mode, directory: "~", agent: nil, mosh: false)
                guard let record = model.records.first(where: { !before.contains($0.id) }), let runtime = model.runtimes[record.id] else {
                    throw RoamError.invalid("launch made no session")
                }
                guard await wait(25, until: { runtime.phase == .connected }) else {
                    throw RoamError.invalid("\(mode) session \(cycle) did not connect: \(runtime.phase) \(runtime.message ?? "")")
                }
                connectSeconds.append(ProcessInfo.processInfo.systemUptime - start)
                runtimes.append(Weak(runtime)); views.append(Weak(runtime.terminalView)); terminals.append(Weak(runtime.terminalView.getTerminal()))
                if let ssh = runtime.ssh { connections.append(Weak(ssh)) }
                try? await Task.sleep(for: .milliseconds(500))
                // About 2.5 MB of output, as a build log or `cat` of a big file would print.
                let marker = "LIFECYCLE\(cycle)"
                let watch = FrameWatch(); watch.start()
                let floodStart = ProcessInfo.processInfo.systemUptime
                runtime.send("seq 1 300000; echo \(marker)_DO''NE\r")
                let finished = await wait(60, until: { tail(runtime).contains(marker + "_DONE") })
                var flood = watch.stop()
                flood["seconds"] = ProcessInfo.processInfo.systemUptime - floodStart; flood["finished"] = finished
                flood["footprintMiB"] = footprint()
                floods.append(flood)
                // The file browser on this session's folder, then back to the terminal.
                model.path.append(.files(host.id, sessionID: record.id))
                try? await Task.sleep(for: .milliseconds(2500))
                model.path.removeLast()
                try? await Task.sleep(for: .seconds(1))
                model.closeSession(record)
                _ = await wait(15, until: { !model.records.contains(where: { $0.id == record.id }) })
            }
            try? await Task.sleep(for: .milliseconds(1500))
            footprints.append(footprint())
        }
        // Shared host connections (files, metrics) are the model's to keep; only the sessions' own must go.
        _ = await wait(5, until: { runtimes.allSatisfy { $0.value == nil } && connections.allSatisfy { $0.value == nil } })
        let retained = ["runtimesRetained": runtimes.filter { $0.value != nil }.count,
                        "viewsRetained": views.filter { $0.value != nil }.count,
                        "terminalModelsRetained": terminals.filter { $0.value != nil }.count,
                        "sessionConnectionsRetained": connections.filter { $0.value != nil }.count]
        let growth = Int(footprints.last ?? 0) - Int(footprints.dropFirst().first ?? footprints.first ?? 0)
        return ["name": "\(mode)_session_cycles", "cycles": cycles, "connectSeconds": connectSeconds,
                "footprintsMiB": footprints, "growthAfterFirstCycleMiB": growth, "floods": floods,
                "terminalCensus": TerminalCensus.live, "openRuntimes": model.runtimes.count,
                "passed": retained.values.allSatisfy { $0 == 0 } && floods.allSatisfy { $0["finished"] as? Bool == true } && growth < 8]
            .merging(retained) { first, _ in first }
    }

    /// The host page polls metrics while shown; leaving it must stop the poll.
    private static func hostPageCycles(_ model: AppModel, host: Host, cycles: Int) async throws -> [String: Any] {
        var footprints: [UInt64] = []
        let watch = FrameWatch(); watch.start()
        for _ in 0..<cycles {
            model.path = [.host(host.id)]
            try? await Task.sleep(for: .seconds(4))
            model.path = [.host(host.id), .files(host.id)]
            try? await Task.sleep(for: .seconds(2))
            model.path = []
            try? await Task.sleep(for: .milliseconds(1500))
            footprints.append(footprint())
        }
        let frames = watch.stop()
        let stopped = await wait(5, until: { model.monitorJobs.isEmpty })
        let growth = Int(footprints.last ?? 0) - Int(footprints.dropFirst().first ?? 0)
        return ["name": "host_page_and_files_cycles", "cycles": cycles, "footprintsMiB": footprints, "frames": frames,
                "monitorStoppedAfterLeaving": stopped, "growthAfterFirstCycleMiB": growth,
                "sharedConnections": model.connections.count, "passed": stopped && growth < 8]
    }

    /// Four tmux sessions left open on the home list for 30 seconds: what the idle app costs and whether it grows.
    private static func idleWithSessions(_ model: AppModel, host: Host) async throws -> [String: Any] {
        var opened: [SessionRecord] = []
        for _ in 0..<4 {
            let before = Set(model.records.map(\.id))
            model.launch(host, mode: .tmux, directory: "~", agent: nil, mosh: false)
            guard let record = model.records.first(where: { !before.contains($0.id) }), let runtime = model.runtimes[record.id],
                  await wait(25, until: { runtime.phase == .connected }) else { throw RoamError.invalid("idle session did not connect") }
            opened.append(record)
            model.leaveTerminal()
        }
        try? await Task.sleep(for: .seconds(3))
        // No frame watch here: its own display link would cost CPU of its own.
        let start = footprint(), cpuStart = cpuSeconds()
        try? await Task.sleep(for: .seconds(30))
        let cpu = cpuSeconds() - cpuStart, end = footprint()
        for record in opened { model.closeSession(record) }
        _ = await wait(20, until: { opened.allSatisfy { record in !model.records.contains(where: { $0.id == record.id }) } })
        return ["name": "idle_home_with_four_tmux_sessions", "seconds": 30, "cpuSeconds": cpu, "cpuPercent": cpu / 30 * 100,
                "footprintStartMiB": start, "footprintEndMiB": end,
                "passed": cpu / 30 < 0.05 && Int(end) - Int(start) < 4]
    }

    /// A connected terminal on screen with nothing printing: what its own animations cost.
    private static func idleTerminal(_ model: AppModel, host: Host) async throws -> [String: Any] {
        let before = Set(model.records.map(\.id))
        model.launch(host, mode: .tmux, directory: "~", agent: nil, mosh: false)
        guard let record = model.records.first(where: { !before.contains($0.id) }), let runtime = model.runtimes[record.id],
              await wait(25, until: { runtime.phase == .connected }) else { throw RoamError.invalid("idle terminal did not connect") }
        try? await Task.sleep(for: .seconds(5))
        let cpuStart = cpuSeconds()
        try? await Task.sleep(for: .seconds(20))
        let cpu = cpuSeconds() - cpuStart
        model.closeSession(record)
        _ = await wait(15, until: { !model.records.contains(where: { $0.id == record.id }) })
        return ["name": "idle_terminal_on_screen", "seconds": 20, "cpuSeconds": cpu, "cpuPercent": cpu / 20 * 100,
                "footprintMiB": footprint()]
    }

    /// The process's user and system CPU time so far.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
#endif
