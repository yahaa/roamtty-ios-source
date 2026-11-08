import Foundation
#if canImport(Security)
import Security
#endif

/// What a host's Keychain item holds. The raw value is part of the item's account, so it must not change.
public enum SecretPurpose: String, CaseIterable, Sendable { case password, key }

/// Keychain secrets never synchronize or migrate to another device. Passphrases are never sent here.
public final class SecretVault {
    public init() {}
    public func save(data: Data?, hostID: String, purpose: SecretPurpose) throws {
        #if canImport(Security)
        let query = identity(hostID, purpose)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RoamError.invalid("无法删除凭据 / Keychain delete failed") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RoamError.invalid("无法保存凭据 / Keychain write failed") }
        #else
        throw RoamError.invalid("Keychain requires an Apple platform")
        #endif
    }
    public func read(hostID: String, purpose: SecretPurpose) throws -> Data? {
        #if canImport(Security)
        var query = identity(hostID, purpose)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RoamError.invalid("无法读取凭据 / Keychain read failed") }
        return result as? Data
        #else
        throw RoamError.invalid("Keychain requires an Apple platform")
        #endif
    }
    public func remove(hostID: String) throws {
        for purpose in SecretPurpose.allCases { try save(data: nil, hostID: hostID, purpose: purpose) }
    }
    #if canImport(Security)
    private func identity(_ hostID: String, _ purpose: SecretPurpose) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.roamtty.credentials",
         kSecAttrAccount as String: hostID + ":" + purpose.rawValue, kSecAttrSynchronizable as String: false]
    }
    #endif
}
