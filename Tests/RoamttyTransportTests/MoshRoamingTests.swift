#if os(Linux) || os(macOS)
import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class MoshRoamingTests: XCTestCase {
    func testTmuxInputAfterResizeAndSourcePortChange() throws {
        try verifyTmuxInput(probe: true)
    }
    func testTmuxInputAfterResizeWithoutSourcePortChange() throws {
        try verifyTmuxInput(probe: false)
    }
    func testTmuxInputAfterResizeWithEchoEnabled() throws {
        try verifyTmuxInput(probe: false, disableEcho: false)
    }
    private func verifyTmuxInput(probe: Bool, disableEcho: Bool = true) throws {
        let serverPath = ProcessInfo.processInfo.environment["ROAMTTY_MOSH_SERVER"] ?? "/usr/bin/mosh-server"
        let tmuxPath = ProcessInfo.processInfo.environment["ROAMTTY_TMUX"] ?? "/usr/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: serverPath), FileManager.default.isExecutableFile(atPath: tmuxPath) else { throw XCTSkip("mosh-server and tmux are required") }
        let name = "roamtty-roaming-" + UUID().uuidString
        let checkpoint = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".size")
        defer { _ = try? command(tmuxPath, ["kill-session", "-t", "=" + name]); try? FileManager.default.removeItem(at: checkpoint) }
        let server = Process(); server.executableURL = URL(fileURLWithPath: serverPath)
        server.arguments = ["new", "-i", "127.0.0.1", "-p", "60001:60999", "--", "/bin/sh", "-c", RemoteCommands.tmuxAttach(name)]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C.UTF-8"; environment["LC_ALL"] = "C.UTF-8"
        environment["TERM"] = "xterm-256color"; environment["MOSH_SERVER_NETWORK_TMOUT"] = "20"
        server.environment = environment
        let announcement = Pipe(); server.standardOutput = announcement; server.standardError = announcement
        try server.run()
        var bytes = Data(); var connection: Mosh.Connect?
        while connection == nil {
            let chunk = announcement.fileHandleForReading.availableData
            if chunk.isEmpty { break }; bytes.append(chunk)
            connection = Mosh.parseConnect(String(decoding: bytes, as: UTF8.self))
        }
        let connect = try XCTUnwrap(connection)
        let transport = try MoshTransport(host: "127.0.0.1", port: connect.port, key: connect.key)
        let initial = expectation(description: "tmux output")
        let evaluated = expectation(description: "first input evaluated")
        let finished = expectation(description: "transport worker finished")
        defer { transport.close(); wait(for: [finished], timeout: 3) }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            var text = ""; var sawInitial = false; var sawEvaluated = false
            do {
                try transport.run(columns: 80, rows: 24, firstContactTimeout: 5, silenceTimeout: 15) { data in
                    text += String(decoding: data, as: UTF8.self)
                    if !sawInitial { sawInitial = true; initial.fulfill() }
                    if !sawEvaluated && text.contains("BEFORE-42") { sawEvaluated = true; evaluated.fulfill() }
                }
            } catch { if error as? RoamError != .cancelled { XCTFail("Mosh worker failed: \(error)") } }
        }
        guard XCTWaiter.wait(for: [initial], timeout: 6) == .completed else { XCTFail("No initial tmux output"); return }
        try poll {
            let result = try self.command(tmuxPath, ["list-clients", "-t", "=" + name, "-F", "#{client_tty}"])
            return result.status == 0 && !result.output.isEmpty
        }
        XCTAssertTrue(transport.write(Data(((disableEcho ? "stty -echo; " : "") + "printf 'BEFORE-%d\\n' $((40+2))\r").utf8)))
        guard XCTWaiter.wait(for: [evaluated], timeout: 6) == .completed else { XCTFail("Initial command failed"); return }
        transport.resize(columns: 91, rows: 33)
        if probe { transport.probe() }
        let ttyResult = try command(tmuxPath, ["display-message", "-p", "-t", "=" + name + ":", "#{pane_tty}"])
        let tty = String(decoding: ttyResult.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(Linux)
        let ttyFlag = "-F"
        #else
        let ttyFlag = "-f"
        #endif
        // tmux's layout metadata changes before the child PTY's kernel size.
        try poll {
            let result = try self.command("/bin/stty", [ttyFlag, tty, "size"])
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "33 91"
        }
        XCTAssertTrue(transport.write(Data(("stty size > " + RemoteCommands.shellQuote(checkpoint.path) + "\r").utf8)))
        try poll {
            guard let bytes = try? Data(contentsOf: checkpoint) else { return false }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "33 91"
        }
        XCTAssertTrue(transport.write(Data("exit\r".utf8)))
    }

    private func poll(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { if try condition() { return }; Thread.sleep(forTimeInterval: 0.02) }
        throw RoamError.timeout
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return CommandResult(output: data, status: process.terminationStatus)
    }
}
#endif
