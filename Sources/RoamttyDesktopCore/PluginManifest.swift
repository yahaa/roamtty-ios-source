import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The plugin build this app version is pinned to (Resources/desktop-plugin.json, the same file as
/// Android's assets/desktop-plugin.json, written by roamtty's scripts/desktop/pin.sh): where to
/// download it and the SHA-256 of each unpacked binary.
/// Port of Android `desktop-core/PluginManifest.kt` (roamtty #218).
public struct PluginManifest: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public let file: String
        public let sha256: String
        public let size: Int64
    }

    public let version: String
    public let baseUrl: String
    public let protoMin: Int
    public let protoMax: Int
    public let openh264: String
    public let targets: [String: Target]

    public static let OPENH264_BASE = "https://ciscobinary.openh264.org"

    /// The same pinned build, downloaded from `baseUrl` instead (a mirror); the checksums still decide what runs.
    public func withBaseUrl(_ baseUrl: String) -> PluginManifest {
        PluginManifest(version: version, baseUrl: baseUrl, protoMin: protoMin, protoMax: protoMax, openh264: openh264, targets: targets)
    }

    public func url(_ target: Target) -> String {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(target.file)"
    }

    public enum ParseError: Error { case invalid(String) }

    public static func parse(_ text: String) throws -> PluginManifest {
        guard let json = JSONValue.object(text) else { throw ParseError.invalid("not a JSON object") }
        guard let version = json["version"] as? String, let baseUrl = json["baseUrl"] as? String,
              let targets = json["targets"] as? [String: Any] else { throw ParseError.invalid("missing version, baseUrl or targets") }
        let proto = json["proto"] as? [String: Any]
        var out: [String: Target] = [:]
        for (key, value) in targets {
            guard let t = value as? [String: Any], let file = t["file"] as? String, let sha = t["sha256"] as? String else {
                throw ParseError.invalid("bad target \(key)")
            }
            out[key] = Target(file: file, sha256: sha, size: JSONValue.int64(t["size"]) ?? 0)
        }
        return PluginManifest(version: version, baseUrl: baseUrl, protoMin: JSONValue.int(proto?["min"]) ?? 1,
                              protoMax: JSONValue.int(proto?["max"]) ?? 1, openh264: JSONValue.string(json["openh264"]), targets: out)
    }

    /// The manifest shipped with the app (app bundle root, or the SwiftPM module bundle in tests).
    /// Session rows ask on every render, so the resource is read once.
    public static func bundled() throws -> PluginManifest { try bundledOnce.get() }
    private static let bundledOnce = Result { try readBundled() }

    private static func readBundled() throws -> PluginManifest {
        var candidates: [Bundle] = [.main]
        #if SWIFT_PACKAGE
        candidates.insert(Bundle.module, at: 0)
        #endif
        for bundle in candidates {
            if let url = bundle.url(forResource: "desktop-plugin", withExtension: "json")
                ?? bundle.url(forResource: "desktop-plugin", withExtension: "json", subdirectory: "Resources") {
                return try parse(String(contentsOf: url, encoding: .utf8))
            }
        }
        throw ParseError.invalid("desktop-plugin.json is missing from the app resources")
    }

    /// Whether `data` (the unpacked binary) is the pinned build for `target`.
    public func verify(_ data: Data, target: Target) -> Bool { Self.sha256Hex(data) == target.sha256.lowercased() }

    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The release target for `uname -sm` output, e.g. "Linux x86_64" → linux-x86_64.
    public static func targetFor(_ uname: String) -> String? {
        let parts = uname.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let system = parts.first ?? "", machine = parts.count > 1 ? parts[1] : ""
        let arch: String
        switch machine.lowercased() {
        case "x86_64", "amd64": arch = "x86_64"
        case "aarch64", "arm64": arch = "aarch64"
        default: return nil
        }
        switch system.lowercased() {
        case "linux": return "linux-\(arch)"
        case "darwin": return "macos-universal"
        // The Windows probe reports "Windows AMD64" / "Windows ARM64" (PROCESSOR_ARCHITECTURE).
        case "windows": return arch == "x86_64" ? "windows-x64" : "windows-arm64"
        default: return nil
        }
    }

    /// The OpenH264 file Cisco publishes for a Linux or Windows target (macOS uses VideoToolbox).
    public static func openh264File(target: String, version: String) -> String? {
        switch target {
        case "linux-x86_64": return "libopenh264-\(version)-linux64.8.so.bz2"
        case "linux-aarch64": return "libopenh264-\(version)-linux-arm64.8.so.bz2"
        case "windows-x64": return "openh264-\(version)-win64.dll.bz2"
        case "windows-arm64": return "openh264-\(version)-win-arm64.dll.bz2"
        default: return nil
        }
    }
}
