import Foundation
import CNative
import RoamttyCore

/// Wire-compatible with Android's MoshProtocol.kt and mosh SSP version 2.
/// All integer fields on the wire are unsigned; UInt64.max means shutdown.
enum Mosh {
    static let protocolVersion: UInt64 = 2
    static let shutdownNumber = UInt64.max
    static let maximumInstruction = 16 * 1024 * 1024

    struct Connect: Equatable {
        let port: Int
        let key: String
    }

    /// The ports `mosh-server new` picks from when none is asked for.
    static let serverPorts = 60000...61000

    /// The `MOSH CONNECT <port> <key>` line of `mosh-server new`: a line of exactly those four fields, a port of
    /// `serverPorts` and a 22-character base64 key.
    static func parseConnect(_ output: String) -> Connect? {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4, fields[0] == "MOSH", fields[1] == "CONNECT",
                  let port = Int(fields[2]), serverPorts.contains(port) else { continue }
            let key = fields[3]
            guard key.utf8.count == 22, key.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "/" || $0 == "+") }) else { continue }
            return Connect(port: port, key: String(key))
        }
        return nil
    }

    /// OCB is provided by the OpenSSL bridge, never by a local AES implementation.
    /// The owning transport confines this object to its worker thread.
    final class Crypto {
        private var key: [UInt8]
        private var sequence: UInt64 = 0

        init(key: String) throws {
            guard key.utf8.count == 22, let decoded = Data(base64Encoded: key + "=="), decoded.count == 16 else {
                throw RoamError.invalid("Invalid mosh key")
            }
            self.key = Array(decoded)
        }

        deinit { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }

        func seal(_ plain: Data, toClient: Bool = false) throws -> Data {
            guard sequence < (UInt64(1) << 63), plain.count <= Int(Int32.max) else {
                throw RoamError.transport("Mosh packet limit reached")
            }
            let value = sequence | (toClient ? UInt64(1) << 63 : 0)
            sequence += 1
            let nonce = [UInt8](repeating: 0, count: 4) + bigEndian(value)
            var tag = [UInt8](repeating: 0, count: 16)
            var output = [UInt8](repeating: 0, count: plain.count + 16)
            let count = plain.withUnsafeBytes { bytes in
                roam_ocb(1, key, nonce, bytes.bindMemory(to: UInt8.self).baseAddress,
                         Int32(plain.count), &output, &tag)
            }
            guard count == plain.count else { throw RoamError.transport("Mosh encryption failed") }
            return Data(nonce.suffix(8)) + Data(output.prefix(Int(count))) + Data(tag)
        }

        /// Rejects reflected client packets and unauthenticated data. The alternate
        /// direction supports peers in interoperability tests without changing crypto.
        func open(_ packet: Data, fromClient: Bool = false) -> Data? {
            guard packet.count >= 24, packet.count - 24 <= Int(Int32.max) else { return nil }
            let bytes = Array(packet)
            guard (bytes[0] & 0x80 != 0) != fromClient else { return nil }
            let nonce = [UInt8](repeating: 0, count: 4) + bytes.prefix(8)
            let ciphertext = Array(bytes[8..<(bytes.count - 16)])
            var tag = Array(bytes.suffix(16))
            var output = [UInt8](repeating: 0, count: ciphertext.count + 16)
            let count = roam_ocb(0, key, nonce, ciphertext, Int32(ciphertext.count), &output, &tag)
            guard count == ciphertext.count else { return nil }
            return Data(output.prefix(Int(count)))
        }
    }

    struct Instruction: Equatable {
        var oldNum: UInt64
        var newNum: UInt64
        var ackNum: UInt64
        var throwawayNum: UInt64
        var diff = Data()
        var protocolVersion: UInt64 = Mosh.protocolVersion

        func encode() -> Data {
            var writer = MoshProto.Writer()
            writer.varint(1, protocolVersion)
            writer.varint(2, oldNum)
            writer.varint(3, newNum)
            writer.varint(4, ackNum)
            writer.varint(5, throwawayNum)
            if !diff.isEmpty { writer.bytes(6, diff) }
            return writer.data
        }

        static func decode(_ data: Data) throws -> Instruction {
            var result = Instruction(oldNum: 0, newNum: 0, ackNum: 0, throwawayNum: 0, protocolVersion: 0)
            try MoshProto.read(data) { field in
                switch field.number {
                case 1: result.protocolVersion = try field.integer()
                case 2: result.oldNum = try field.integer()
                case 3: result.newNum = try field.integer()
                case 4: result.ackNum = try field.integer()
                case 5: result.throwawayNum = try field.integer()
                case 6: result.diff = try field.bytes()
                default: break
                }
            }
            return result
        }
    }

    enum UserEvent {
        case keys(Data)
        case resize(columns: Int, rows: Int)

        func encode() -> Data {
            var message = MoshProto.Writer()
            var body = MoshProto.Writer()
            switch self {
            case .keys(let data):
                body.bytes(4, data)
                message.bytes(2, body.data)
            case .resize(let columns, let rows):
                body.varint(5, UInt64(max(1, min(columns, 65535))))
                body.varint(6, UInt64(max(1, min(rows, 65535))))
                message.bytes(3, body.data)
            }
            return message.data
        }
    }

    static func userMessage(_ events: [Data]) -> Data {
        var writer = MoshProto.Writer()
        for event in events { writer.bytes(1, event) }
        return writer.data
    }

    enum HostEvent: Equatable {
        case bytes(Data)
        case resize(columns: Int, rows: Int)
    }

    static func hostMessage(_ data: Data) throws -> [HostEvent] {
        var events = [HostEvent]()
        try MoshProto.read(data) { instruction in
            guard instruction.number == 1 else { return }
            try MoshProto.read(try instruction.bytes()) { body in
                switch body.number {
                case 2:
                    try MoshProto.read(try body.bytes()) { field in
                        if field.number == 4 { events.append(.bytes(try field.bytes())) }
                    }
                case 3:
                    var columns = 0, rows = 0
                    try MoshProto.read(try body.bytes()) { field in
                        if field.number == 5 { columns = Int(clamping: try field.integer()) }
                        if field.number == 6 { rows = Int(clamping: try field.integer()) }
                    }
                    events.append(.resize(columns: columns, rows: rows))
                default: break // Echo acknowledgments are for optional local prediction.
                }
            }
        }
        return events
    }

    static func compress(_ data: Data) throws -> Data {
        guard data.count <= maximumInstruction else { throw malformed("Mosh instruction too large") }
        var length = compressBound(uLong(data.count))
        var result = [UInt8](repeating: 0, count: Int(length))
        let status = data.withUnsafeBytes { bytes in
            compress2(&result, &length, bytes.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
        }
        guard status == Z_OK else { throw malformed("Mosh compression failed") }
        return Data(result.prefix(Int(length)))
    }

    static func decompress(_ data: Data, limit: Int = maximumInstruction) throws -> Data {
        guard !data.isEmpty, data.count <= Int(UInt32.max), limit >= 0 else { throw malformed("Invalid compressed mosh instruction") }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw malformed("Mosh decompression failed")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard count <= limit - result.count else { throw malformed("Mosh instruction too large") }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else {
                    throw malformed("Truncated or invalid mosh instruction")
                }
            }
        }
    }

    /// Fragment = big-endian instruction id, final-bit/15-bit index, payload.
    static func fragments(id: UInt64, payload: Data, maxPayload: Int) throws -> [Data] {
        guard maxPayload > 0, payload.count <= maximumInstruction else { throw malformed("Invalid mosh fragment size") }
        let count = max(1, payload.count / maxPayload + (payload.count % maxPayload == 0 ? 0 : 1))
        guard count <= 32768 else { throw malformed("Too many mosh fragments") }
        let source = Array(payload)
        return (0..<count).map { index in
            let start = index * maxPayload, end = min(source.count, start + maxPayload)
            let number = UInt16(index) | (index == count - 1 ? 0x8000 : 0)
            return Data(bigEndian(id) + [UInt8(number >> 8), UInt8(truncatingIfNeeded: number)] + source[start..<end])
        }
    }

    struct Assembly {
        private var currentID: UInt64?
        private var completed = false
        private var parts = [Int: Data]()
        private var count: Int?
        private var buffered = 0

        mutating func add(_ fragment: Data) -> Data? {
            guard fragment.count >= 10 else { return nil }
            let bytes = Array(fragment)
            let id = readBigEndian(bytes.prefix(8))
            let raw = Int(bytes[8]) << 8 | Int(bytes[9])
            let number = raw & 0x7fff
            if let currentID, id < currentID { return nil }
            if id != currentID {
                currentID = id; completed = false; parts.removeAll(keepingCapacity: true); count = nil; buffered = 0
            }
            guard !completed else { return nil }
            if let count, number >= count { return nil }
            if raw & 0x8000 != 0 {
                guard count == nil || count == number + 1,
                      !parts.keys.contains(where: { $0 > number }) else { return nil }
                count = number + 1
            }
            if parts[number] == nil {
                let payload = Data(bytes.dropFirst(10))
                guard payload.count <= maximumInstruction - buffered else {
                    parts.removeAll(); completed = true; return nil
                }
                buffered += payload.count
                parts[number] = payload
            }
            guard let count, parts.count == count else { return nil }
            var result = Data(capacity: buffered)
            for index in 0..<count {
                guard let part = parts[index] else { return nil }
                result.append(part)
            }
            parts.removeAll(keepingCapacity: true); buffered = 0; completed = true
            return result
        }
    }

    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) }
    }

    static func readBigEndian<T: Sequence>(_ bytes: T) -> UInt64 where T.Element == UInt8 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func malformed(_ message: String) -> RoamError { .transport(message) }
}

