import Foundation
import CNative
import RoamttyCore

public struct CommandResult {
    public let output: Data
    public let status: Int32
    public init(output: Data, status: Int32) { self.output = output; self.status = status }
    /// The output as UTF-8, with anything else replaced: commands print text, and a stray byte must not lose it.
    public var text: String { String(decoding: output, as: UTF8.self) }
    /// `text` without the whitespace and line breaks around it.
    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// libssh2 handles are always touched under `libraryLock`. Waiting for network readiness never holds it,
/// so terminal, exec and short-lived SFTP channels can share an authenticated connection.
public final class SSHConnection: @unchecked Sendable {
    let host: RoamttyCore.Host
    private var credentials: Credentials
    private let pins: PinStore
    let prompt: (AuthPrompt) -> [String]?
    public var onPhase: ((ConnectionPhase) -> Void)?
    let libraryLock = NSRecursiveLock()
    private let stateLock = NSLock()
    // libssh2 keeps channel-open and SFTP-init retry state on the session.
    // Hold this gate across EAGAIN, without preventing existing-channel I/O.
    private let creationCondition = NSCondition()
    private var creatingChannel = false
    var session: OpaquePointer?
    /// The allocator of a session this connection made; see `roam_ssh_heap_destroy`.
    private var heap: OpaquePointer?
    /// Blocks libssh2 left behind in sessions since launch, released when each session went.
    public static var reclaimedNativeBlocks: Int { reclaimedLock.lock(); defer { reclaimedLock.unlock() }; return reclaimed }
    private static let reclaimedLock = NSLock()
    private static var reclaimed = 0
    // Raw read/write/resize calls interleave on a worker. EAGAIN does not imply
    // that the most recent call owns libssh2's one retained transport packet.
    private struct PendingChannelIO {
        var read: (stream: Int32, count: Int)?
        var write: (stream: Int32, bytes: Data)?
        var resize: (columns: Int32, rows: Int32, width: Int32, height: Int32)?
        var isEmpty: Bool { read == nil && write == nil && resize == nil }
    }
    private var pendingChannelIO: [OpaquePointer: PendingChannelIO] = [:]
    private var socket: Int32 = -1
    private var terminal: OpaquePointer?
    private var stopped = false
    private var authenticated = false
    private var acceptingInput = false
    private var input = InputQueue()
    /// Ends the terminal loop's network wait as soon as input is queued.
    private let wake = WorkerWake()
    private var pendingSize: (Int, Int)?
    private var transferGeneration = 0
    /// Loops parked on the socket between bursts (the terminal, exec streams), by their wake, and the other
    /// libssh2 work in flight. Another thread's libssh2 call can read a loop's packets off the socket into
    /// libssh2's buffer, where no poll sees them, so a loop waits long only while it is the connection's sole user.
    private var waitingLoops: [ObjectIdentifier: WorkerWake] = [:]
    private var otherWork = 0
    /// A loop's network wait while nothing else uses the connection: input, a resize, a close or other work wake it.
    static let idleWaitMs: Int32 = 1000
    /// A loop's network wait while other work may take its packets off the socket.
    static let sharedWaitMs: Int32 = 30
    private static let initialized: Void = { _ = libssh2_init(0) }()

