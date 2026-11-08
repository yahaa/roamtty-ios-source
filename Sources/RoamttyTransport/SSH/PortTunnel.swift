import Foundation
import CNative
import RoamttyCore

/// Why a forwarded connection did not open.
public enum PortTunnelError: Error, Equatable {
    /// The SSH login the tunnel rides on is not up, or not yet back after a drop.
    case unavailable
    /// The server could not connect, as when nothing listens on the port.
    case refused
    /// The server does not forward connections for this login (`AllowTcpForwarding no`): nothing to retry.
    case prohibited
}

extension SSHConnection {
    /// A TCP connection the server makes to `host`:`port` for the phone (SSH direct-tcpip), as a stream: `read` takes
    /// what the far end sends until its end, `write` sends to it. Throws `PortTunnelError`. Blocks: never call it on
    /// the main thread.
    public func openSocket(host: String, port: Int) throws -> SSHExecStream {
        guard isConnected else { throw PortTunnelError.unavailable }
        do {
            return SSHExecStream(connection: self, channel: try openDirectChannel(host: host, port: port), endsAtEOF: true)
        } catch PortTunnelError.prohibited {
            throw PortTunnelError.prohibited
        } catch {
            throw isConnected ? PortTunnelError.refused : PortTunnelError.unavailable
        }
    }
}

/// One forwarded connection as `PortTunnel` uses it; `SSHExecStream` over a direct-tcpip channel is the real one.
public protocol TunnelStream: AnyObject, Sendable {
    /// Blocks until bytes come; empty once the far end's output ended or the stream closed.
    func read(maxBytes: Int) -> [UInt8]
    func write(_ bytes: [UInt8]) throws
    /// Ends what this side sends, once everything written so far has gone.
    func finishWriting()
    func close()
}

extension SSHExecStream: TunnelStream {}

/// Android's `PortTunnel` (roamtty #275): serves 127.0.0.1 on the phone and carries each connection to `target`:`port`
/// on the server through `open`, one SSH channel per connection. Every connection asks `open` afresh, so the tunnel
/// outlives a dropped and restored login. It takes the server's own port number when that is free on the phone, so
/// pages that name their port still work.
public final class PortTunnel: @unchecked Sendable {
    public let target: String
    public let port: Int
    public let localPort: Int
    /// Blocking; called on the tunnel's own threads.
    private let open: @Sendable (String, Int) throws -> TunnelStream
    private let listener: Int32
    private let lock = NSLock()
    private var closed = false
    private var clients: Set<Int32> = []
    private var streams: [ObjectIdentifier: TunnelStream] = [:]

    public init(target: String, port: Int, preferredLocalPort: Int? = nil, open: @escaping @Sendable (String, Int) throws -> TunnelStream) throws {
        self.target = target; self.port = port; self.open = open
        var bound: Int32 = 0
        let descriptor = roam_listen_loopback(Int32(preferredLocalPort ?? port), &bound)
        guard descriptor >= 0 else { throw RoamError.transport("Cannot listen on the phone's loopback") }
        listener = descriptor; localPort = Int(bound)
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "roamtty.tunnel.\(port)"
        thread.start()
    }

    deinit { close() }

    /// Whether something on the server accepts connections on the port. Throws `PortTunnelError.unavailable` when
    /// the login is not up and `.prohibited` when the server forwards nothing, so a caller can tell "nothing
    /// listens" from "cannot ask". Blocks.
    public func listening() throws -> Bool {
        do { try open(target, port).close(); return true } catch PortTunnelError.refused { return false }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func acceptLoop() {
        defer { roam_socket_close(listener) }
        while !isClosed {
            let client = roam_socket_accept(listener, 250)
            if client == -2 { continue }
            if client < 0 { return }
            lock.lock()
            guard !closed else { lock.unlock(); roam_socket_close(client); return }
            clients.insert(client)
            lock.unlock()
            let thread = Thread { [self] in relay(client) }
            thread.name = "roamtty.tunnel.\(port).relay"
            thread.start()
        }
    }

    private func relay(_ client: Int32) {
        defer {
            lock.lock(); clients.remove(client); lock.unlock()
            roam_socket_close(client)
        }
        guard let remote = try? open(target, port) else { return }
        lock.lock()
        let wanted = !closed
        if wanted { streams[ObjectIdentifier(remote)] = remote }
        lock.unlock()
        defer { remote.close(); lock.lock(); streams.removeValue(forKey: ObjectIdentifier(remote)); lock.unlock() }
        guard wanted else { return }
        // The page's requests: an end of them is passed on, and the server's answer still comes back.
        let uploaded = DispatchSemaphore(value: 0)
        let upload = Thread {
            defer { uploaded.signal() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { roam_socket_recv(client, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                do { try remote.write(Array(buffer[0..<Int(count)])) } catch { return }
            }
            remote.finishWriting()
        }
        upload.name = "roamtty.tunnel.\(port).upload"
        upload.start()
        while true {
            let bytes = remote.read(maxBytes: 32 * 1024)
            if bytes.isEmpty { break }
            let failed = bytes.withUnsafeBytes { roam_socket_send_all(client, $0.baseAddress, $0.count) } != 0
            if failed { break }
        }
        // Wakes the upload thread from its read, so the descriptor is closed only once nothing uses it.
        roam_socket_shutdown(client)
        uploaded.wait()
    }

    /// Stops listening and ends every connection still open.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let open = Array(clients), remotes = Array(streams.values)
        lock.unlock()
        for client in open { roam_socket_shutdown(client) }
        for remote in remotes { remote.close() }
    }
}