/// Bounds-checked protobuf subset. Unknown fixed-width fields remain skippable.
enum MoshProto {
    struct Writer {
        private(set) var data = Data()
        mutating func varint(_ field: Int, _ value: UInt64) {
            raw(UInt64(field) << 3); raw(value)
        }
        mutating func bytes(_ field: Int, _ value: Data) {
            raw(UInt64(field) << 3 | 2); raw(UInt64(value.count)); data.append(value)
        }
        private mutating func raw(_ value: UInt64) {
            var value = value
            while value >= 128 {
                data.append(UInt8(value & 127) | 128); value >>= 7
            }
            data.append(UInt8(value))
        }
    }

    struct Field {
        let number: Int
        var value: UInt64?
        var data: Data?
        func integer() throws -> UInt64 {
            guard let value else { throw Mosh.malformed("Invalid mosh protobuf field type") }
            return value
        }
        func bytes() throws -> Data {
            guard let data else { throw Mosh.malformed("Invalid mosh protobuf field type") }
            return data
        }
    }

    static func read(_ data: Data, field: (Field) throws -> Void) throws {
        let bytes = Array(data)
        var position = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard position < bytes.count else { throw Mosh.malformed("Truncated mosh protobuf") }
                let byte = bytes[position]; position += 1
                guard index < 9 || byte <= 1 else { throw Mosh.malformed("Mosh protobuf integer overflow") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw Mosh.malformed("Invalid mosh protobuf integer")
        }
        while position < bytes.count {
            let key = try varint()
            guard key >> 3 > 0, key >> 3 <= 0x1fffffff else { throw Mosh.malformed("Invalid mosh protobuf field") }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: try field(Field(number: number, value: varint()))
            case 1, 5:
                let length = key & 7 == 1 ? 8 : 4
                guard length <= bytes.count - position else { throw Mosh.malformed("Truncated mosh protobuf") }
                position += length
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - position) else { throw Mosh.malformed("Truncated mosh protobuf") }
                let end = position + Int(length)
                try field(Field(number: number, data: Data(bytes[position..<end])))
                position = end
            default: throw Mosh.malformed("Unsupported mosh protobuf wire type")
            }
        }
    }
}
