import Foundation

/// Big-endian writer for the desktop protocol's binary messages.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v >> 8)); bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u32(_ v: Int64) { for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> Int64(s))) } }
    mutating func i64(_ v: Int64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> Int64(s))) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(s))) } }
    mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

/// Big-endian reader; every read returns nil once the bytes run out (Java's BufferUnderflowException).
struct ByteReader {
    let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8], at position: Int = 0) { self.bytes = bytes; self.position = position }

    var remaining: Int { bytes.count - position }

    mutating func u8() -> Int? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return Int(bytes[position])
    }

    mutating func u16() -> Int? {
        guard remaining >= 2 else { return nil }
        defer { position += 2 }
        return Int(bytes[position]) << 8 | Int(bytes[position + 1])
    }

    mutating func u32() -> Int64? {
        guard remaining >= 4 else { return nil }
        var v: Int64 = 0
        for i in 0..<4 { v = v << 8 | Int64(bytes[position + i]) }
        position += 4
        return v
    }

    /// Four bytes as a signed int.
    mutating func i32() -> Int? { u32().map { Int(Int32(truncatingIfNeeded: $0)) } }

    mutating func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[position + i]) }
        position += 8
        return v
    }

    mutating func rest() -> [UInt8] {
        defer { position = bytes.count }
        return Array(bytes[position...])
    }
}

/// Loose JSON accessors with the defaults of org.json's `opt*`.
enum JSONValue {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return any as? [String: Any]
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String { return s == "true" ? true : s == "false" ? false : nil }
        return nil
    }

    /// org.json `optString`: "" when missing or null, numbers and booleans as text.
    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case nil, is NSNull: return ""
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default: return "\(v!)"
        }
    }

    static func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
}
