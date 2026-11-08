import XCTest
import CNative
@testable import RoamttyCore

/// Android's ListeningPortsTest and PortTunnelTest's address cases.
final class ListeningPortsTests: XCTestCase {
    func testListsOwnProcessesFirstWithTheirFoldersUnderHome() {
        let ports = ListeningPort.parse([
            "HOME\t/home/v",
            "PORT\t0.0.0.0:22\t\t\t",
            "PORT\t[::]:22\t\t\t",
            "PORT\t127.0.0.1:8888\t42\t/home/v/ml\t/usr/bin/python3 /home/v/.local/bin/jupyter-lab --no-browser",
            "PORT\t[::1]:5173\t7\t/home/v/code/blog\tnode /home/v/code/blog/node_modules/.bin/vite",
            "PORT\t127.0.0.1:5173\t7\t/home/v/code/blog\tnode /home/v/code/blog/node_modules/.bin/vite",
            "PORT\t127.0.0.53%lo:53\t\t\t",
            "PORT\t192.0.2.20:8801\t9\t/home/v\tpython3 -m http.server 8801 --bind 192.0.2.20",
            "noise"
        ])
        XCTAssertEqual(ports.map(\.port), [5173, 8801, 8888, 22, 53])
        let vite = ports[0]
        XCTAssertEqual(vite.pid, 7)
        XCTAssertEqual(vite.directory, "~/code/blog")
        XCTAssertEqual(vite.shortCommand, "node vite")
        XCTAssertEqual(vite.address, "127.0.0.1")
        XCTAssertEqual(ports[3].url.target, "localhost")
        XCTAssertEqual(ports[1].url.target, "192.0.2.20")
        XCTAssertEqual(ports[1].directory, "~")
        XCTAssertEqual(ports[2].shortCommand, "python3 jupyter-lab --no-browser")
        XCTAssertNil(ports[3].pid)
        XCTAssertEqual(ports[4].address, "127.0.0.53")
    }

    func testMacAppPathsWithSpacesShortenToTheProgram() {
        let code = ListeningPort(port: 1, address: "127.0.0.1", pid: 1, command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper " +
            "(Plugin).app/Contents/MacOS/Code Helper (Plugin) /Users/z/.vscode/server.js --node-ipc", directory: "/")
        XCTAssertEqual(code.shortCommand, "Code Helper (Plugin) server.js --node-ipc")
        XCTAssertEqual(ListeningPort(port: 1, address: "", pid: 1, command: "node /a/b/vite /srv/", directory: "/").shortCommand, "node vite /srv/")
    }

    func testLeavesOutEphemeralPorts() {
        XCTAssertEqual(ListeningPort.parse(["PORT\t127.0.0.1:64725\t9\t/\tCode Helper", "PORT\t*:3000\t9\t/\tnode"]).map(\.port), [3000])
    }