    public init(host: RoamttyCore.Host, credentials: Credentials, pinStore: PinStore, prompt: @escaping (AuthPrompt) -> [String]?) {
        self.host = host; self.credentials = credentials; self.pins = pinStore; self.prompt = prompt
    }
    deinit {
        disconnect()
        libraryLock.lock()
        if let session { _ = libssh2_session_free(session) }
        if let heap {
            let count = roam_ssh_heap_destroy(heap, nil)
            Self.reclaimedLock.lock(); Self.reclaimed += count; Self.reclaimedLock.unlock()
        }
        libraryLock.unlock()
        roam_socket_close(socket)
        credentials.clear()
    }
    var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }
    public var isConnected: Bool { stateLock.lock(); defer { stateLock.unlock() }; return authenticated && !stopped }
    /// The numeric address this connection actually reached, which a name with several addresses does not pin down.
    var peerAddress: String? {
        stateLock.lock(); let fd = socket; stateLock.unlock()
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard roam_socket_peer(fd, &buffer, Int32(buffer.count)) == 0 else { return nil }
        return String(cString: buffer)
    }
    func locked<T>(_ action: () throws -> T) rethrows -> T { libraryLock.lock(); defer { libraryLock.unlock() }; return try action() }
    /// `wake` lets queued input end the wait early.
    func networkWait(wake: WorkerWake? = nil) throws {
        guard !isStopped else { throw RoamError.cancelled }
        let direction = locked { libssh2_session_block_directions(session) }
        let read = direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0
        let write = direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
        let result = wake.map { $0.poll(socket, events: Int16((read || !write ? POLLIN : 0) | (write ? POLLOUT : 0)), timeout: waitMilliseconds(for: $0)) }
            ?? roam_socket_poll(socket, read || !write ? 1 : 0, write ? 1 : 0, Self.sharedWaitMs)
        if result < 0 {
            disconnect()
            throw RoamError.transport("Network wait failed")
        }
    }
    func waitMilliseconds(for wake: WorkerWake) -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        let alone = otherWork == 0 && waitingLoops.count == 1 && waitingLoops[ObjectIdentifier(wake)] != nil
        return alone ? Self.idleWaitMs : Self.sharedWaitMs
    }
    /// Wakes every parked loop, so each picks its wait again.
    private func wakeLoops(_ loops: [WorkerWake]) { for loop in loops { loop.signal() } }
    /// A loop that waits on the socket with `wake`, for as long as `body` runs.
    func asWaitingLoop<T>(_ wake: WorkerWake?, _ body: () throws -> T) rethrows -> T {
        guard let wake else { return try body() }
        stateLock.lock(); waitingLoops[ObjectIdentifier(wake)] = wake; let others = Array(waitingLoops.values); stateLock.unlock()
        wakeLoops(others)
        defer { stateLock.lock(); waitingLoops.removeValue(forKey: ObjectIdentifier(wake)); let rest = Array(waitingLoops.values); stateLock.unlock(); wakeLoops(rest) }
        return try body()
    }
    /// libssh2 work outside the loops: parked loops switch to short waits until it ends.
    func asOtherWork<T>(_ body: () throws -> T) rethrows -> T {
        beginOtherWork()
        defer { endOtherWork() }
        return try body()
    }
    /// The two halves of `asOtherWork`, for work that outlives one call (a held SFTP session).
    func beginOtherWork() {
        stateLock.lock(); otherWork += 1; let loops = otherWork == 1 ? Array(waitingLoops.values) : []; stateLock.unlock()
        wakeLoops(loops)
    }
    func endOtherWork() {
        // Its last call may have left a loop's packets in libssh2's buffer: each loop reads once more before waiting long.
        stateLock.lock(); otherWork -= 1; let loops = otherWork == 0 ? Array(waitingLoops.values) : []; stateLock.unlock()
        wakeLoops(loops)
    }
    @discardableResult
    func retry(timeout: TimeInterval = 20, cancelled: () -> Bool = { false }, _ operation: () -> Int32) throws -> Int32 {
        let until = Date().addingTimeInterval(timeout)
        var pending = false
        while true {
            if isStopped {
                // Finish only an operation already retained by libssh2. The
                // caller still receives cancellation, never business success.
                if pending { settle(timeout: 0, operation) }
                throw RoamError.cancelled
            }
            guard !cancelled() else { throw RoamError.cancelled }
            let value = locked(operation)
            pending = value == LIBSSH2_ERROR_EAGAIN
            if !pending {
                guard value >= 0 else { throw error(value) }
                return value
            }
            guard Date() < until else {
                disconnect(); settle(timeout: 0, operation)
                throw RoamError.timeout
            }
            do { try networkWait() } catch {
                if isStopped { settle(timeout: 0, operation) }
                throw error
            }
        }
    }
    /// Keep the exact retry arguments until the raw native operation completes.
    /// Recording and stopped replay use the same library lock as ordinary I/O.
    func readChannel(_ channel: OpaquePointer, _ stream: Int32, _ bytes: UnsafeMutablePointer<CChar>?, _ count: Int) -> Int {
        locked {
            let result = libssh2_channel_read_ex(channel, stream, bytes, count)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN { pending.read = pending.read ?? (stream, count) } else { pending.read = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    func writeChannel(_ channel: OpaquePointer, _ stream: Int32, _ bytes: UnsafePointer<CChar>?, _ count: Int) -> Int {
        locked {
            let result = libssh2_channel_write_ex(channel, stream, bytes, count)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN, pending.write == nil {
                // libssh2 writes at most 32700 bytes, even for a larger input.
                // Own only this in-flight chunk; the caller's buffer may expire.
                pending.write = (stream, bytes.map { Data(bytes: $0, count: min(count, 32768)) } ?? Data())
            } else if result != LIBSSH2_ERROR_EAGAIN { pending.write = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    func resizeChannel(_ channel: OpaquePointer, _ columns: Int32, _ rows: Int32, _ width: Int32, _ height: Int32) -> Int32 {
        locked {
            let result = libssh2_channel_request_pty_size_ex(channel, columns, rows, width, height)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN { pending.resize = pending.resize ?? (columns, rows, width, height) } else { pending.resize = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    private func storePending(_ pending: PendingChannelIO, channel: OpaquePointer) {
        if pending.isEmpty { pendingChannelIO.removeValue(forKey: channel) } else { pendingChannelIO[channel] = pending }
    }
    /// One bounded pass, under stopped disposal callbacks and libraryLock.
    /// Never wait for one candidate: its packet can belong to another candidate
    /// on this very worker. Whichever owns the native slot can finish this pass;
    /// the remaining candidates finish on the next pass.
    private func unwindPendingChannelIO() {
        var scratch = [CChar](repeating: 0, count: 32768)
        for (channel, var pending) in pendingChannelIO {
            if let read = pending.read {
                let result = libssh2_channel_read_ex(channel, read.stream, &scratch, min(read.count, scratch.count))
                if result != LIBSSH2_ERROR_EAGAIN { pending.read = nil }
            }
            if let write = pending.write {
                let result = write.bytes.withUnsafeBytes { libssh2_channel_write_ex(channel, write.stream, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
                if result != LIBSSH2_ERROR_EAGAIN { pending.write = nil }
            }
            if let size = pending.resize {
                let result = libssh2_channel_request_pty_size_ex(channel, size.columns, size.rows, size.width, size.height)
                if result != LIBSSH2_ERROR_EAGAIN { pending.resize = nil }
            }
            storePending(pending, channel: channel)
        }
    }
    /// Destructors and already-started requests retain native state through EAGAIN.
    /// Cancellation must finish that local state before its owner releases the resource.
    @discardableResult
    func settle(timeout: TimeInterval, _ operation: () -> Int32) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var abortIO = false
        while true {
            let result = locked {
                guard abortIO, isStopped, let session else { return operation() }
                // A pending packet can keep returning EAGAIN even after socket shutdown
                // (including custom socket callbacks). Fail its I/O while holding the
                // library lock so libssh2 can finish local destruction without a wait.
                let sendCallback = unsafeBitCast(stoppedCleanupSend, to: (@convention(c) () -> Void).self)
                let recvCallback = unsafeBitCast(stoppedCleanupReceive, to: (@convention(c) () -> Void).self)
                let send = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, sendCallback)
                let recv = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recvCallback)
                defer {
                    _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, send)
                    _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recv)
                }
                unwindPendingChannelIO()
                return operation()
            }
            if result != LIBSSH2_ERROR_EAGAIN {
                if result < 0 { _ = error(result) }
                return result >= 0
            }
            if isStopped {
                // Give every raw owner one disposal attempt before yielding to
                // another worker's in-flight retry/pointer operation.
                if abortIO { Thread.sleep(forTimeInterval: 0.001) }
                abortIO = true
                continue
            }
            if Date() >= deadline { disconnect(); abortIO = true; continue }
            do { try networkWait() } catch { disconnect(); abortIO = true }
        }
    }
    func pointer(timeout: TimeInterval = 20, cancelled: () -> Bool = { false }, _ operation: () -> OpaquePointer?) throws -> OpaquePointer {
        let until = Date().addingTimeInterval(timeout)
        var pending = false
        func finishStoppedRequest() -> OpaquePointer? {
            var pointer: OpaquePointer?
            settle(timeout: 0) {
                pointer = operation()
                return pointer == nil ? libssh2_session_last_errno(session) : 0
            }
            return pointer
        }
        while true {
            if isStopped {
                // A buffered successful result must reach its owning caller's
                // defer, even if disconnect won the race with native init/open.
                if pending, let pointer = finishStoppedRequest() { return pointer }
                throw RoamError.cancelled
            }
            guard !cancelled() else { throw RoamError.cancelled }
            let result: (OpaquePointer?, Int32) = locked { let p = operation(); return (p, p == nil ? libssh2_session_last_errno(session) : 0) }
            if let p = result.0 { return p }
            pending = result.1 == LIBSSH2_ERROR_EAGAIN
            guard pending else { throw error(result.1) }
            guard Date() < until else {
                disconnect()
                // Return a successful native open to its owner for disposal;
                // otherwise preserve the timeout that invalidated the session.
                if let pointer = finishStoppedRequest() { return pointer }
                throw RoamError.timeout
            }
            do { try networkWait() } catch {
                if isStopped, let pointer = finishStoppedRequest() { return pointer }
                throw error
            }
        }
    }
    func error(_ code: Int32) -> RoamError {
        if code == LIBSSH2_ERROR_AUTHENTICATION_FAILED { return .authentication }
        switch code {
        case LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
             LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_BAD_SOCKET,
             LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_INVALID_MAC,
             LIBSSH2_ERROR_DECRYPT, LIBSSH2_ERROR_ENCRYPT,
             LIBSSH2_ERROR_KEX_FAILURE, LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE,
             LIBSSH2_ERROR_PROTO, LIBSSH2_ERROR_ZLIB, LIBSSH2_ERROR_COMPRESS:
            disconnect()
        default: break // Missing files, denied channels, and command exits are not connection death.
        }
        // Library text may contain remote-controlled content or credentials; never log it.
        return .transport("SSH operation failed (\(code))")
    }
    public func connect() throws {
        _ = Self.initialized
        _ = try host.validated()
        onPhase?(.connecting)
        do {
            let fd = roam_tcp_connect(host.hostname, Int32(host.port), 20_000)
            guard fd >= 0 else { throw RoamError.transport("无法连接主机 / Cannot reach host") }
            stateLock.lock(); socket = fd; let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { throw RoamError.cancelled }
            guard let heap = roam_ssh_heap_create(Unmanaged.passUnretained(self).toOpaque()) else { throw RoamError.transport("SSH allocation failed") }
            guard let ssh = roam_ssh_session_init(heap) else { _ = roam_ssh_heap_destroy(heap, nil); throw RoamError.transport("SSH allocation failed") }
            self.heap = heap; session = ssh
            libssh2_session_set_blocking(ssh, 0)
            libssh2_session_set_timeout(ssh, 20_000)
            // No DSA, RSA/SHA1, CBC, group1 or SHA1 key-exchange downgrade.
            _ = libssh2_session_method_pref(ssh, LIBSSH2_METHOD_HOSTKEY, "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256")
            _ = libssh2_session_method_pref(ssh, LIBSSH2_METHOD_KEX,
                // swiftlint:disable:next line_length - libssh2 takes the algorithm list as one string
                "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512")
            for method in [LIBSSH2_METHOD_CRYPT_CS, LIBSSH2_METHOD_CRYPT_SC] {
                _ = libssh2_session_method_pref(ssh, method, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr")
            }
            try retry { libssh2_session_handshake(ssh, fd) }
            onPhase?(.verifying)
            var keyLength = 0; var keyType: Int32 = 0
            guard let bytes = libssh2_session_hostkey(ssh, &keyLength, &keyType), keyLength > 0 else { throw RoamError.transport("Missing host key") }
            let algorithm = libssh2_session_methods(ssh, LIBSSH2_METHOD_HOSTKEY).map { String(cString: $0) } ?? "unknown"
            let pin = HostPin(endpoint: host.endpoint, algorithm: algorithm, key: Data(bytes: bytes, count: keyLength))
            try TrustPolicy(store: pins).verify(pin) { self.prompt(.verifyHost(pin)) != nil }
            guard !isStopped else { throw RoamError.cancelled }
            onPhase?(.authenticating)
            switch host.auth {
            case .password:
                guard let password = credentials.password else { throw RoamError.authentication }
                _ = try password.withUnsafeBytes { raw in
                    try retry(timeout: 140) {
                        libssh2_userauth_password_ex(ssh, host.username, UInt32(host.username.utf8.count), raw.bindMemory(to: CChar.self).baseAddress, UInt32(password.count), nil)
                    }
                }
            case .key:
                guard let key = credentials.privateKey else { throw RoamError.authentication }
                _ = try key.withUnsafeBytes { raw in
                    try retry(timeout: 140) {
                        libssh2_userauth_publickey_frommemory(ssh, host.username, host.username.utf8.count, nil, 0,
                            raw.bindMemory(to: CChar.self).baseAddress, key.count, credentials.passphrase)
                    }
                }
            case .interactive:
                try retry(timeout: 140) {
                    libssh2_userauth_keyboard_interactive_ex(ssh, host.username, UInt32(host.username.utf8.count)) { _, _, instruction, length, count, prompts, responses, abstract in
                        guard let opaque = roam_ssh_user(abstract), let prompts, let responses, count >= 0, count <= 128 else { return }
                        let owner = Unmanaged<SSHConnection>.fromOpaque(opaque).takeUnretainedValue()
                        let labels = (0..<Int(count)).map { i in
                            prompts[i].text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(prompts[i].length)), as: UTF8.self) } ?? ""
                        }
                        let echo = (0..<Int(count)).map { prompts[$0].echo != 0 }
                        let text = instruction.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: max(0, Int(length))), as: UTF8.self) } ?? ""
                        guard let answers = owner.prompt(.keyboard(instruction: text, labels: labels, echo: echo)), answers.count == Int(count) else { return }
                        for i in 0..<answers.count {
                            let bytes = answers[i].utf8CString
                            // libssh2 frees the answers with the session's own allocator.
                            guard bytes.count <= 1_048_577, let memory = roam_ssh_alloc(abstract, bytes.count) else { continue }
                            bytes.withUnsafeBufferPointer { buffer in _ = memcpy(memory, buffer.baseAddress!, buffer.count) }
                            responses[i].text = memory.assumingMemoryBound(to: CChar.self)
                            responses[i].length = UInt32(bytes.count - 1)
                        }
                    }
                }
            }
            credentials.clear()
            libssh2_keepalive_config(ssh, 1, 15)
            stateLock.lock()
            let cancelledAfterAuthentication = stopped
            if !cancelledAfterAuthentication { authenticated = true }
            stateLock.unlock()
            guard !cancelledAfterAuthentication else { throw RoamError.cancelled }
            onPhase?(.connected)
        } catch {
            credentials.clear()
            if case RoamError.hostKeyChanged = error { onPhase?(.hostKeyChanged) } else if case RoamError.authentication = error { onPhase?(.authFailed) } else { onPhase?(.failed) }
            disconnect(); throw error
        }
    }
    public func disconnect() {
        stateLock.lock()
        let notify = authenticated && !stopped
        authenticated = false; stopped = true; acceptingInput = false; input.reset(); transferGeneration += 1
        let fd = socket, loops = Array(waitingLoops.values)
        stateLock.unlock()
        roam_socket_shutdown(fd)
        wakeLoops(loops)
        creationCondition.lock(); creationCondition.broadcast(); creationCondition.unlock()
        if notify { onPhase?(.disconnected) }
    }
    func openChannel(cancelled: () -> Bool = { false }, start: (OpaquePointer) throws -> Void) throws -> OpaquePointer {
        try withChannelCreation(cancelled: cancelled) {
            let channel = try pointer { libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) }
            do { try start(channel); return channel } catch { closeChannel(channel); throw error }
        }
    }
    /// A direct-tcpip channel: the server connects to `host`:`port` and carries that connection. Throws
    /// `PortTunnelError.prohibited` when the server refuses to forward at all (`AllowTcpForwarding no`).
    func openDirectChannel(host: String, port: Int) throws -> OpaquePointer {
        var prohibited = false
        do {
            return try withChannelCreation {
                try pointer {
                    let channel = libssh2_channel_direct_tcpip_ex(session, host, Int32(port), "127.0.0.1", 22)
                    // Read under the library lock with the failure itself: the reason is only in libssh2's own text.
                    prohibited = channel == nil && Self.lastErrorIsProhibited(session)
                    return channel
                }
            }
        } catch {
            if prohibited { throw PortTunnelError.prohibited }
            throw error
        }
    }
    /// libssh2 reports every refused channel as `LIBSSH2_ERROR_CHANNEL_FAILURE`; the reason it gives in its own,
    /// fixed message tells "administratively prohibited" from "connect failed".
    private static func lastErrorIsProhibited(_ session: OpaquePointer?) -> Bool {
        guard let session else { return false }
        var message: UnsafeMutablePointer<CChar>?
        guard libssh2_session_last_error(session, &message, nil, 0) == LIBSSH2_ERROR_CHANNEL_FAILURE, let message else { return false }
        return strstr(message, "prohibited") != nil
    }
    func openSFTP(cancelled: () -> Bool = { false }) throws -> OpaquePointer {
        try withChannelCreation(cancelled: cancelled) {
            // A second init cannot start while the first remains in EAGAIN.
            // Finish the shared init sequence, then dispose a cancelled result.
            let sftp = try pointer { libssh2_sftp_init(session) }
            if isStopped || cancelled() {
                settle(timeout: 10) { libssh2_sftp_shutdown(sftp) }
                throw RoamError.cancelled
            }
            return sftp
        }
    }
    private func withChannelCreation<T>(cancelled: () -> Bool = { false }, _ action: () throws -> T) throws -> T {
        try asOtherWork { try createChannel(cancelled: cancelled, action) }
    }
    private func createChannel<T>(cancelled: () -> Bool, _ action: () throws -> T) throws -> T {
        creationCondition.lock()
        while creatingChannel {
            if isStopped || cancelled() {
                creationCondition.unlock(); throw RoamError.cancelled
            }
            _ = creationCondition.wait(until: Date().addingTimeInterval(0.03))
        }
        guard !isStopped, !cancelled() else {
            creationCondition.unlock(); throw RoamError.cancelled
        }
        guard isConnected else {
            creationCondition.unlock(); throw RoamError.transport("SSH connection is not authenticated")
        }
        creatingChannel = true
        creationCondition.unlock()
        defer {
            creationCondition.lock(); creatingChannel = false; creationCondition.broadcast(); creationCondition.unlock()
        }
        do { return try action() } catch {
            // A timed-out init still owns libssh2's pending session state; a new
            // connection is required before another independent init can start.
            if error as? RoamError == .timeout { disconnect() }
            throw error
        }
    }
    func closeChannel(_ channel: OpaquePointer) {
        asOtherWork {
            settle(timeout: 2) { libssh2_channel_close(channel) }
            settle(timeout: 2) {
                let result = libssh2_channel_free(channel)
                if result != LIBSSH2_ERROR_EAGAIN { pendingChannelIO.removeValue(forKey: channel) }
                return result
            }
        }
    }
    /// Closing a pipe-backed exec channel does not stop its remote process.
    /// Signal this channel's process group first, leaving other exec/PTY/SFTP
    /// channels and the cached connection intact. TERM gives sudo time to relay
    /// the signal to its privileged command before any bounded escalation.
    /// This is best effort on servers that ignore SSH signals. Detached or
    /// differently privileged descendants need their own command's cleanup;
    /// there is deliberately no host-wide PID/group scan or extra sudo request.
    private func terminateExec(_ channel: OpaquePointer) {
        guard !isStopped else { return }
        let deadline = Date().addingTimeInterval(3)
        // libssh2 retains the signal packet across EAGAIN and ignores a new
        // signame until that packet completes. Finish TERM before starting a
        // distinct KILL, reserving the final half-second for escalation.
        let escalation = deadline.addingTimeInterval(-0.5)
        guard sendExecSignal(channel, name: "TERM", until: escalation) else { return }
        if drainTerminatedExec(channel, until: min(escalation, Date().addingTimeInterval(2))) { return }
        guard !isStopped, Date() < deadline else { return }
        guard sendExecSignal(channel, name: "KILL", until: deadline) else { return }
        _ = drainTerminatedExec(channel, until: deadline)
    }
    private func sendExecSignal(_ channel: OpaquePointer, name: String, until deadline: Date) -> Bool {
        do {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RoamError.timeout }
            _ = try retry(timeout: remaining) { libssh2_channel_signal_ex(channel, name, name.utf8.count) }
            return true
        } catch {
            // An unfinished signal (or an earlier pending write that prevents
            // its send) occupies the session's shared transport slot. Closing
            // just this channel would leave every future channel stuck behind
            // that packet. Mark the connection unusable before normal cleanup.
            disconnect()
            return false
        }
    }
    private func drainTerminatedExec(_ channel: OpaquePointer, until deadline: Date) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !isStopped, Date() < deadline {
            for stream in 0...1 {
                let count = buffer.withUnsafeMutableBytes { raw in
                    readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                }
                if count < 0 && count != LIBSSH2_ERROR_EAGAIN { return false }
            }
            if locked({ libssh2_channel_eof(channel) }) != 0 {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                return (try? retry(timeout: remaining) { libssh2_channel_wait_closed(channel) }) != nil
            }
            do { try networkWait() } catch { return false }
        }
        return false
    }
    public func openTerminal(mode: SessionMode, remoteName: String, existing: Bool = false, columns: Int, rows: Int) throws {
        guard terminal == nil else { throw RoamError.invalid("A terminal is already open") }
        if mode == .tmux { if try exec(RemoteCommands.tmuxProbe).status != 0 { onPhase?(.tmuxMissing); throw RoamError.tmuxMissing } }
        let channel = try openChannel { channel in
            try retry { libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, nil, 0, Int32(max(2, columns)), Int32(max(2, rows)), 0, 0) }
            if mode == .tmux {
                let command = RemoteCommands.tmuxAttach(remoteName, existing: existing)
                _ = try command.withCString { bytes in
                    try retry { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
                }
            } else { try retry { libssh2_channel_process_startup(channel, "shell", 5, nil, 0) } }
        }
        stateLock.lock(); terminal = channel; acceptingInput = !stopped; stateLock.unlock()
    }
    @discardableResult public func write(_ data: Data) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped && acceptingInput && input.enqueue(data) else { return false }
        wake?.signal()
        return true
    }
    public func resize(columns: Int, rows: Int) {
        stateLock.lock(); pendingSize = (max(2, columns), max(2, rows)); stateLock.unlock()
        wake?.signal()
    }
    /// The most terminal output gathered before it is handed over.
    static let burstLimit = 128 * 1024
    public func runTerminal(onOutput: @escaping (Data) -> Void) throws {
        guard let channel = terminal else { throw RoamError.invalid("Terminal is not open") }
        defer {
            stateLock.lock(); acceptingInput = false; input.reset(); terminal = nil; stateLock.unlock()
            closeChannel(channel); onPhase?(.disconnected)
        }
        try asWaitingLoop(wake) { try terminalLoop(channel, onOutput: onOutput) }
    }
    private func terminalLoop(_ channel: OpaquePointer, onOutput: @escaping (Data) -> Void) throws {
        var sizing: (Int, Int)?
        var buffer = [UInt8](repeating: 0, count: 32768)
        var outgoing = Data(); var offset = 0
        var lastAlive = Date()
        // libssh2 resends the request it started after EAGAIN and ignores the size passed with the retry, so the
        // size in flight is kept apart from a newer one, which goes once it is done.
        while !isStopped {
            stateLock.lock()
            if sizing == nil { sizing = pendingSize; pendingSize = nil }
            if outgoing.isEmpty { outgoing = input.pop() ?? Data(); offset = 0 }
            stateLock.unlock()
            var resized = false
            if let size = sizing {
                let rc = resizeChannel(channel, Int32(size.0), Int32(size.1), 0, 0)
                if rc == 0 { sizing = nil; resized = true } else if rc != LIBSSH2_ERROR_EAGAIN { throw error(rc) }
            }
            if !outgoing.isEmpty {
                let sent = outgoing.withUnsafeBytes { raw in
                    writeChannel(channel, 0, raw.bindMemory(to: CChar.self).baseAddress!.advanced(by: offset), outgoing.count - offset)
                }
                if sent > 0 {
                    offset += sent
                    if offset == outgoing.count { outgoing.removeAll(keepingCapacity: true); offset = 0 }
                } else if sent < 0 && sent != LIBSSH2_ERROR_EAGAIN {
                    throw error(Int32(sent))
                }
            }
            // A burst is drained up to `burstLimit` and handed over once: each hand-over waits for the main
            // thread, so one per 8 KiB read kept it busy for as long as a large output ran.
            var chunk = Data()
            for stream in 0...1 {
                while chunk.count < Self.burstLimit {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                    }
                    if count > 0 { chunk.append(contentsOf: buffer[0..<count]) } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN {
                        if !chunk.isEmpty { onOutput(chunk) }
                        throw error(Int32(count))
                    } else { break }
                }
            }
            let received = !chunk.isEmpty
            if received { onOutput(chunk) }
            if locked({ libssh2_channel_eof(channel) }) != 0 { return }
            if Date().timeIntervalSince(lastAlive) > 15 {
                var seconds: Int32 = 0
                try retry(timeout: 60) { libssh2_keepalive_send(session, &seconds) }
                lastAlive = Date()
            }
            stateLock.lock(); let newerSize = resized && pendingSize != nil; stateLock.unlock()
            if !received && !newerSize { try networkWait(wake: wake) }
        }
        throw RoamError.cancelled
    }
    public func exec(_ command: String, timeout: TimeInterval = 20) throws -> CommandResult {
        try execute(command, input: nil, timeout: timeout, cancellation: nil, onOutput: nil)
    }

    /// Sends bytes through channel stdin, followed by EOF; input never becomes an
    /// SSH command argument. Output callbacks run on this worker outside the lock.
    /// Both input and combined stdout/stderr are limited to 8 MiB.
    public func exec(_ command: String, input: Data, timeout: TimeInterval = 20,
                     cancellation: TransferCancellation? = nil,
                     onOutput: ((Data) -> Void)? = nil) throws -> CommandResult {
        try execute(command, input: input, timeout: timeout, cancellation: cancellation, onOutput: onOutput)
    }

    private func execute(_ command: String, input: Data?, timeout: TimeInterval,
                         cancellation: TransferCancellation?, onOutput: ((Data) -> Void)?) throws -> CommandResult {
        let limit = 8 * 1024 * 1024
        guard timeout.isFinite, timeout > 0, command.utf8.count <= 256 * 1024,
              (input?.count ?? 0) <= limit else { throw RoamError.invalid("SSH command or input exceeds its limit") }
        guard !isStopped, cancellation?.isCancelled != true else { throw RoamError.cancelled }
        return try asOtherWork { try runCommand(command, input: input, timeout: timeout, limit: limit, cancellation: cancellation, onOutput: onOutput) }
    }
    private func runCommand(_ command: String, input: Data?, timeout: TimeInterval, limit: Int,
                            cancellation: TransferCancellation?, onOutput: ((Data) -> Void)?) throws -> CommandResult {
        let channel = try command.withCString { bytes in
            try openChannel(cancelled: { cancellation?.isCancelled == true }) { channel in
                // Complete channel setup before honoring a per-command cancel;
                // abandoning session-level EAGAIN state would affect other jobs.
                try retry(timeout: min(timeout, 20)) { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
            }
        }
        var completed = false
        defer { if !completed { terminateExec(channel) }; closeChannel(channel) }
        let stdin = input ?? Data()
        let until = Date().addingTimeInterval(timeout)
        return try stdin.withUnsafeBytes { inputBytes in
            var output = Data(); var buffer = [UInt8](repeating: 0, count: 32768)
            var sent = 0; var eofSent = input == nil
            while !isStopped {
                guard cancellation?.isCancelled != true else { throw RoamError.cancelled }
                guard Date() < until else { throw RoamError.timeout }
                var progressed = false
                // Reading and writing must interleave. A command such as `cat`
                // can fill its output window before all input has been sent.
                for stream in 0...1 {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                    }
                    if count > 0 {
                        guard count <= limit - output.count else { throw RoamError.invalid("远端响应过大 / Remote response too large") }
                        let bytes = Data(buffer[0..<count])
                        output.append(bytes); progressed = true
                        onOutput?(bytes)
                        guard cancellation?.isCancelled != true, !isStopped else { throw RoamError.cancelled }
                    } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw error(Int32(count)) }
                }
                if locked({ libssh2_channel_eof(channel) }) != 0 {
                    // Output EOF can precede process exit. A short ignored wait
                    // would otherwise report libssh2's default status 0 while
                    // the command is still running and may eventually fail.
                    let remaining = until.timeIntervalSinceNow
                    guard remaining > 0 else { throw RoamError.timeout }
                    try retry(timeout: remaining, cancelled: { cancellation?.isCancelled == true }) { libssh2_channel_wait_closed(channel) }
                    guard cancellation?.isCancelled != true, !isStopped else { throw RoamError.cancelled }
                    let result = CommandResult(output: output, status: locked { libssh2_channel_get_exit_status(channel) })
                    completed = true
                    return result
                }
                if sent < stdin.count {
                    let count = writeChannel(channel, 0, inputBytes.bindMemory(to: CChar.self).baseAddress!.advanced(by: sent), min(32768, stdin.count - sent))
                    if count > 0 { sent += count; progressed = true } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw error(Int32(count)) }
                } else if !eofSent {
                    let result = locked { libssh2_channel_send_eof(channel) }
                    if result == 0 { eofSent = true; progressed = true } else if result != LIBSSH2_ERROR_EAGAIN { throw error(result) }
                }
                if !progressed { try networkWait() }
            }
            throw RoamError.cancelled
        }
    }
    func transferEpoch() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return transferGeneration }
}

// libssh2 socket callbacks return negative errno, rather than setting errno.
private let stoppedCleanupReceive: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, _, _, _ in -Int(ENOTCONN) }

// Discard output only after socket shutdown. Reporting a complete send lets
// libssh2 clear its retained packet slot before its final receive fails.
private let stoppedCleanupSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, count, _, _ in count }
