import Foundation
import CNative

public struct HostPin: Codable, Equatable, Sendable {
    public let endpoint: String
    public let algorithm: String
    public let key: Data
    public init(endpoint: String, algorithm: String, key: Data) { self.endpoint = endpoint; self.algorithm = algorithm; self.key = key }
    public var fingerprint: String {
        var digest = [UInt8](repeating: 0, count: 32)
        key.withUnsafeBytes { bytes in roam_sha256(bytes.bindMemory(to: UInt8.self).baseAddress, key.count, &digest) }
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
public protocol PinStore: AnyObject {
    func pin(endpoint: String) throws -> HostPin?
    func putIfAbsent(_ pin: HostPin) throws -> HostPin
}
public enum AuthPrompt {
    case verifyHost(HostPin)
    case keyboard(instruction: String, labels: [String], echo: [Bool])
}
public struct TrustPolicy {
    private let store: PinStore
    public init(store: PinStore) { self.store = store }
    public func verify(_ received: HostPin, approve: () -> Bool) throws {
        if let old = try store.pin(endpoint: received.endpoint) {
            guard old.key == received.key else { throw RoamError.hostKeyChanged(old.fingerprint, received.fingerprint) }
            return
        }
        guard approve() else { throw RoamError.rejected }
        let winner = try store.putIfAbsent(received)
        guard winner.key == received.key else { throw RoamError.hostKeyChanged(winner.fingerprint, received.fingerprint) }
    }
}
