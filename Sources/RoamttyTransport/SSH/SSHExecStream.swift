import Foundation
import CNative
import RoamttyCore
import RoamttyDesktopCore

/// One exec channel kept open for a long-running command whose stdin and stdout carry a binary protocol:
/// the remote desktop's `roamtty-desktop serve` (Android `RemoteStream`, roamtty #218). A pump thread
/// moves bytes under the connection's library lock; `read` blocks the caller until bytes come or the
/// command's output ends. Closing drops the channel only, as Android does: the plugin sees its stdin end
/// and keeps the desktop for a resume.
public final class SSHExecStream: DesktopStream, @unchecked Sendable {
    private let connection: SSHConnection
    private let channel: OpaquePointer
    private let cond = NSCondition()
    /// Bytes before `incomingStart` / `outgoingStart` are already taken; they are dropped in bulk, not per read.
    private var incoming: [UInt8] = []
    private var incomingStart = 0
    private var outgoing: [UInt8] = []
    private var outgoingStart = 0
    private var errors: [UInt8] = []
    private var finished = false
    private var closeRequested = false
    /// `finishWriting` asked for an end of input, which goes once everything written before it has.
    private var eofRequested = false
    private var eofSent = false
    /// The far end's output ended. A forwarded connection's reader stops there, without waiting for the channel's close.
    private var outputEnded = false
    private let endsAtEOF: Bool
    private var status: Int?
    private let wake = WorkerWake()
    private static let maxErrors = 16 * 1024
    private static let maxIncoming = 4 * 1024 * 1024
    /// libssh2 writes at most 32700 bytes a call, so a larger slice would only be copied.
    private static let writeChunk = 32768

    init(connection: SSHConnection, channel: OpaquePointer, endsAtEOF: Bool = false) {
        self.connection = connection; self.channel = channel; self.endsAtEOF = endsAtEOF
        let t = Thread { [self] in pump() }
        t.name = "roamtty.ssh.stream"
        t.start()
    }

    public func read(maxBytes: Int) -> [UInt8] {
        cond.lock(); defer { cond.unlock() }
        while incomingCount == 0 && !finished && !closeRequested && !(endsAtEOF && outputEnded) { cond.wait() }
        if incomingCount == 0 { return [] }
        let n = min(maxBytes, incomingCount)
        let out = Array(incoming[incomingStart..<(incomingStart + n)])
        incomingStart += n
        Self.compact(&incoming, start: &incomingStart)
        cond.broadcast()
        return out
    }

    public func write(_ bytes: [UInt8]) throws {
        cond.lock()
        guard !finished && !closeRequested else { cond.unlock(); throw RoamError.transport("Stream closed") }
        Self.compact(&outgoing, start: &outgoingStart)
        outgoing.append(contentsOf: bytes)
        cond.unlock()
        wake?.signal()
    }

