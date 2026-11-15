import Foundation
import Security

/// The vault's media public key, pinned in the login keychain. The manifest that also carries
/// it lives in the movable storage folder, where anyone who can write could swap in their own
/// key; locked captures encrypt only to this pinned copy. It is not secret.
enum VaultPublicKeyPin {
  private static let service = "com.muzhen.TimeScroll.vault"
  private static let account = "media-public-key-v2"

  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  static func save(_ publicKey: Data) throws {
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: publicKey] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw error(status) }
    var attributes = query
    attributes[kSecAttrLabel as String] = "TimeScroll Vault Public Key"
    attributes[kSecValueData as String] = publicKey
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw error(added) }
  }

  /// The pinned key, or nil when none was pinned on this Mac.
  static func load() throws -> Data? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw error(status) }
    return data
  }

  private static func error(_ status: OSStatus) -> NSError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                   userInfo: [NSLocalizedDescriptionKey: "Could not access the vault public key in the keychain: \(message)"])
  }
}
