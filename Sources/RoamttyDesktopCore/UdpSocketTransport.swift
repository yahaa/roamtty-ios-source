import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A UDP socket to the host for `UdpLink`: BSD sockets (they work the same on iOS and Linux), one
/// receive thread per socket, and a new socket on `rebind` after a network change. The socket is
/// connected to the host, so the kernel drops datagrams from anyone else; AES-GCM checks the rest.
public final class UdpSocketTransport: UdpTransport, @unchecked Sendable {
    public enum Failure: Error { case resolve(String), socket(Int32) }

    public var onReceive: (([UInt8]) -> Void)?
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private let address: [UInt8]
    private let family: Int32

    public init(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #else
        hints.ai_socktype = SOCK_DGRAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { throw Failure.resolve(host) }
        defer { freeaddrinfo(res) }
        family = info.pointee.ai_family
        address = Array(UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
        try open()
    }

    private func open() throws {
        #if canImport(Glibc)
        let s = socket(family, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let s = socket(family, SOCK_DGRAM, 0)
        #endif
        guard s >= 0 else { throw Failure.socket(errno) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = address.withUnsafeBytes { connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count)) }
        guard rc == 0 else { let e = errno; _ = systemClose(s); throw Failure.socket(e) }
        lock.lock(); let old = fd; fd = s; lock.unlock()
        if old >= 0 { _ = systemClose(old) }
        let thread = Thread { [weak self] in self?.receiveLoop(s) }
        thread.name = "desktop-udp-rx"
        thread.start()
    }

    private func current() -> (fd: Int32, closed: Bool) { lock.lock(); defer { lock.unlock() }; return (fd, closed) }

    private func receiveLoop(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let (now, isClosed) = current()
            if isClosed || now != s { return }
            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            if n > 0 { onReceive?(Array(buf[0..<n])) }
        }
    }

    public var localPort: Int {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let s = current().fd
        let rc = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        guard rc == 0 else { return 0 }
        let family = Int32(storage.ss_family)
        return withUnsafePointer(to: &storage) { p in
            if family == AF_INET6 {
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            }
            return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
    }

    public func send(_ datagram: [UInt8]) {
        let s = current().fd
        guard s >= 0 else { return }
        _ = datagram.withUnsafeBytes { systemSend(s, $0.baseAddress, $0.count) }
    }

    public func rebind() throws { try open() }

    public func close() {
        lock.lock(); closed = true; let s = fd; fd = -1; lock.unlock()
        if s >= 0 { _ = systemClose(s) }
    }

    private func systemSend(_ s: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(s, p, n, 0)
        #else
        return Glibc.send(s, p, n, 0)
        #endif
    }

    private func systemClose(_ s: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(s)
        #else
        return Glibc.close(s)
        #endif
    }
}
