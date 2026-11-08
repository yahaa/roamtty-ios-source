import SwiftUI
import UIKit
import ImageIO
import RoamttyCore
import RoamttyTransport

/// A shared handle, never a UIImage in SwiftUI state/value copies. All UIKit references
/// are registered here and cleared synchronously before the pool releases its budget.
@MainActor final class MarkdownImageDisplay: BudgetedImageResource {
    private var image: UIImage?
    private let views = NSHashTable<UIImageView>.weakObjects()
    let pixelSize: CGSize
    let decodedByteCount: Int

    init(_ bitmap: CGImage) {
        image = UIImage(cgImage: bitmap)
        pixelSize = CGSize(width: bitmap.width, height: bitmap.height)
        decodedByteCount = bitmap.bytesPerRow * bitmap.height
    }
    func attach(_ view: UIImageView) { views.add(view); view.image = image }
    func detach(_ view: UIImageView) { view.image = nil; view.layer.contents = nil; views.remove(view) }
    func discard() {
        for view in views.allObjects { view.image = nil; view.layer.contents = nil }
        views.removeAllObjects()
        image = nil
    }
}

struct MarkdownImageView: UIViewRepresentable {
    let display: MarkdownImageDisplay
    let label: String
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.accessibilityLabel = label
        if context.coordinator.display !== display { context.coordinator.display?.detach(view) }
        context.coordinator.display = display
        display.attach(view)
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.display?.detach(view); coordinator.display = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var display: MarkdownImageDisplay? }
}

@MainActor private enum MarkdownImagePipeline {
    struct Key: Hashable { let connection: UUID; let path: String }
    static let pool = BoundedImagePool<Key, MarkdownImageDisplay>()
    // Weak object keys avoid retaining SSH sessions or credentials after demand finishes.
    // A UUID (rather than a bare address) also prevents an allocator-reused address hit.
    static let identities = NSMapTable<SSHConnection, NSUUID>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    static func key(connection: SSHConnection, path: String) -> Key {
        let id: UUID
        if let existing = identities.object(forKey: connection) { id = existing as UUID } else { id = UUID(); identities.setObject(id as NSUUID, forKey: connection) }
        return Key(connection: id, path: path)
    }
    static func validate(model: AppModel, target: RemoteConnectionTarget, connection: SSHConnection) throws {
        try model.validate(target)
        if case .host(let id) = target {
            guard model.connections[id] === connection, connection.isConnected else { throw CancellationError() }
        }
    }
}

/// Only a visible row owns a demand. Generation checks also guard connection acquisition,
/// which can outlive SwiftUI cancellation while an authentication prompt is being answered.
@MainActor final class MarkdownImageDemand: ObservableObject {
    @Published private(set) var display: MarkdownImageDisplay?
    @Published private(set) var pixelSize: CGSize?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var source: String?

    deinit {
        task?.cancel()
        if let token { Task { @MainActor in MarkdownImagePipeline.pool.release(token) } }
    }

    func start(model: AppModel, target: RemoteConnectionTarget, path: String) {
        stop()
        if source != path { source = path; pixelSize = nil }
        let current = generation
        task = Task { [weak self, weak model] in
            guard let model else { return }
            defer { if self?.generation == current { self?.task = nil } }
            do {
                let ssh = try await model.connection(for: target)
                try Task.checkCancellation()
                try MarkdownImagePipeline.validate(model: model, target: target, connection: ssh)
                guard let self, self.generation == current else { return }
                let key = MarkdownImagePipeline.key(connection: ssh, path: path)
                self.token = MarkdownImagePipeline.pool.request(key, load: {
                    let cancellation = TransferCancellation()
                    return try await withTaskCancellationHandler(operation: {
                        // A single awaited work item owns fetch + decode, so cancellation
                        // cannot return a slot while synchronous ImageIO is still running.
                        let bitmap = try await performInBackground {
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            let file = try ssh.readFile(path, maxBytes: imagePreviewBytes, cancellation: cancellation)
                            guard !file.truncated, !cancellation.isCancelled else { throw CancellationError() }
                            return try decodeMarkdownBitmap(file.data)
                        }
                        try Task.checkCancellation()
                        return MarkdownImageDisplay(bitmap)
                    }, onCancel: { cancellation.cancel() })
                }, onLoad: { [weak self, weak model, weak ssh] result in
                    guard let self, self.generation == current else { return }
                    guard let model, let ssh,
                          (try? MarkdownImagePipeline.validate(model: model, target: target, connection: ssh)) != nil else {
                        self.stop(); return
                    }
                    self.display = result
                    if let result { self.pixelSize = result.pixelSize }
                })
            } catch { }
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        // The display handle can remain in an old SwiftUI value, but release clears its
        // underlying pixels (including attached UIImageViews) when the last lease ends.
        display = nil
        if let token { MarkdownImagePipeline.pool.release(token) }
        token = nil
    }
}

/// Output is explicitly 8-bit RGBA with a known stride, even for HDR/high-bit-depth inputs.
/// The 32 MiB pool includes retained outputs and 16 MiB reservations for each active job.
/// Outside that budget, at most two jobs hold <=8 MiB encoded data plus an ImageIO thumbnail,
/// a normalization context, and ImageIO's internal scratch space. CoreAnimation may retain
/// a previous display surface until its next commit; this is not a whole-process RSS cap.
private func decodeMarkdownBitmap(_ data: Data) throws -> CGImage {
    try autoreleasepool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0, thumbnail.width <= 2048, thumbnail.height <= 2048,
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                      bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RoamError.invalid("Image cannot be previewed")
        }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let bitmap = context.makeImage(), bitmap.bytesPerRow * bitmap.height <= 16 * 1024 * 1024 else {
            throw RoamError.invalid("Image cannot be previewed")
        }
        return bitmap
    }
}
