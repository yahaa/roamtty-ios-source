#if canImport(CoreMedia)
import CoreMedia
import XCTest
@testable import RoamttyDesktopCore

final class DesktopSampleBufferTests: XCTestCase {
    func testSampleOwnsBytesIndependentlyOfInputAndSurvivesItsRelease() throws {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 100, height: 100, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var input: [UInt8] = [0, 0, 0, 4, 0x65, 42, 43, 44]
        let sample = try XCTUnwrap(DesktopSampleBuffer.make(input, format: XCTUnwrap(format), frame: 1))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var pointer: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: nil, dataPointerOut: &pointer), noErr)
        input.withUnsafeBytes { original in
            XCTAssertNotEqual(UnsafeRawPointer(pointer), original.baseAddress, "CoreMedia must own its storage, not borrow the Swift array")
        }
        input.removeAll()
        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 8, destination: &bytes), noErr)
        XCTAssertEqual(bytes, [0, 0, 0, 4, 0x65, 42, 43, 44])
    }
}
#endif
