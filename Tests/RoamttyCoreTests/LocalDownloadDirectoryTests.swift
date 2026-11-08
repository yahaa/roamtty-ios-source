import Foundation
import XCTest
@testable import RoamttyCore

final class LocalDownloadDirectoryTests: XCTestCase {
    func testPublicationCannotReplaceAnExistingEmptyFolder() throws {
        try withFolder { root in
            let transaction = try LocalDownloadDirectory(in: root)
            try makeContents(transaction, text: "downloaded")
            let empty = root.appendingPathComponent("report")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
            let result = try transaction.publish(as: "report")
            XCTAssertNotEqual(result, empty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
            XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("download.txt"), encoding: .utf8), "downloaded")
        }
    }

    func testPublicationPreservesDestinationCreatedDuringDownload() throws {
        try withFolder { root in
            let transaction = try LocalDownloadDirectory(in: root)
            try makeContents(transaction, text: "downloaded")
            let existing = root.appendingPathComponent("report")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            try Data("existing".utf8).write(to: existing.appendingPathComponent("keep.txt"))
            let result = try transaction.publish(as: "report")
            XCTAssertNotEqual(result, existing)
            XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("keep.txt"), encoding: .utf8), "existing")
            XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("download.txt"), encoding: .utf8), "downloaded")
            transaction.discard()
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        }
    }

    func testCancelledCleanupRemovesOnlyItsOwnStage() throws {
        try withFolder { root in
            let cancelled = try LocalDownloadDirectory(in: root)
            let running = try LocalDownloadDirectory(in: root)
            try makeContents(cancelled, text: "cancelled")
            try makeContents(running, text: "running")
            let unrelated = root.appendingPathComponent("report")
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
            cancelled.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.directoryURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try String(contentsOf: running.directoryURL.appendingPathComponent("download.txt"), encoding: .utf8), "running")
            XCTAssertThrowsError(try cancelled.publish(as: "report"))
        }
    }

    func testConcurrentPublishersCannotReplaceOrMergeEachOther() throws {
        try withFolder { root in
            let lock = NSLock()
            var completed: [URL] = [], failures: [Error] = []
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                do {
                    let transaction = try LocalDownloadDirectory(in: root)
                    try makeContents(transaction, text: "job \(index)")
                    let result = try transaction.publish(as: "report")
                    lock.lock(); completed.append(result); lock.unlock()
                } catch { lock.lock(); failures.append(error); lock.unlock() }
            }
            XCTAssertTrue(failures.isEmpty, "\(failures)")
            XCTAssertEqual(Set(completed).count, 8)
            let contents = try Set(completed.map { try String(contentsOf: $0.appendingPathComponent("download.txt"), encoding: .utf8) })
            XCTAssertEqual(contents, Set((0..<8).map { "job \($0)" }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 8)
        }
    }

    func testPublicationRejectsPathTraversalAndRespectsOtherReservations() throws {
        try withFolder { root in
            let transaction = try LocalDownloadDirectory(in: root)
            try makeContents(transaction, text: "downloaded")
            XCTAssertThrowsError(try transaction.publish(as: "../outside"))
            let result = try transaction.publish(as: "Report", excluding: [root.appendingPathComponent("report").path])
            XCTAssertNotEqual(result.lastPathComponent.lowercased(), "report")
        }
    }

    private func makeContents(_ transaction: LocalDownloadDirectory, text: String) throws {
        try FileManager.default.createDirectory(at: transaction.directoryURL, withIntermediateDirectories: false)
        try Data(text.utf8).write(to: transaction.directoryURL.appendingPathComponent("download.txt"))
    }
    private func withFolder(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
