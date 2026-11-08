#!/bin/bash
# Compile the production CoreMedia sample factory with ASan; no app/device build required.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/roamtty-sample-ownership.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_dir/main.swift" <<'SWIFT'
import Foundation
import CoreMedia

var format: CMVideoFormatDescription?
precondition(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
    codecType: kCMVideoCodecType_H264, width: 1280, height: 720, extensions: nil,
    formatDescriptionOut: &format) == noErr)
for index in 0..<128 {
    let size = 1024 * 1024
    let sample: CMSampleBuffer = autoreleasepool {
        let bytes = [UInt8](repeating: UInt8(index), count: size)
        let sample = DesktopSampleBuffer.make(bytes, format: format!, frame: Int64(index))!
        let block = CMSampleBufferGetDataBuffer(sample)!
        var data: UnsafeMutablePointer<Int8>?
        precondition(CMBlockBufferGetDataPointer(block, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &data) == noErr)
        bytes.withUnsafeBytes { precondition($0.baseAddress != UnsafeRawPointer(data), "borrowed Swift bytes") }
        return sample
    }
    let block = CMSampleBufferGetDataBuffer(sample)!
    var copied = [UInt8](repeating: 255, count: size)
    precondition(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &copied) == noErr)
    precondition(copied.allSatisfy { $0 == UInt8(index) }, "sample corrupted after Swift input released")
}
print("PASS: 128 production samples retain independent 1 MiB buffers after input release (ASan)")
SWIFT
xcrun swiftc -sanitize=address "$repo_dir/Sources/RoamttyDesktopCore/DesktopSampleBuffer.swift" "$probe_dir/main.swift" -o "$probe_dir/ownership"
"$probe_dir/ownership"
