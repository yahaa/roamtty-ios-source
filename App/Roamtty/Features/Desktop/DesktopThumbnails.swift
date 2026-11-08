import SwiftUI
import UIKit

struct DesktopPicture {
    let image: UIImage
    let frosted: UIImage
}

/// Last useful desktop frame, persisted independently of the live connection. All file operations
/// share a serial queue, so deleting a host cannot race an earlier queued save into recreating it.
@MainActor final class DesktopThumbnails: ObservableObject {
    @Published private(set) var images: [String: DesktopPicture] = [:]
    private var loaded = Set<String>()
    private var generations: [String: Int] = [:]
    private let io = DispatchQueue(label: "desktop-thumbnails", qos: .utility)
    private let folder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] ?? "Roamtty"
        folder = base.appendingPathComponent(name).appendingPathComponent("desktop-thumbs")
    }
    private func url(_ id: String) -> URL {
        // Encoding, rather than replacing path characters, also avoids collisions between host IDs.
        folder.appendingPathComponent(id.utf8.map { String(format: "%02x", $0) }.joined() + ".jpg")
    }
    func load(_ id: String) {
        guard loaded.insert(id).inserted else { return }
        let file = url(id), generation = generations[id, default: 0]
        io.async {
            let image = UIImage(contentsOfFile: file.path).map { DesktopPicture(image: $0, frosted: Self.frosted($0)) }
            Task { @MainActor in
                guard self.generations[id, default: 0] == generation else { return }
                if self.images[id] == nil { self.images[id] = image }
            }
        }
    }
    func save(_ image: UIImage, for id: String) {
        let file = url(id), folder = folder, generation = generations[id, default: 0]
        io.async {
            guard let thumbnail = Self.thumbnail(image), let data = thumbnail.jpegData(compressionQuality: 0.82) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                let picture = DesktopPicture(image: thumbnail, frosted: Self.frosted(thumbnail))
                Task { @MainActor in
                    guard self.generations[id, default: 0] == generation else { return }
                    self.images[id] = picture
                }
            } catch { /* Best effort: keep the last successful picture. */ }
        }
    }
    func remove(_ id: String) {
        generations[id, default: 0] += 1
        images[id] = nil
        loaded.remove(id)
        let file = url(id)
        io.async { try? FileManager.default.removeItem(at: file) }
    }
    /// Android's frosted copy: 48 pixels wide, two separable radius-2 box blurs.
    nonisolated private static func frosted(_ image: UIImage) -> UIImage {
        let width = 48, height = max(1, Int(image.size.height * 48 / image.size.width))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cg = image.cgImage else { return image }
        pixels.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap)
            ctx?.interpolationQuality = .medium
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for _ in 0..<2 {
            for horizontal in [true, false] {
                let source = pixels
                for y in 0..<height { for x in 0..<width {
                    let position = horizontal ? x : y, length = horizontal ? width : height
                    let range = max(0, position - 2)...min(length - 1, position + 2)
                    for channel in 0..<3 {
                        var sum = 0
                        for k in range { sum += Int(source[((horizontal ? y : k) * width + (horizontal ? k : x)) * 4 + channel]) }
                        pixels[(y * width + x) * 4 + channel] = UInt8(sum / range.count)
                    }
                    pixels[(y * width + x) * 4 + 3] = 255
                } }
            }
        }
        return pixels.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap)
            return ctx?.makeImage().map { UIImage(cgImage: $0) } ?? image
        }
    }

    nonisolated private static func thumbnail(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        guard let cg = sample.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let useful = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                      bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return stride(from: 0, to: bytes.count, by: 4).contains { i in
                bytes[i + 3] > 16 && max(bytes[i], bytes[i + 1], bytes[i + 2]) > 12
            }
        }
        guard useful else { return nil }
        let width = min(640, image.size.width)
        let size = CGSize(width: width, height: width * image.size.height / image.size.width)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