    public var errorOutput: String { cond.lock(); defer { cond.unlock() }; return String(decoding: errors, as: UTF8.self) }
    public var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return finished }
    public var exitStatus: Int? { cond.lock(); defer { cond.unlock() }; return status }

    /// Sends an end of input once everything written so far has gone; the far end's output still comes.
    public func finishWriting() {
        cond.lock(); eofRequested = true; cond.unlock()
        wake?.signal()
    }

    public func close() {
        cond.lock(); closeRequested = true; cond.broadcast(); cond.unlock()
        wake?.signal()
    }

    /// Unread bytes; called under `cond`.
    private var incomingCount: Int { incoming.count - incomingStart }

    /// Drops the taken prefix once it is everything or at least half of the buffer, so each byte moves at most once.
    private static func compact(_ buffer: inout [UInt8], start: inout Int) {
        if start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 } else if start >= 64 * 1024 && start >= buffer.count / 2 { buffer.removeFirst(start); start = 0 }
    }

    private func pump() {
        connection.asWaitingLoop(wake) { pumpLoop() }
    }

    private func pumpLoop() {
        var buffer = [UInt8](repeating: 0, count: 32768)
        var lastAlive = Date()
        var exit: Int?
        defer {
            connection.closeChannel(channel)
            cond.lock(); finished = true; status = exit; cond.broadcast(); cond.unlock()
        }
        do {
            while !connection.isStopped {
                cond.lock()
                // Hold back while the reader is far behind (libssh2's window then throttles the host).
                // `read` and `close` signal; the timeout only bounds noticing a dropped connection.
                while incomingCount >= Self.maxIncoming && !closeRequested && !connection.isStopped {
                    _ = cond.wait(until: Date().addingTimeInterval(0.25))
                }
                let stop = closeRequested || connection.isStopped
                // A chunk that starts where the last write stopped: an EAGAIN retry hands libssh2 the same bytes.
                let pending = Array(outgoing[outgoingStart..<min(outgoing.count, outgoingStart + Self.writeChunk)])
                let sendEOF = pending.isEmpty && eofRequested && !eofSent
                cond.unlock()
                if stop { return }
                var progressed = false
                if !pending.isEmpty {
                    let sent = pending.withUnsafeBytes { raw in
                        connection.writeChannel(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, pending.count)
                    }
                    if sent > 0 {
                        cond.lock(); outgoingStart += sent; Self.compact(&outgoing, start: &outgoingStart); cond.unlock()
                        progressed = true
                    } else if sent < 0 && sent != LIBSSH2_ERROR_EAGAIN { throw connection.error(Int32(sent)) }
                } else if sendEOF {
                    let result = connection.locked { libssh2_channel_send_eof(channel) }
                    if result == 0 { cond.lock(); eofSent = true; cond.unlock(); progressed = true } else if result != LIBSSH2_ERROR_EAGAIN { throw connection.error(result) }
                }
                for stream in 0...1 {
                    while true {
                        cond.lock()
                        let stop = closeRequested || connection.isStopped
                        let available = stream == 0 ? Self.maxIncoming - incomingCount : buffer.count
                        cond.unlock()
                        if stop { return }
                        let want = min(buffer.count, available)
                        if want == 0 { break }
                        let count = buffer.withUnsafeMutableBytes { raw in
                            connection.readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, want)
                        }
                        if count > 0 {
                            cond.lock()
                            if stream == 0 {
                                Self.compact(&incoming, start: &incomingStart)
                                incoming.append(contentsOf: buffer[0..<count])
                            } else {
                                errors.append(contentsOf: buffer[0..<count])
                                if errors.count > Self.maxErrors { errors.removeFirst(errors.count - Self.maxErrors) }
                            }
                            cond.broadcast(); cond.unlock()
                            progressed = true
                            if stream == 0 && count == buffer.count { continue }
                        } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw connection.error(Int32(count)) }
                        break
                    }
                }
                if connection.locked({ libssh2_channel_eof(channel) }) != 0 {
                    cond.lock(); outputEnded = true; cond.broadcast(); cond.unlock()
                    // The exit status comes with the channel's close; bounded, like exec.
                    _ = try? connection.retry(timeout: 5, cancelled: { self.closeWanted }) { libssh2_channel_wait_closed(channel) }
                    exit = Int(connection.locked { libssh2_channel_get_exit_status(channel) })
                    return
                }
                if Date().timeIntervalSince(lastAlive) > 15 {
                    var seconds: Int32 = 0
                    try connection.retry(timeout: 60) { libssh2_keepalive_send(connection.session, &seconds) }
                    lastAlive = Date()
                }
                if !progressed { try connection.networkWait(wake: wake) }
            }
        } catch {
            return
        }
    }

    private var closeWanted: Bool { cond.lock(); defer { cond.unlock() }; return closeRequested }
}

extension SSHConnection {
    /// Starts `command` on a new exec channel and keeps it open (see `SSHExecStream`).
    public func openStream(_ command: String) throws -> SSHExecStream {
        guard command.utf8.count <= 256 * 1024 else { throw RoamError.invalid("SSH command exceeds its limit") }
        let channel = try command.withCString { bytes in
            try openChannel { channel in
                try retry { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
            }
        }
        return SSHExecStream(connection: self, channel: channel)
    }
}

/// The remote desktop's view of an SSH login (`DesktopHost`), on the existing exec and SFTP code.
public final class SSHDesktopHost: DesktopHost, @unchecked Sendable {
    public let connection: SSHConnection

    public init(connection: SSHConnection) { self.connection = connection }

    public func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        execute(RemoteCommands.stdinShell, input: Data(script.utf8), timeout: timeout, onLine: onLine)
    }

    public func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        execute(command, input: Data(), timeout: timeout, onLine: onLine)
    }

    private func execute(_ command: String, input: Data, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        var pending = Data()
        func flush(all: Bool) {
            // Lines are cut by index and the consumed prefix dropped once per chunk, not copied per line.
            var start = pending.startIndex
            while let nl = pending[start...].firstIndex(of: 0x0A) {
                var line = pending[start..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                onLine(String(decoding: line, as: UTF8.self))
                start = nl + 1
            }
            if all && start < pending.endIndex { onLine(String(decoding: pending[start...], as: UTF8.self)); start = pending.endIndex }
            if start == pending.endIndex { pending.removeAll() } else if start > pending.startIndex { pending = Data(pending[start...]) }
        }
        do {
            let result = try connection.exec(command, input: input, timeout: timeout) { chunk in pending.append(chunk); flush(all: false) }
            flush(all: true)
            return Int(result.status)
        } catch {
            flush(all: true)
            return nil
        }
    }

    public func upload(_ data: Data, to path: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-desktop-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try connection.upload(file, to: path, progress: { _, _ in })
    }

    public func openStream(_ command: String) -> DesktopStream? { try? connection.openStream(command) }

    public func disconnect() { connection.disconnect() }
}
