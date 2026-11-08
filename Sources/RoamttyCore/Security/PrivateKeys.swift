import Foundation

/// Ports of Android's PrivateKeys.kt and the SSH greeting check in HostReachability.kt.
public enum PrivateKeys {
    /// Whether `key` (OpenSSH or PEM) is protected by a passphrase. A key that cannot be read counts as encrypted, so
    /// the caller still asks rather than failing silently.
    public static func needsPassphrase(_ key: Data) -> Bool {
        guard let text = String(data: key, encoding: .utf8) else { return true }
        if let body = armored(text, label: "OPENSSH PRIVATE KEY") {
            guard let data = Data(base64Encoded: body), let cipher = openSSHCipher(data) else { return true }
            return cipher != "none"
        }
        if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
        for label in ["RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY", "PRIVATE KEY"] where armored(text, label: label) != nil {
            return text.range(of: #"Proc-Type:\s*4,\s*ENCRYPTED"#, options: .regularExpression) != nil
        }
        return true
    }

    private static func armored(_ text: String, label: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN \(label)-----"), let end = text.range(of: "-----END \(label)-----", range: begin.upperBound..<text.endIndex) else { return nil }
        return text[begin.upperBound..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// The cipher name of an `openssh-key-v1` blob, or nil when it is not one.
    private static func openSSHCipher(_ data: Data) -> String? {
        let bytes = [UInt8](data), magic = Array("openssh-key-v1\0".utf8)
        guard bytes.count >= magic.count + 4, Array(bytes[0..<magic.count]) == magic else { return nil }
        let at = magic.count
        let length = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        guard length <= 64, bytes.count >= at + 4 + length else { return nil }
        return String(bytes: bytes[(at + 4)..<(at + 4 + length)], encoding: .ascii)
    }
}

/// Reads a server's SSH identification. RFC 4253 lets a server send other lines before its version line.
public enum SSHGreeting {
    public enum Result: Equatable { case needMore, valid, invalid }
    /// Our own identification goes out first, as ssh does: a transparent proxy that sniffs the first client bytes
    /// before dialing out never relays sshd's greeting to a silent client.
    public static let probeIdentification = Data("SSH-2.0-Roamtty_probe\r\n".utf8)
    public static let maxBytes = 8192

    public static func scan(_ received: Data) -> Result {
        var line: [UInt8] = []
        for (index, byte) in received.enumerated() {
            if index >= maxBytes { return .invalid }
            guard byte == 10 else { line.append(byte); continue }
            if line.starts(with: Array("SSH-".utf8)) { return valid(line) ? .valid : .invalid }
            line.removeAll()
        }
        return received.count >= maxBytes ? .invalid : .needMore
    }

    /// RFC 4253: printable ASCII software name without spaces or '-', optional comments, and a complete line.
    static func valid(_ line: [UInt8]) -> Bool {
        guard line.count + 1 <= 255, let text = String(bytes: line, encoding: .isoLatin1) else { return false }
        return text.range(of: #"^SSH-(?:2\.0|1\.99)-[\x21-\x2C\x2E-\x7E]+(?: [^\x00\r\n]*)?\r?$"#, options: .regularExpression) != nil
    }
}
