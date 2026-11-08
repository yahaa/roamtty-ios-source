import Foundation
import CNative
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One directory download owns only its private sibling stage until it publishes.
/// Publish after the transfer has completed and cancellation has been checked.
/// Calls for one transaction must be serialized; separate transactions may publish concurrently.
public final class LocalDownloadDirectory {
    public let directoryURL: URL
    private let parent: URL
    private var stage: URL?

    public init(in parent: URL) throws {
        self.parent = parent
        let stage = parent.appendingPathComponent(".roamtty-" + UUID().uuidString + ".download", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.stage = stage
        directoryURL = stage.appendingPathComponent("contents", isDirectory: true)
    }

    deinit { discard() }

    public func publish(as name: String, excluding reservedPaths: Set<String> = []) throws -> URL {
        guard stage != nil else { throw RoamError.cancelled }
        guard isSafeRemoteEntryName(name) else { throw RoamError.invalid("Invalid download name") }
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RoamError.invalid("Incomplete directory download") }
        let reserved = Set(reservedPaths.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        for index in 0...9_999 {
            let candidate = parent.appendingPathComponent(index == 0 ? name : name + " (\(index))", isDirectory: true)
            if reserved.contains(candidate.path.precomposedStringWithCanonicalMapping.lowercased()) { continue }
            let error = directoryURL.path.withCString { source in candidate.path.withCString { roam_move_exclusive(source, $0) } }
            if error == 0 { discard(); return candidate }
            if error == EEXIST || error == ENOTEMPTY { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: candidate.path])
        }
        throw RoamError.invalid("No available download name")
    }

    /// Never removes a final destination, including one created by another actor while downloading.
    public func discard() {
        guard let stage else { return }
        self.stage = nil
        try? FileManager.default.removeItem(at: stage)
    }
}