    func testIpv6OnlyListenersAreReachedOverIpv6() {
        let ports = ListeningPort.parse(["PORT\t[::1]:3000\t5\t/srv\tnode server.js"])
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports.first?.url.target, "::1")
        XCTAssertEqual(ports.first?.url.display, "[::1]:3000")
    }

    func testParsesLoopbackPagesOnly() {
        XCTAssertEqual(LoopbackUrl.parse("http://localhost:5173/"), LoopbackUrl(host: "localhost", port: 5173, rest: "/"))
        XCTAssertEqual(LoopbackUrl.parse("http://LOCALHOST:5173"), LoopbackUrl(host: "localhost", port: 5173, rest: "/"))
        XCTAssertEqual(LoopbackUrl.parse("http://127.0.0.1:8000/docs?x=1#top"), LoopbackUrl(host: "127.0.0.1", port: 8000, rest: "/docs?x=1#top"))
        XCTAssertEqual(LoopbackUrl.parse("http://0.0.0.0"), LoopbackUrl(host: "0.0.0.0", port: 80, rest: "/"))
        XCTAssertEqual(LoopbackUrl.parse("http://[::1]:3000/")?.target, "::1")
        XCTAssertEqual(LoopbackUrl.parse("http://0.0.0.0:3000/")?.target, "localhost")
        XCTAssertNil(LoopbackUrl.parse("https://localhost:5173/"))
        XCTAssertNil(LoopbackUrl.parse("http://example.com:5173/"))
        XCTAssertNil(LoopbackUrl.parse("http://localhost.example.com/"))
        XCTAssertNil(LoopbackUrl.parse("http://localhost:99999/"))
    }

    func testMapsPagesThroughTheTunnelAndBack() throws {
        let url = try XCTUnwrap(LoopbackUrl.parse("http://localhost:5173/posts/1"))
        XCTAssertEqual(url.through(41000), "http://localhost:41000/posts/1")
        XCTAssertEqual(LoopbackUrl.parse("http://127.0.0.1:8000")?.through(41000), "http://127.0.0.1:41000/")
        XCTAssertEqual(url.display, "localhost:5173/posts/1")
        XCTAssertEqual(LoopbackUrl(host: "localhost", port: 5173, rest: "/").display, "localhost:5173")
        XCTAssertEqual(LoopbackUrl.fromTunnel("http://localhost:41000/about", localPort: 41000, port: 5173), LoopbackUrl(host: "localhost", port: 5173, rest: "/about"))
        XCTAssertNil(LoopbackUrl.fromTunnel("https://example.com/", localPort: 41000, port: 5173))
    }

    /// The tunnel listens on 127.0.0.1 alone: other loopback addresses are asked for there, and shown as the server's.
    func testOtherLoopbackAddressesGoThroughTheTunnelsOwn() throws {
        let url = try XCTUnwrap(LoopbackUrl.parse("http://127.0.0.2:3000/app"))
        XCTAssertEqual(url.target, "127.0.0.2")
        XCTAssertEqual(url.through(41000), "http://127.0.0.1:41000/app")
        XCTAssertEqual(LoopbackUrl.fromTunnel("http://127.0.0.1:41000/app/x", localPort: 41000, port: 3000, host: url.host),
                       LoopbackUrl(host: "127.0.0.2", port: 3000, rest: "/app/x"))
        XCTAssertEqual(LoopbackUrl.fromTunnel("http://localhost:41000/", localPort: 41000, port: 3000, host: url.host),
                       LoopbackUrl(host: "localhost", port: 3000, rest: "/"))
        XCTAssertEqual(LoopbackUrl.fromTunnel("http://localhost:41000/", localPort: 41000, port: 3000, host: "[::1]"),
                       LoopbackUrl(host: "[::1]", port: 3000, rest: "/"))
        let resolver = ListeningPort(port: 53, address: "127.0.0.53", pid: nil, command: "", directory: "")
        XCTAssertEqual(resolver.url.through(41000), "http://127.0.0.1:41000/")
        XCTAssertEqual(resolver.url.target, "127.0.0.53")
    }

    /// The script on this machine's own shell lists a port this test listens on, with this process as its owner.
    func testScriptFindsAListenerHere() throws {
        // Below the ephemeral range, which the list leaves out.
        var listener: Int32 = -1, port = 0
        for preferred in (20000..<30000).shuffled().prefix(50) {
            var bound: Int32 = 0
            let fd = roam_listen_loopback(Int32(preferred), &bound)
            if fd >= 0 && Int(bound) == preferred { listener = fd; port = preferred; break }
            roam_socket_close(fd)
        }
        try XCTSkipUnless(listener >= 0, "no free port")
        defer { roam_socket_close(listener) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ListeningPort.script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "neither ss nor lsof")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let found = try XCTUnwrap(ListeningPort.parse(lines).first { $0.port == port }, lines.joined(separator: "\n"))
        XCTAssertEqual(found.pid, Int(ProcessInfo.processInfo.processIdentifier))
    }
}
