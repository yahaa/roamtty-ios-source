import Foundation
import XCTest
@testable import RoamttyCore

final class RemoteFoldersTests: XCTestCase {
    func testDetectedPluginsChooseNewSessionModeWithoutChangingSavedPreference() {
        var host = Host(mode: .tmux)
        XCTAssertEqual(host.newSessionMode, .tmux)
        host.plugins = []
        XCTAssertEqual(host.newSessionMode, .shell)
        XCTAssertEqual(host.mode, .tmux)
        host.mode = .shell; host.plugins = ["mosh", "tmux"]
        XCTAssertEqual(host.newSessionMode, .tmux)
        host.plugins = nil
        XCTAssertEqual(host.newSessionMode, .shell)
    }

    func testParserRejectsMalformedRootsAndUnsafeChildNames() throws {
        XCTAssertNil(RemoteFolders.parse("not-absolute\n/tmp\nchild\n"))
        XCTAssertNil(RemoteFolders.parse("/home/user\n/tmp\u{1b}\nchild\n"))
        XCTAssertNil(RemoteFolders.parse("/home/user\n"))
        let listing = try XCTUnwrap(RemoteFolders.parse("/home/user/\n/home/user/work\nzeta\nAlpha\nAlpha\n..\n.\n*\na/b\nbad\u{7f}\n"))
        XCTAssertEqual(listing.home, "/home/user")
        XCTAssertEqual(listing.display, "~/work")
        XCTAssertEqual(listing.folders, ["Alpha", "zeta"])
        XCTAssertEqual(listing.directory.entries.map(\.path), ["/home/user/work/Alpha", "/home/user/work/zeta"])
        XCTAssertEqual(RemoteFolders.displayPath("/home/user2", home: "/home/user"), "/home/user2")
        XCTAssertEqual(RemoteFolders.displayPath("/", home: "/"), "/")
    }

    #if os(Linux) || os(macOS)
    func testActualPOSIXShellListsLiteralFoldersAndRejectsMissingPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-folders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["中文 ' $(touch injected) folder", "nested", ".hidden", "unsafe\nname"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("file".utf8).write(to: root.appendingPathComponent("ordinary.txt"))
        let result = try execute(RemoteFolders.script(root.path), workingDirectory: root)
        XCTAssertEqual(result.status, 0)
        let parsed = try XCTUnwrap(RemoteFolders.parse(result.output))
        // Darwin's URL normalizer collapses /private/var to /var even after
        // resolving links, while the remote shell correctly emits pwd -P.
        let physicalPath = try execute("/bin/pwd -P", workingDirectory: root).output.trimmingCharacters(in: .newlines)
        XCTAssertEqual(parsed.path, physicalPath)
        XCTAssertEqual(Set(parsed.folders), ["中文 ' $(touch injected) folder", "nested"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        XCTAssertEqual(try execute(RemoteFolders.script("nested"), workingDirectory: root).status, 0)
        XCTAssertNotEqual(try execute(RemoteFolders.script(root.path + "/missing"), workingDirectory: root).status, 0)
        XCTAssertThrowsError(try RemoteFolders.script("/tmp/invalid\npath"))
    }

    func testFolderEnumerationIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-folders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<505 { try FileManager.default.createDirectory(at: root.appendingPathComponent(String(format: "entry-%03d", index)), withIntermediateDirectories: false) }
        let result = try execute(RemoteFolders.script(root.path), workingDirectory: root)
        XCTAssertEqual(result.status, 0)
        let parsed = try XCTUnwrap(RemoteFolders.parse(result.output))
        XCTAssertEqual(parsed.folders.count, 500)
    }

    private func execute(_ script: String, workingDirectory: URL) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
    #endif
}
