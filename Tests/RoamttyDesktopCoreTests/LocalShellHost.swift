import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import RoamttyDesktopCore

/// A `DesktopHost` that is this machine: scripts go to a local `/bin/sh -s` with HOME set to `home`,
/// uploads land under `home`, streams are local processes. Android's tests use the same trick.
final class LocalShellHost: DesktopHost, @unchecked Sendable {
    /// A write to a process that already exited must fail, not end the test run.
    static let ignoreSigpipe: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    let home: URL
    var environment: [String: String]
    private(set) var disconnected = false
    private(set) var commands: [String] = []

    init(home: URL, environment: [String: String] = [:]) {
        _ = Self.ignoreSigpipe
        self.home = home
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env.removeValue(forKey: "SSH_CLIENT")
        for (k, v) in environment { env[k] = v }
        self.environment = env
    }

    private func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = home
        return p
    }

    func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        let p = process(["-s"])
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = output
        do { try p.run() } catch { return nil }
        try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).forEach {
            if !$0.isEmpty { onLine(String($0)) }
        }
        return Int(p.terminationStatus)
    }

    /// No Windows here: a POSIX host's `runCommand` would run PowerShell, which is missing.
    var runCommandHandler: ((String) -> (Int?, [String]))?
    func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        guard let handler = runCommandHandler else { return nil }
        let (status, lines) = handler(command)
        lines.forEach(onLine)
        return status
    }

    func upload(_ data: Data, to path: String) throws {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
        precondition(!FileManager.default.fileExists(atPath: url.path))
        try data.write(to: url)
    }

    func openStream(_ command: String) -> DesktopStream? {
        commands.append(command)
        let p = process(["-c", command])
        return try? ProcessStream(p)
    }

    func disconnect() { disconnected = true }
}

/// A local process as a `DesktopStream`; closing ends its stdin, as a closed SSH channel does.
final class ProcessStream: DesktopStream, @unchecked Sendable {
    private let process: Process
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var errors: [UInt8] = []
    private var eof = false, closed = false

    init(_ p: Process) throws {
        process = p
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        Thread.detachNewThread { [self] in
            while true {
                let d = stdout.fileHandleForReading.availableData
                cond.lock()
                if d.isEmpty { eof = true; cond.broadcast(); cond.unlock(); break }
                buffer.append(contentsOf: d); cond.broadcast(); cond.unlock()
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                let d = stderr.fileHandleForReading.availableData
                if d.isEmpty { break }
                cond.lock(); errors.append(contentsOf: d); cond.unlock()
            }
        }
    }

    func read(maxBytes: Int) -> [UInt8] {
        cond.lock(); defer { cond.unlock() }
        while buffer.isEmpty && !eof && !closed { cond.wait() }
        if buffer.isEmpty { return [] }
        let n = min(maxBytes, buffer.count)
        let out = Array(buffer[0..<n]); buffer.removeFirst(n)
        return out
    }

    func write(_ bytes: [UInt8]) throws {
        cond.lock(); let c = closed; cond.unlock()
        if c { throw CocoaError(.fileWriteUnknown) }
        try stdin.fileHandleForWriting.write(contentsOf: Data(bytes))
    }

    var errorOutput: String { cond.lock(); defer { cond.unlock() }; return String(decoding: errors, as: UTF8.self) }
    var isClosed: Bool { cond.lock(); let e = eof; cond.unlock(); return e && !process.isRunning }
    var exitStatus: Int? { process.isRunning ? nil : Int(process.terminationStatus) }

    func close() {
        cond.lock()
        let was = closed
        closed = true; cond.broadcast(); cond.unlock()
        if !was { try? stdin.fileHandleForWriting.close() }
    }

    /// Test cleanup: the process itself.
    func kill() { if process.isRunning { process.terminate() } }
    deinit { kill() }
}
