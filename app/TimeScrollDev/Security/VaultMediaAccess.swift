import Foundation

enum VaultMediaAccess {
  static let didChange = Notification.Name("com.muzhen.TimeScroll.vaultMediaAccessChanged")
  struct Token: Hashable {
    let generation: String?
    let vaultEnabled: Bool
  }

  static func token(for url: URL) -> Token? {
    let generation = StoragePaths.sharedString(forKey: "vault.mediaGeneration")
    let enabled = (StoragePaths.sharedObject(forKey: "settings.vaultEnabled") as? Bool)
      ?? UserDefaults.standard.bool(forKey: "settings.vaultEnabled")
    if enabled || url.pathExtension.lowercased() == "tse" {
      guard StoragePaths.sharedBool(forKey: "vault.isUnlocked") else { return nil }
    }
    return Token(generation: generation, vaultEnabled: enabled)
  }

  static func isCurrent(_ token: Token, for url: URL) -> Bool {
    self.token(for: url) == token
  }
}
