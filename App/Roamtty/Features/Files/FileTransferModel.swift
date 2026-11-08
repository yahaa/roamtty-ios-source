import Foundation
import Combine
import SwiftUI
import PhotosUI
import RoamttyCore
import RoamttyTransport

enum TransferState: String { case running, complete, failed, cancelled }
struct PendingSharedUpload: Identifiable {
    let id = UUID()
    let hostID: String
    let urls: [URL]
    var ready = false
    var claimed = false
}
struct TransferJob: Identifiable {
    let id = UUID()
    let name: String
    let uploading: Bool
    let started = Date()
    var bytes: Int64 = 0
    var total: Int64?
    var state = TransferState.running
    var message: String?
    var localURL: URL?
    var remotePath: String
    var pendingInsertion: String?
    var fraction: Double? { guard let total, total > 0 else { return nil }; return min(1, Double(bytes) / Double(total)) }
    var speed: String { formattedBytes(Int64(Double(bytes) / max(1, Date().timeIntervalSince(started)))) + "/s" }
}
/// Hands a transfer's progress to the main thread without holding the transfer up. A transfer reports every chunk
/// it reads or writes (up to 64 KiB), and its worker used to wait for the main thread each time. It now leaves the
/// latest numbers here and queues at most one hand-over, so the screens get them at most once per main-loop turn.
final class TransferProgressRelay {
    private let lock = NSLock()
    private var latest: (bytes: Int64, total: Int64?)?
    private let apply: (Int64, Int64?) -> Void
    init(_ apply: @escaping (Int64, Int64?) -> Void) { self.apply = apply }
    func send(_ bytes: Int64, _ total: Int64?) {
        lock.lock(); let queued = latest != nil; latest = (bytes, total); lock.unlock()
        guard !queued else { return }
        DispatchQueue.main.async { [self] in
            lock.lock(); let value = latest; latest = nil; lock.unlock()
            if let value { apply(value.bytes, value.total) }
        }
    }
}
@MainActor final class FileTransferModel: ObservableObject {
    private final class InsertionTarget {
        weak var runtime: SessionRuntime?
        let connectionTarget: RemoteConnectionTarget
        init(_ runtime: SessionRuntime, connectionTarget: RemoteConnectionTarget) { self.runtime = runtime; self.connectionTarget = connectionTarget }
    }
    @Published var jobs: [TransferJob] = []
    @Published private(set) var pendingSharedUploads: [PendingSharedUpload] = []
    // Claimed requests remain here until their confirmation closes, including while backgrounded.
    var pendingUploadURLs: [URL] { pendingSharedUploads.flatMap(\.urls) }
    private(set) var activeUploadURLs = Set<URL>()
    private var tokens: [UUID: TransferCancellation] = [:]
    private var cancellations = Set<UUID>()
    private var reservedDestinations = Set<String>()
    private var insertionTargets: [UUID: InsertionTarget] = [:]
    func prepareSharedUpload(_ urls: [URL], hostID: String) -> UUID? {
        let existing = Set(pendingUploadURLs).union(activeUploadURLs)
        var seen = existing
        let selected = urls.filter { seen.insert($0).inserted }
        guard !selected.isEmpty else { return nil }
        let request = PendingSharedUpload(hostID: hostID, urls: selected)
        pendingSharedUploads.append(request)
        return request.id
    }
    /// Called only by the chooser's onDismiss, after its presentation has ended.
    func releaseSharedUpload(_ id: UUID) -> String? {
        guard let index = pendingSharedUploads.firstIndex(where: { $0.id == id }) else { return nil }
        pendingSharedUploads[index].ready = true
        return pendingSharedUploads[index].hostID
    }
    func claimSharedUpload(hostID: String) -> PendingSharedUpload? {
        guard let index = pendingSharedUploads.firstIndex(where: { $0.hostID == hostID && $0.ready && !$0.claimed }) else { return nil }
        pendingSharedUploads[index].claimed = true
        return pendingSharedUploads[index]
    }
    @discardableResult func finishSharedUpload(_ id: UUID) -> [URL] {
        guard let index = pendingSharedUploads.firstIndex(where: { $0.id == id }) else { return [] }
        return pendingSharedUploads.remove(at: index).urls
    }
    func cancel(_ job: TransferJob) { cancellations.insert(job.id); tokens[job.id]?.cancel(); update(job.id) { $0.state = .cancelled } }
    func clearFinished() {
        for job in jobs where job.state != .running { insertionTargets.removeValue(forKey: job.id); cancellations.remove(job.id) }
        jobs.removeAll { $0.state != .running }
    }
    private func update(_ id: UUID, _ apply: (inout TransferJob) -> Void) { if let index = jobs.firstIndex(where: { $0.id == id }) { apply(&jobs[index]) } }
    /// Where a job's transfer reports its bytes and total.
    private func progressRelay(for id: UUID) -> TransferProgressRelay { TransferProgressRelay { bytes, total in self.update(id) { $0.bytes = bytes; $0.total = total } } }
    func upload(_ url: URL, directory: String, host: Host, model: AppModel, insert: Bool = false, targetSessionID: String? = nil, name: String? = nil,
                targetRuntime: SessionRuntime? = nil, connectionTarget: RemoteConnectionTarget? = nil) {
        let connectionTarget = connectionTarget ?? targetRuntime.map { RemoteConnectionTarget.session($0) }
            ?? model.connectionTarget(hostID: host.id, sessionID: targetSessionID)
        let remoteName = name ?? url.lastPathComponent
        guard isSafeRemoteEntryName(remoteName), isValidRemoteDirectory(directory) else { model.error = model.text("无效的上传路径", "Invalid upload path"); return }
        activeUploadURLs.insert(url)
        let target = joinRemotePath(directory: directory, name: remoteName)
        let job = TransferJob(name: remoteName, uploading: true, remotePath: target)
        if insert, let runtime = connectionTarget.runtime, runtime.host.id == host.id { insertionTargets[job.id] = InsertionTarget(runtime, connectionTarget: connectionTarget) }
        let cancellation = TransferCancellation()
        tokens[job.id] = cancellation
        jobs.insert(job, at: 0)
        Task {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() }; tokens.removeValue(forKey: job.id); activeUploadURLs.remove(url) }
            do {
                guard !cancellation.isCancelled else { throw RoamError.cancelled }
                let ssh = try await model.connection(for: connectionTarget)
                guard !cancellation.isCancelled else { throw RoamError.cancelled }
                let progress = progressRelay(for: job.id)
                try await performInBackground {
                    var sent: Int64 = 0
                    // One SFTP session for the whole tree, not one per file and folder.
                    try ssh.withSFTPSession(cancellation: cancellation) { sftp in
                        try Self.uploadTree(url: url, path: target, sftp: sftp, count: 0, cancellation: cancellation) { bytes, total in
                            progress.send(sent + bytes, total.map { sent + $0 })
                        } completed: { bytes in sent += bytes }
                    }
                }
                guard !cancellations.contains(job.id) else { return }
                update(job.id) { $0.state = .complete }
                do {
                    try await SharedInbox.acknowledge([url])
                    model.incomingFiles.removeAll { $0 == url }
                } catch { update(job.id) { $0.message = model.text("上传已完成，但共享队列未能更新：", "Upload completed, but the shared queue could not be updated: ") + error.localizedDescription } }
                if insert, let text = terminalPathText(target) { update(job.id) { $0.pendingInsertion = text }; insertPath(job.id, model: model) }
            } catch { if !cancellations.contains(job.id) { update(job.id) { $0.state = .failed; $0.message = error.localizedDescription } } }
        }
    }
    func canInsertPath(_ job: TransferJob, model: AppModel) -> Bool {
        guard job.state == .complete, job.pendingInsertion != nil, let target = insertionTargets[job.id], target.runtime != nil else { return false }
        do { try model.validate(target.connectionTarget); return true } catch { return false }
    }
    @discardableResult func insertPath(_ id: UUID, model: AppModel) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), let input = job.pendingInsertion else { return false }
        guard canInsertPath(job, model: model), let runtime = insertionTargets[id]?.runtime, runtime.pasteText(input) else { return false }
        update(id) { $0.pendingInsertion = nil }
        insertionTargets.removeValue(forKey: id)
        return true
    }
    /// Returns the queued jobs so the caller can follow them until their paths are in the terminal.
    @discardableResult func uploadImages(_ images: [PhotosPickerItem], runtime: SessionRuntime, model: AppModel, connectionTarget: RemoteConnectionTarget? = nil) -> [UUID] {
        let connectionTarget = connectionTarget ?? .session(runtime)
        let queued = images.prefix(9).map { item -> (PhotosPickerItem, TransferJob, TransferCancellation) in
            let path = TerminalAttachment.remotePNGPath()
            let job = TransferJob(name: (path as NSString).lastPathComponent, uploading: true, remotePath: path)
            let token = TransferCancellation()
            tokens[job.id] = token; insertionTargets[job.id] = InsertionTarget(runtime, connectionTarget: connectionTarget); jobs.insert(job, at: 0)
            return (item, job, token)
        }
        // Decode and upload sequentially so a batch never holds nine decoded images in memory.
        Task {
            for (item, job, token) in queued {
                var source: PickedTerminalImage?
                defer { source?.remove(); tokens.removeValue(forKey: job.id); if jobs.first(where: { $0.id == job.id })?.pendingInsertion == nil { insertionTargets.removeValue(forKey: job.id) } }
                do {
                    guard !token.isCancelled else { continue }
                    try model.validate(connectionTarget)
                    guard let picked = try await item.loadTransferable(type: PickedTerminalImage.self) else { throw RoamError.invalid(model.text("无法读取所选图片", "Unable to read the selected image")) }
                    source = picked
                    guard !token.isCancelled else { continue }
                    let png = try await performInBackground { try picked.png(cancellation: token) }
                    guard !token.isCancelled else { continue }
                    let ssh = try await model.connection(for: connectionTarget)
                    guard !token.isCancelled else { continue }
                    let progress = progressRelay(for: job.id)
                    try await performInBackground { try ssh.upload(png, to: job.remotePath, progress: progress.send, cancellation: token) }
                    guard !token.isCancelled else { continue }
                    let input = try TerminalAttachment.imageInput(job.remotePath, bracketed: false)
                    update(job.id) { $0.state = .complete; $0.pendingInsertion = input }
                    insertPath(job.id, model: model)
                } catch { if !token.isCancelled { update(job.id) { $0.state = .failed; $0.message = error.localizedDescription } } }
            }
        }
        return queued.map(\.1.id)
    }
    func download(_ entry: RemoteEntry, host: Host, model: AppModel, name: String? = nil, connectionTarget: RemoteConnectionTarget? = nil) {
        let connectionTarget = connectionTarget ?? .host(host.id)
        let job = TransferJob(name: name ?? entry.name, uploading: false, remotePath: entry.path)
        let cancellation = TransferCancellation()
        tokens[job.id] = cancellation
        jobs.insert(job, at: 0)
        Task {
            var scoped: URL?
            var directoryDownload: LocalDownloadDirectory?
            var reservedPath: String?
            defer { directoryDownload?.discard(); scoped?.stopAccessingSecurityScopedResource(); tokens.removeValue(forKey: job.id); if let reservedPath { reservedDestinations.remove(reservedPath) } }
            do {
                guard !cancellation.isCancelled else { throw RoamError.cancelled }
                let ssh = try await model.connection(for: connectionTarget)
                guard !cancellation.isCancelled else { throw RoamError.cancelled }
                let folder: URL
                if let bookmark = model.settings.downloadBookmark {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale, url.startAccessingSecurityScopedResource() else {
                        throw RoamError.invalid(model.text("下载目录授权已过期，请在设置中重新选择", "Download folder access expired. Choose it again in Settings."))
                    }
                    scoped = url; folder = url
                } else {
                    folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Downloads", isDirectory: true)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = Self.availableURL(folder.appendingPathComponent(name ?? entry.name), reserved: reservedDestinations)
                reservedDestinations.insert(destination.path); reservedPath = destination.path
                if entry.isDirectory { directoryDownload = try LocalDownloadDirectory(in: folder) }
                let workingURL = directoryDownload?.directoryURL ?? destination
                let progress = progressRelay(for: job.id)
                try await performInBackground {
                    var received: Int64 = 0
                    try ssh.withSFTPSession(cancellation: cancellation) { sftp in
                        try Self.downloadTree(entry: entry, destination: workingURL, sftp: sftp, depth: 0, cancellation: cancellation) { bytes, total in
                            progress.send(received + bytes, entry.isDirectory ? nil : total)
                        } completed: { bytes in received += bytes }
                    }
                }
                guard !cancellation.isCancelled else { return }
                // Publication and the complete state run together on MainActor, so Cancel cannot
                // interleave after publication and delete a completed destination.
                let completedURL = try directoryDownload?.publish(as: destination.lastPathComponent, excluding: reservedDestinations.subtracting([destination.path])) ?? destination
                update(job.id) { $0.state = .complete; $0.localURL = completedURL }
            } catch { if !cancellations.contains(job.id) { update(job.id) { $0.state = .failed; $0.message = error.localizedDescription } } }
        }
    }
    nonisolated private static func availableURL(_ url: URL, reserved: Set<String>) -> URL {
        // Chosen Files-provider destinations may be case-insensitive even though native iOS storage is not.
        let reserved = Set(reserved.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        func available(_ candidate: URL) -> Bool { !reserved.contains(candidate.path.precomposedStringWithCanonicalMapping.lowercased()) && !FileManager.default.fileExists(atPath: candidate.path) }
        if available(url) { return url }
        for index in 1...9999 {
            let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
            let candidate = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (\(index))" + suffix)
            if available(candidate) { return candidate }
        }
        return url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    }
    nonisolated private static func uploadTree(url: URL, path: String, sftp: SFTPSession, count: Int, cancellation: TransferCancellation,
                                               progress: @escaping (Int64, Int64?) -> Void, completed: (Int64) -> Void) throws {
        guard !cancellation.isCancelled else { throw RoamError.cancelled }
        guard count < 64, isSafeRemoteEntryName(url.lastPathComponent) else { throw RoamError.invalid("Invalid or deeply nested upload path") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw RoamError.invalid("Symbolic links are not uploaded recursively") }
        if values.isDirectory == true {
            do { try sftp.createDirectory(path) } catch {
                // Existing upload folders may be reused, but a regular file or inaccessible path cannot.
                guard !cancellation.isCancelled else { throw RoamError.cancelled }
                _ = try sftp.listDirectory(path)
            }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try uploadTree(url: child, path: joinRemotePath(directory: path, name: child.lastPathComponent), sftp: sftp, count: count + 1,
                    cancellation: cancellation, progress: progress, completed: completed)
            }
        } else { try sftp.upload(url, to: path, progress: progress); completed(Int64(values.fileSize ?? 0)) }
    }
    nonisolated private static func downloadTree(entry: RemoteEntry, destination: URL, sftp: SFTPSession, depth: Int,
                                                 cancellation: TransferCancellation, progress: @escaping (Int64, Int64?) -> Void, completed: (Int64) -> Void) throws {
        guard !cancellation.isCancelled else { throw RoamError.cancelled }
        guard depth < 64, isSafeRemoteEntryName(entry.name) else { throw RoamError.invalid("Invalid or deeply nested remote path") }
        if entry.isDirectory {
            guard !entry.isSymlink else { throw RoamError.invalid("Symbolic-link directories are not downloaded recursively") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let listing = try sftp.listDirectory(entry.path)
            guard listing.unreadableNames == 0 else { throw RoamError.invalid("文件夹中有无法识别的文件名（非 UTF-8），无法完整下载 / The folder holds names that are not UTF-8, so it can't be downloaded whole") }
            for child in listing.entries {
                try downloadTree(entry: child, destination: destination.appendingPathComponent(child.name), sftp: sftp, depth: depth + 1,
                    cancellation: cancellation, progress: progress, completed: completed)
            }
        } else { try sftp.download(entry.path, to: destination, progress: progress); completed(entry.size ?? 0) }
    }
}
