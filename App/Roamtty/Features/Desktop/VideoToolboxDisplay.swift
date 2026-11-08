import SwiftUI
import UIKit
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage
import RoamttyDesktopCore

/// Shows H.264 frames with `AVSampleBufferDisplayLayer` (plan §8). SPS/PPS from the first keyframe
/// build the format description; later access units are enqueued as AVCC sample buffers.
/// This file is UIKit/VideoToolbox-only and is **not compiled or verified on Linux**.
final class VideoToolboxDisplay: NSObject, DesktopVideoDisplay {
    let layer = AVSampleBufferDisplayLayer()
    // All format, layer and snapshot-keyframe access is on the decoder's main executor.
    private var format: CMFormatDescription?
    private var latestKeyframe: ([UInt8], CMFormatDescription)? // accessed only on main
    private let snapshotQueue = DispatchQueue(label: "desktop-snapshot", qos: .utility)
    /// Annex-B → AVCC conversion runs here, so the main thread only enqueues finished samples.
    private let conversionQueue = DispatchQueue(label: "desktop-video-convert", qos: .userInteractive)
    /// Creating a Core Image context is costly; one serves every snapshot (it is thread-safe).
    private static let snapshotContext = CIContext()
    weak var decoder: DesktopVideoDecoder?
    var onSize: ((Int, Int) -> Void)?

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    #if DEBUG
    func showLayoutFixture() {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 1280, height: 720,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow]
        for i in 0..<4 {
            context.setFillColor(colors[i].cgColor)
            context.fill(CGRect(x: (i % 2) * 640, y: (i / 2) * 360, width: 640, height: 360))
        }
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(16)
        context.stroke(CGRect(x: 8, y: 8, width: 1264, height: 704))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        layer.enqueue(sample)
    }
    #endif

    func scheduleVideoWork(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func scheduleConversionWork(_ work: @escaping () -> Void) {
        conversionQueue.async(execute: work)
    }

    var isReadyForMoreVideo: Bool { layer.status == .failed || layer.isReadyForMoreMediaData }

    func notifyWhenReadyForVideo(_ work: @escaping () -> Void) {
        layer.requestMediaDataWhenReady(on: .main) { [weak self] in
            guard let self else { return }
            self.layer.stopRequestingMediaData()
            work()
        }
    }

    func cancelVideoReadinessNotification() { layer.stopRequestingMediaData() }

    func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8], rendered: @escaping (Int64) -> Void) {
        if layer.status == .failed { decoder?.reset(); return }
        if keyframe {
            let (s, p) = H264.spsPps(annexB, offset: offset)
            if let s, let p,
               let f = Self.makeFormat(sps: Array(H264.NAL(bytes: s, type: 7).payload),
                                       pps: Array(H264.NAL(bytes: p, type: 8).payload)) {
                format = f
                onSize?(width, height)
            } else { decoder?.reset(); return }
        }
        guard let format, !avcc.isEmpty,
              let sample = DesktopSampleBuffer.make(avcc, format: format, frame: frame) else {
            decoder?.reset(); return
        }
        if keyframe { latestKeyframe = (avcc, format) }
        layer.enqueue(sample)
        // Older iOS has no per-frame presentation callback. Measure the actual layer enqueue
        // after decoded, as an approximation of scan-out. Main/readiness wait is included
        // in receive-to-decoded latency: the decoder stamps decoded on main, once the sink is ready.
        rendered(UdpLink.monotonicUs())
    }

    func flush() {
        layer.stopRequestingMediaData()
        layer.flushAndRemoveImage()
        latestKeyframe = nil
        format = nil
    }

    /// Copy the displayed frame without rendering the AV layer into a black UIKit screenshot.
    /// Older iOS falls back to decoding one retained keyframe, only at thumbnail cadence.
    @MainActor func snapshot(_ completion: @escaping @MainActor (UIImage?) -> Void) {
        // Handed over to the snapshot queue and only read there.
        nonisolated(unsafe) let pixel: CVPixelBuffer? = {
            if #available(iOS 17.4, *) { return layer.sampleBufferRenderer.displayedPixelBuffer() }
            return nil
        }()
        let keyframe = latestKeyframe
        snapshotQueue.async {
            let buffer = pixel ?? keyframe.flatMap { Self.decodeSnapshot($0.0, format: $0.1) }
            let image = buffer.flatMap { buffer -> UIImage? in
                let ci = CIImage(cvPixelBuffer: buffer)
                return Self.snapshotContext.createCGImage(ci, from: ci.extent).map { UIImage(cgImage: $0) }
            }
            Task { @MainActor in completion(image) }
        }
    }

    private static func decodeSnapshot(_ bytes: [UInt8], format: CMFormatDescription) -> CVPixelBuffer? {
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil,
            decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        guard let sample = DesktopSampleBuffer.make(bytes, format: format, frame: 0) else { return nil }
        var result: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { result = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? result : nil
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMFormatDescription? {
        var format: CMFormatDescription?
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                let pointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                let sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        return format
    }
}

/// Hosts the controller's `AVSampleBufferDisplayLayer`.
struct DesktopVideoSurface: UIViewRepresentable {
    let display: VideoToolboxDisplay
    /// The picture's frame inside the view when zoomed or panned; nil fills the view.
    var content: CGRect?
    func makeUIView(context: Context) -> DesktopVideoHostView {
        let view = DesktopVideoHostView()
        view.attach(display)
        view.content = content
        return view
    }
    func updateUIView(_ uiView: DesktopVideoHostView, context: Context) {
        uiView.attach(display)
        uiView.content = content
    }
}

final class DesktopVideoHostView: UIView {
    private weak var display: VideoToolboxDisplay?
    var content: CGRect? {
        didSet {
            guard content != oldValue else { return }
            // UI tests read the picture's drawn size here.
            accessibilityValue = content.map { "\(Int($0.width))x\(Int($0.height))" }
            setNeedsLayout()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityIdentifier = "desktop-video-surface"
        accessibilityLabel = "Remote desktop picture"
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func attach(_ display: VideoToolboxDisplay) {
        if self.display === display { return }
        self.display?.layer.removeFromSuperlayer()
        self.display = display
        layer.addSublayer(display.layer)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Follows the fingers: no implicit layer animation.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display?.layer.frame = content ?? bounds
        CATransaction.commit()
    }
}
