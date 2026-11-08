#if canImport(CoreMedia)
import CoreMedia

public enum DesktopSampleBuffer {
    public static func make(_ avcc: [UInt8], format: CMFormatDescription, frame: Int64) -> CMSampleBuffer? {
        guard !avcc.isEmpty else { return nil }
        // CoreMedia allocates and owns the bytes until the final sample/block reference dies.
        // The same helper serves live presentation and asynchronous snapshot decompression.
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}
#endif
