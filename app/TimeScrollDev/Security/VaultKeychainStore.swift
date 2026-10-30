import Foundation
import Security

/// Stores the vault master secret as a generic password in the user's login keychain.
/// This needs no keychain-access-groups entitlement or provisioning profile. The item belongs
/// to TimeScroll's signing identity, so other apps (including the MCP helper, which never
/// needs it) get a macOS prompt, while TimeScroll itself reads it without one across
/// Developer ID updates.
enum VaultKeychainStore {
    private static let service = "com.muzhen.TimeScroll.vault"
    private static let account = "master-secret-v2"

    /// Updates the stored item in place, adding it only when missing, so a failed write never
    /// leaves the keychain without the previous key.
    static func save(_ secret: VaultSecret) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: secret.rawData]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw error(updateStatus, action: "save") }

        var attributes = query
        attributes[kSecAttrLabel as String] = "TimeScroll Vault Key"
        attributes[kSecValueData as String] = secret.rawData
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status, action: "save") }
    }

    /// The stored secret, or nil when there is none (e.g. new Mac or reset keychain).
    static func load() throws -> VaultSecret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw error(status, action: "read") }
        return try VaultSecret(rawData: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func error(_ status: OSStatus, action: String) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "Could not \(action) the vault key in the keychain: \(message)"])
    }
}
