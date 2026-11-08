import Foundation

/// The mouse tracking mode a host asked for, followed through the output stream with xterm's rules.
///
/// SwiftTerm 1.13 turns tracking off when an encoding mode (1005, 1006, 1015, 1016) is reset, where xterm only
/// changes the encoding. mosh-server resends every mode as a reset/set pair after a resize, so a tmux session
/// over mosh lost its wheel scrolling (`ESC[?1002l ESC[?1002h … ESC[?1006l ESC[?1006h` leaves SwiftTerm off).
/// The runtime compares this with SwiftTerm after each chunk and puts the requested mode back.
public struct TerminalMouseTracking: Equatable {
    /// The DECSET number of the active tracking mode (9, 1000, 1002 or 1003); nil when off.
    public private(set) var mode: Int?
    /// The stream ends between sequences and characters, so a sequence can be inserted without splitting one.
    public var atBoundary: Bool { state == .ground && utf8Pending == 0 }
    private var state = State.ground
    private var utf8Pending = 0
    private var parameters = [UInt8]()
    private var privateMarker = false
    private var intermediate = false

    private enum State: Equatable { case ground, escape, csi, string, stringEscape }
    private static let trackingModes: Set<Int> = [9, 1000, 1002, 1003]

    public init() {}

    public mutating func consume<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes { consume(byte) }
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            switch byte {
            case 0x1b: state = .escape; utf8Pending = 0
            case 0xc0...0xdf: utf8Pending = 1
            case 0xe0...0xef: utf8Pending = 2
            case 0xf0...0xf7: utf8Pending = 3
            case 0x80...0xbf: utf8Pending = max(0, utf8Pending - 1)
            default: utf8Pending = 0
            }
        case .escape:
            switch byte {
            case 0x5b: state = .csi; parameters.removeAll(keepingCapacity: true); privateMarker = false; intermediate = false
            case 0x5d, 0x50, 0x5f, 0x5e, 0x58: state = .string // OSC, DCS, APC, PM, SOS
            case 0x63: mode = nil; state = .ground // RIS
            case 0x1b: break
            case 0x20...0x2f: break // ESC intermediates, e.g. ESC ( B
            default: state = .ground
            }
        case .csi:
            switch byte {
            case 0x1b: state = .escape
            case 0x3f where parameters.isEmpty && !privateMarker: privateMarker = true
            case 0x30...0x3f: if parameters.count < 64 { parameters.append(byte) }
            case 0x20...0x2f: intermediate = true
            case 0x40...0x7e:
                if privateMarker && !intermediate && (byte == 0x68 || byte == 0x6c) { apply(set: byte == 0x68) }
                state = .ground
            case 0x18, 0x1a: state = .ground // CAN, SUB abort the sequence
            default: break // C0 controls inside a CSI are executed, not collected
            }
        case .string:
            switch byte {
            case 0x07, 0x18, 0x1a: state = .ground
            case 0x1b: state = .stringEscape
            default: break
            }
        case .stringEscape:
            // ST ends the string; any other ESC sequence cancels it and is read as itself.
            if byte == 0x5c { state = .ground } else { state = .escape; consume(byte) }
        }
    }

    private mutating func apply(set: Bool) {
        for field in parameters.split(separator: 0x3b, omittingEmptySubsequences: false) {
            guard let value = Int(String(decoding: field, as: UTF8.self)), Self.trackingModes.contains(value) else { continue }
            mode = set ? value : nil
        }
    }
}
