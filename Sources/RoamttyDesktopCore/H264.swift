import Foundation

/// Annex-B H.264 helpers shared by the VideoToolbox path and the Linux tests.
/// Port of Android `VideoDecoder.nalUnits` (roamtty #218).
public enum H264 {
    /// One NAL unit with its start code still attached, and its type (low 5 bits of the header).
    public struct NAL: Equatable, Sendable {
        public let bytes: [UInt8]
        public let type: Int
        public init(bytes: [UInt8], type: Int) { self.bytes = bytes; self.type = type }
        public var isSPS: Bool { type == 7 }
        public var isPPS: Bool { type == 8 }
        /// Payload after the 3- or 4-byte start code.
        public var payload: ArraySlice<UInt8> {
            if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return bytes[4...] }
            if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return bytes[3...] }
            return bytes[...]
        }
    }

    /// The Annex-B NAL units of an access unit, each with its start code, and its type.
    public static func nalUnits(_ data: [UInt8], offset: Int = 0) -> [NAL] {
        let starts = startCodes(data, offset: offset)
        return starts.indices.map { n in
            let unit = starts[n]
            let end = n + 1 < starts.count ? starts[n + 1].start : data.count
            let type = unit.payload < end ? Int(data[unit.payload] & 0x1F) : 0
            return NAL(bytes: Array(data[unit.start..<end]), type: type)
        }
    }

    /// Where each NAL unit's start code (3 or 4 bytes) and payload begin. A zero before `00 00 01` belongs to the
    /// start code, so the unit before it ends one byte earlier.
    static func startCodes(_ data: [UInt8], offset: Int = 0, stopAfter: ((_ type: Int) -> Bool)? = nil) -> [(start: Int, payload: Int)] {
        guard offset < data.count else { return [] }
        return data.withUnsafeBufferPointer { bytes in
            var units: [(start: Int, payload: Int)] = []
            var i = offset
            while i + 3 <= bytes.count {
                // Only a 1 can end a start code, so most bytes are passed after one comparison.
                if bytes[i + 2] > 1 { i += 3; continue }
                if bytes[i + 2] == 1 && bytes[i + 1] == 0 && bytes[i] == 0 {
                    units.append((i > offset && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                    if let stopAfter, i + 3 < bytes.count, stopAfter(Int(bytes[i + 3] & 0x1F)) { break }
                    i += 3
                } else { i += 1 }
            }
            return units
        }
    }

    /// Length-prefixed (AVCC) form of the access unit, for `CMSampleBuffer` / VideoToolbox. One pass, one copy.
    public static func avcc(_ data: [UInt8], offset: Int = 0) -> [UInt8] {
        let units = startCodes(data, offset: offset)
        guard !units.isEmpty else { return [] }
        var out: [UInt8] = []
        // Every start code becomes a 4-byte length, so the output is at most one byte a unit longer.
        out.reserveCapacity(data.count - units[0].start + units.count)
        data.withUnsafeBufferPointer { bytes in
            for (n, unit) in units.enumerated() {
                let end = n + 1 < units.count ? units[n + 1].start : bytes.count
                let length = UInt32(max(0, end - unit.payload))
                // Each byte stores only its part of the 32-bit big-endian length.
                out.append(UInt8(truncatingIfNeeded: length >> 24)); out.append(UInt8(truncatingIfNeeded: length >> 16))
                out.append(UInt8(truncatingIfNeeded: length >> 8)); out.append(UInt8(truncatingIfNeeded: length))
                if end > unit.payload { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[unit.payload..<end])) }
            }
        }
        return out
    }

    /// The first SPS and PPS, each with its start code. Encoders put them first, so the scan stops once both are seen.
    public static func spsPps(_ data: [UInt8], offset: Int = 0) -> (sps: [UInt8]?, pps: [UInt8]?) {
        var seenSPS = false, seenPPS = false
        let units = startCodes(data, offset: offset) { type in
            if type == 7 { seenSPS = true } else if type == 8 { seenPPS = true }
            return seenSPS && seenPPS
        }
        var sps: [UInt8]?, pps: [UInt8]?
        for n in units.indices {
            let unit = units[n], type = unit.payload < data.count ? Int(data[unit.payload] & 0x1F) : 0
            guard (type == 7 && sps == nil) || (type == 8 && pps == nil) else { continue }
            // The last unit seen may end where the scan stopped, so its end is found here.
            let end = n + 1 < units.count ? units[n + 1].start : nextStart(data, after: unit.payload)
            if type == 7 { sps = Array(data[unit.start..<end]) } else { pps = Array(data[unit.start..<end]) }
        }
        return (sps, pps)
    }

    /// Where the unit after `from` begins (its start code included), or the end of the data.
    private static func nextStart(_ data: [UInt8], after from: Int) -> Int {
        startCodes(data, offset: from) { _ in true }.first?.start ?? data.count
    }
}
