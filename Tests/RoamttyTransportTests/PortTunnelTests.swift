import XCTest
import CNative
import RoamttyCore
@testable import RoamttyTransport

/// Android's PortTunnelTest: the tunnel on the phone's loopback, with a plain socket standing in for the SSH channel,
/// then the real thing over the fixture's login.
final class PortTunnelTests: XCTestCase {
    /// Stands in for the SSH channel: a plain socket to `port` on this machine.
    private final class SocketStream: TunnelStream, @unchecked Sendable {
        let fd: Int32
        init(port: Int) throws {
            fd = roam_tcp_connect("127.0.0.1", Int32(port), 2000)
            guard fd >= 0 else { throw PortTunnelError.refused }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        }
        deinit { roam_socket_close(fd) }
        func read(maxBytes: Int) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: maxBytes)
            let count = buffer.withUnsafeMutableBytes { roam_socket_recv(fd, $0.baseAddress, $0.count) }
            return count > 0 ? Array(buffer[0..<Int(count)]) : []
        }
        func write(_ bytes: [UInt8]) throws {
            guard bytes.withUnsafeBytes({ roam_socket_send_all(fd, $0.baseAddress, $0.count) }) == 0 else { throw PortTunnelError.refused }
        }
        func finishWriting() { roam_socket_shutdown_write(fd) }
        func close() { roam_socket_shutdown(fd) }
    }

    /// Answers each connection with an HTTP response naming what was asked, then closes it.
    private final class WebServer: @unchecked Sendable {
        let listener: Int32
        let port: Int
        private let lock = NSLock()
        private var stopped = false
        init() throws {
            var bound: Int32 = 0
            listener = roam_listen_loopback(0, &bound)
            guard listener >= 0 else { throw PortTunnelError.unavailable }
            port = Int(bound)
            Thread { [self] in
                while true {
                    lock.lock(); let done = stopped; lock.unlock()
                    if done { break }
                    let client = roam_socket_accept(listener, 100)
                    if client == -2 { continue }
                    if client < 0 { break }
                    Thread {
                        var request = [UInt8](), buffer = [UInt8](repeating: 0, count: 1024)
                        while !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") {
                            let count = buffer.withUnsafeMutableBytes { roam_socket_recv(client, $0.baseAddress, $0.count) }
                            if count <= 0 { break }
                            request += buffer[0..<Int(count)]
                        }
                        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                        let body = "got " + line
                        let response = Array("HTTP/1.0 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
                        _ = response.withUnsafeBytes { roam_socket_send_all(client, $0.baseAddress, $0.count) }
                        roam_socket_close(client)
                    }.start()
                }
                roam_socket_close(listener)
            }.start()
        }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }

    private func fetch(_ port: Int, _ path: String) throws -> String {
        let stream = try SocketStream(port: port)
        defer { stream.close() }
        try stream.write(Array("GET \(path) HTTP/1.0\r\n\r\n".utf8))
        var answer: [UInt8] = []
        while true {
            let bytes = stream.read(maxBytes: 4096)
            if bytes.isEmpty { break }
            answer += bytes
        }
        return String(decoding: answer, as: UTF8.self)
    }

    private func freePort() -> Int {
        var bound: Int32 = 0
        let fd = roam_listen_loopback(0, &bound)
        roam_socket_close(fd)
        return Int(bound)
    }

    func testCarriesEachConnectionToTheServerPort() throws {
        let server = try WebServer(); defer { server.stop() }
        let tunnel = try PortTunnel(target: "localhost", port: server.port, preferredLocalPort: 0) { _, port in try SocketStream(port: port) }
        defer { tunnel.close() }
        XCTAssertNotEqual(tunnel.localPort, server.port)
        XCTAssertTrue(try tunnel.listening())
        XCTAssertTrue(try fetch(tunnel.localPort, "/a").hasSuffix("got GET /a HTTP/1.0"))
        // A second connection gets a channel of its own.
        XCTAssertTrue(try fetch(tunnel.localPort, "/b?x=1").hasSuffix("got GET /b?x=1 HTTP/1.0"))
    }

    func testTakesTheServerPortNumberWhenItIsFreeOnThePhone() throws {
        let free = freePort()
        let tunnel = try PortTunnel(target: "localhost", port: free) { _, port in try SocketStream(port: port) }
        XCTAssertEqual(tunnel.localPort, free)
        // Taken: any free port.
        let other = try PortTunnel(target: "localhost", port: free) { _, port in try SocketStream(port: port) }
        XCTAssertNotEqual(other.localPort, free)
        other.close(); tunnel.close()
    }

    func testReportsAPortNothingListensOn() throws {
        let closed = freePort()
        let tunnel = try PortTunnel(target: "localhost", port: closed, preferredLocalPort: 0) { _, port in try SocketStream(port: port) }
        defer { tunnel.close() }
        XCTAssertFalse(try tunnel.listening())
        // The page's connection ends at once instead of hanging.
        XCTAssertEqual(try fetch(tunnel.localPort, "/"), "")
    }

    func testALostLoginIsNotMistakenForAClosedPort() throws {
        let tunnel = try PortTunnel(target: "localhost", port: 5173, preferredLocalPort: 0) { _, _ in throw PortTunnelError.unavailable }
        XCTAssertThrowsError(try tunnel.listening()) { XCTAssertEqual($0 as? PortTunnelError, .unavailable) }
        let port = tunnel.localPort
        tunnel.close()
        // The listener goes with the tunnel.
        let deadline = Date().addingTimeInterval(2)
        var fd: Int32 = 0
        repeat { fd = roam_tcp_connect("127.0.0.1", Int32(port), 500); if fd >= 0 { roam_socket_close(fd); Thread.sleep(forTimeInterval: 0.1) } } while fd >= 0 && Date() < deadline
        XCTAssertLessThan(fd, 0)
    }

    // MARK: Over the fixture's SSH login

    private func connect() throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Set ROAMTTY_TEST_PASSWORD_FILE to run live OpenSSH tests") }
        let password = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(name: "Fixture", address: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test", auth: .password)
        let connection = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: try AppStore(url: URL(fileURLWithPath: ":memory:"))) { prompt in
            if case .verifyHost = prompt { return ["trust"] }
            return [password]
        }
        try connection.connect()
        return connection
    }

    func testDirectChannelsReachTheServersOwnPorts() throws {
        let client = try connect(); defer { client.disconnect() }
        // The fixture's sshd answers on its own port 22 with its banner.
        let ssh = try client.openSocket(host: "localhost", port: 22)
        let banner = ssh.read(maxBytes: 64)
        ssh.close()
        XCTAssertTrue(String(decoding: banner, as: UTF8.self).hasPrefix("SSH-2.0"))
        XCTAssertThrowsError(try client.openSocket(host: "localhost", port: 1)) { XCTAssertEqual($0 as? PortTunnelError, .refused) }
        // A refused channel leaves the login usable.
        XCTAssertEqual(try client.exec("printf ok").text, "ok")
        // A target the server will not forward to at all is told apart from a port nothing listens on.
        XCTAssertThrowsError(try client.openSocket(host: "127.0.0.2", port: 22)) { XCTAssertEqual($0 as? PortTunnelError, .prohibited) }
        XCTAssertEqual(try client.exec("printf ok").text, "ok")
        // A page served on the host's loopback, through a tunnel on this machine.
        let port = 18000 + Int.random(in: 0..<2000)
        let server = "cd /tmp && exec python3 -m http.server \(port) --bind 127.0.0.1"
        let stream = try client.openStream(server); defer { stream.close() }
        let tunnel = try PortTunnel(target: "localhost", port: port, preferredLocalPort: 0) { host, port in try client.openSocket(host: host, port: port) }
        defer { tunnel.close() }
        let deadline = Date().addingTimeInterval(10)
        while try !tunnel.listening() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        let page = try fetch(tunnel.localPort, "/")
        XCTAssertTrue(page.hasPrefix("HTTP/1.0 200"), page)
        XCTAssertTrue(page.contains("Directory listing"), page)
        // The listing script finds that server with its command line.
        let lines = try client.exec(RemoteCommands.stdinShell, input: Data(ListeningPort.script.utf8)).text.split(separator: "\n").map(String.init)
        let listed = try XCTUnwrap(ListeningPort.parse(lines).first { $0.port == port }, lines.joined(separator: "\n"))
        XCTAssertTrue(listed.command.contains("http.server"), listed.command)
        XCTAssertEqual(listed.directory, "/tmp")
    }
}
