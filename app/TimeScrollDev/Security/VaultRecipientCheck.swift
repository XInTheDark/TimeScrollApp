import Foundation

/// Decides which public key captures may be encrypted to while the vault is locked. Only a key
/// trusted outside the storage folder qualifies; a manifest that disagrees means the folder
/// was altered or belongs to another vault, so encryption fails closed.
enum VaultRecipientCheck {
  static func recipient(trusted: Data?, manifestKey: Data?) throws -> Data {
    guard let trusted else {
      throw NSError(domain: "TS.Vault", code: 32, userInfo: [NSLocalizedDescriptionKey: "Unlock the vault to resume encrypted capture."])
    }
    if let manifestKey, manifestKey != trusted {
      throw NSError(domain: "TS.Vault", code: 33, userInfo: [NSLocalizedDescriptionKey: "The vault file in the storage folder does not match this Mac's vault key. Unlock the vault to continue."])
    }
    return trusted
  }
}
