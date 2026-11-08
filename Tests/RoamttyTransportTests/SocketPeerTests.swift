import XCTest
import CNative
#if os(Linux)
import Glibc
private let bindSocket = Glibc.bind
#else
import Darwin
private let bindSocket = Darwin.bind
#endif

final class SocketPeerTests: XCTestCase {
    /// "localhost" may resolve to ::1 first; mosh must use the IPv4 address the TCP connection actually reached.
    func testPeerIsTheNumericAddressTheConnectionReached() throws {
        #if os(Linux)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { roam_socket_close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bindSocket(listener, $0, size) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &size) == 0
            }
        }
        XCTAssertTrue(bound)
        let fd = roam_tcp_connect("localhost", Int32(UInt16(bigEndian: address.sin_port)), 5_000)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { roam_socket_close(fd) }
        var host = [CChar](repeating: 0, count: 1025)
        XCTAssertEqual(roam_socket_peer(fd, &host, Int32(host.count)), 0)
        XCTAssertEqual(String(cString: host), "127.0.0.1")
    }

    func testPeerFailsWithoutAConnection() {
        var host = [CChar](repeating: 0, count: 1025)
        XCTAssertNotEqual(roam_socket_peer(-1, &host, Int32(host.count)), 0)
    }
}
