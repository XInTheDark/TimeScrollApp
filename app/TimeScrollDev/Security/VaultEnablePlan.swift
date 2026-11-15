import Foundation

/// Chooses the master secret when the vault is turned on. Data encrypted earlier can only be
/// read with that vault's secret, so an existing vault is always reused or recovered; a new
/// secret replaces it only when the user explicitly asks to start a new vault.
struct VaultEnablePlan {
  let secret: VaultSecret
  /// True when an existing vault's recovery file will be replaced (and must be archived first).
  let replacesExistingVault: Bool

  enum Failure: LocalizedError, Equatable {
    case existingVaultNeedsPassphrase
    case existingVaultUnreadable

    var errorDescription: String? {
      switch self {
      case .existingVaultNeedsPassphrase:
        return "This storage folder already has an encrypted vault, and that passphrase does not open it. Enter the vault's recovery passphrase to turn encryption back on."
      case .existingVaultUnreadable:
        return "This storage folder has a vault recovery file that cannot be read. Restore it from a backup, or start a new vault."
      }
    }
  }

  /// True when the folder has a vault whose key this Mac's keychain does not hold, so turning
  /// encryption on needs that vault's recovery passphrase.
  static func needsExistingPassphrase(existing: VaultManifest?, manifestFilePresent: Bool, stored: VaultSecret?) -> Bool {
    guard let existing else { return manifestFilePresent }
    return !(stored.map(existing.matches) ?? false)
  }

  /// Runs PBKDF2 when an existing vault must be opened; call off the main thread.
  static func resolve(existing: VaultManifest?,
                      manifestFilePresent: Bool,
                      stored: VaultSecret?,
                      passphrase: String,
                      startNewVault: Bool) throws -> VaultEnablePlan {
    if existing == nil, manifestFilePresent {
      // A damaged recovery file is still the only copy of that vault's key; never overwrite it silently.
      guard startNewVault else { throw Failure.existingVaultUnreadable }
      return VaultEnablePlan(secret: .generate(), replacesExistingVault: true)
    }
    guard let existing else {
      // No vault file here. A key already in the keychain may still encrypt media elsewhere
      // in this folder (for example a deleted manifest), so keep it.
      return VaultEnablePlan(secret: stored ?? .generate(), replacesExistingVault: false)
    }
    if startNewVault { return VaultEnablePlan(secret: .generate(), replacesExistingVault: true) }
    if let stored, existing.matches(stored) {
      return VaultEnablePlan(secret: stored, replacesExistingVault: false)
    }
    guard let recovered = try? existing.openRecovery(passphrase: passphrase) else {
      throw Failure.existingVaultNeedsPassphrase
    }
    return VaultEnablePlan(secret: recovered, replacesExistingVault: false)
  }
}
