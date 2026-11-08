import Foundation

/// gzip (RFC 1952) with a small DEFLATE (RFC 1951) decoder, for the phone-side check of a plugin
/// release (`linux-*.gz`) before it is uploaded: Android unpacks with GZIPInputStream, and neither
/// Foundation on Linux nor iOS has a gzip reader (Compression's zlib is raw DEFLATE without the
/// header and CRC). The CRC-32 and size in the trailer are checked.
public enum Gzip {
    public enum Failure: Error, Equatable { case header, data, checksum }

    public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count >= 18, input[0] == 0x1f, input[1] == 0x8b, input[2] == 8 else { throw Failure.header }
        let flags = input[3]
        var at = 10
        if flags & 4 != 0 { // FEXTRA
            guard at + 2 <= input.count else { throw Failure.header }
            at += 2 + Int(input[at]) | Int(input[at + 1]) << 8
        }
        if flags & 8 != 0 { while at < input.count && input[at] != 0 { at += 1 }; at += 1 } // FNAME
        if flags & 16 != 0 { while at < input.count && input[at] != 0 { at += 1 }; at += 1 } // FCOMMENT
        if flags & 2 != 0 { at += 2 } // FHCRC
        guard at < input.count else { throw Failure.header }
        var inflater = Inflater(input, start: at)
        let out = try inflater.run()
        let end = inflater.byteEnd
        guard end + 8 <= input.count else { throw Failure.data }
        func le32(_ i: Int) -> UInt32 { UInt32(input[i]) | UInt32(input[i + 1]) << 8 | UInt32(input[i + 2]) << 16 | UInt32(input[i + 3]) << 24 }
        guard le32(end) == crc32(out), le32(end + 4) == UInt32(truncatingIfNeeded: out.count) else { throw Failure.checksum }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        bytes.withUnsafeBufferPointer { p in for b in p { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFF_FFFF
    }
}

/// A canonical Huffman code as count-per-length and symbols in order (zlib's puff.c layout).
private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: ArraySlice<Int>) throws {
        symbols = [Int](repeating: 0, count: lengths.count)
        for l in lengths { counts[l] += 1 }
        var left = 1
        for len in 1..<16 { left <<= 1; left -= counts[len]; if left < 0 { throw Gzip.Failure.data } }
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offs[len + 1] = offs[len] + counts[len] }
        for (i, l) in lengths.enumerated() where l != 0 { symbols[offs[l]] = i; offs[l] += 1 }
    }
}

private struct Inflater {
    private let input: [UInt8]
    private var pos: Int
    private var bitBuf = 0
    private var bitCount = 0
    private var out: [UInt8] = []

    init(_ input: [UInt8], start: Int) { self.input = input; pos = start; out.reserveCapacity(input.count * 3) }

    /// The first byte after the DEFLATE stream (the gzip trailer).
    var byteEnd: Int { pos }

    private mutating func bits(_ need: Int) throws -> Int {
        var val = bitBuf
        while bitCount < need {
            guard pos < input.count else { throw Gzip.Failure.data }
            val |= Int(input[pos]) << bitCount
            pos += 1
            bitCount += 8
        }
        bitBuf = val >> need
        bitCount -= need
        return val & ((1 << need) - 1)
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.counts[len]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw Gzip.Failure.data
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                   4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        // swiftlint:disable:next force_try - RFC 1951's fixed code lengths always build a valid table.
        return (try! Huffman(lengths: l[...]), try! Huffman(lengths: [Int](repeating: 5, count: 30)[...]))
    }()

    mutating func run() throws -> [UInt8] {
        var last = 0
        repeat {
            last = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Self.fixed.0, Self.fixed.1)
            case 2: let (l, d) = try dynamic(); try codes(l, d)
            default: throw Gzip.Failure.data
            }
        } while last == 0
        bitBuf = 0; bitCount = 0 // the trailer starts on the next byte
        return out
    }

    private mutating func stored() throws {
        bitBuf = 0; bitCount = 0
        guard pos + 4 <= input.count else { throw Gzip.Failure.data }
        let len = Int(input[pos]) | Int(input[pos + 1]) << 8
        let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw Gzip.Failure.data }
        pos += 4
        guard pos + len <= input.count else { throw Gzip.Failure.data }
        out.append(contentsOf: input[pos..<(pos + len)])
        pos += len
    }

    private mutating func dynamic() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw Gzip.Failure.data }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[order[i]] = try bits(3) }
        let lencode = try Huffman(lengths: lengths[0..<19])
        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(lencode)
            if symbol < 16 { lengths[index] = symbol; index += 1; continue }
            var len = 0
            if symbol == 16 {
                guard index > 0 else { throw Gzip.Failure.data }
                len = lengths[index - 1]
                symbol = 3 + (try bits(2))
            } else if symbol == 17 { symbol = 3 + (try bits(3)) } else { symbol = 11 + (try bits(7)) }
            guard index + symbol <= nlen + ndist else { throw Gzip.Failure.data }
            for _ in 0..<symbol { lengths[index] = len; index += 1 }
        }
        guard lengths[256] != 0 else { throw Gzip.Failure.data }
        return (try Huffman(lengths: lengths[0..<nlen]), try Huffman(lengths: lengths[nlen..<(nlen + ndist)]))
    }

    private mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            var symbol = try decode(lencode)
            if symbol < 256 { out.append(UInt8(symbol)); continue }
            if symbol == 256 { return }
            symbol -= 257
            guard symbol < 29 else { throw Gzip.Failure.data }
            let len = Self.lengthBase[symbol] + (try bits(Self.lengthExtra[symbol]))
            let ds = try decode(distcode)
            guard ds < 30 else { throw Gzip.Failure.data }
            let dist = Self.distBase[ds] + (try bits(Self.distExtra[ds]))
            guard dist <= out.count else { throw Gzip.Failure.data }
            let from = out.count - dist
            for i in 0..<len { out.append(out[from + i]) }
        }
    }
}
