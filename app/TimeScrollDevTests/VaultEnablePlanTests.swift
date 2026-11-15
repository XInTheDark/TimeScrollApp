import Foundation
import Testing
@testable import TimeScroll

/// Turning the vault on never silently replaces an existing vault's key or recovery file.
struct VaultEnablePlanTests {
  private static let passphrase = "correct horse battery"
  private static let original = VaultSecret.generate()
  // PBKDF2 at 600k iterations is slow; build the manifest once.
  private static let manifest = try! VaultManifest.make(secret: original, recoveryPassphrase: passphrase)

  private func resolve(existing: VaultManifest? = manifest, present: Bool? = nil, stored: VaultSecret?,
                       passphrase: String = passphrase, startNew: Bool = false) throws -> VaultEnablePlan {
    try VaultEnablePlan.resolve(existing: existing, manifestFilePresent: present ?? (existing != nil),
                                stored: stored, passphrase: passphrase, startNewVault: startNew)
  }

  @Test func freshFolderWithoutKeyCreatesAVault() throws {
    let plan = try resolve(existing: nil, stored: nil)
    #expect(!plan.replacesExistingVault)
  }

  @Test func freshFolderKeepsAKeyAlreadyInTheKeychain() throws {
    let stored = VaultSecret.generate()
    let plan = try resolve(existing: nil, stored: stored)
    #expect(plan.secret.rawData == stored.rawData)
  }

  @Test func matchingKeychainKeyIsReused() throws {
    let plan = try resolve(stored: Self.original, passphrase: "a new passphrase")
    #expect(plan.secret.rawData == Self.original.rawData)
    #expect(!plan.replacesExistingVault)
  }

  @Test func missingKeychainKeyRecoversTheExistingVault() throws {
    let plan = try resolve(stored: nil)
    #expect(plan.secret.rawData == Self.original.rawData)
    #expect(!plan.replacesExistingVault)
  }

  @Test func mismatchingKeychainKeyRecoversTheExistingVault() throws {
    let plan = try resolve(stored: VaultSecret.generate())
    #expect(plan.secret.rawData == Self.original.rawData)
  }

  @Test func wrongPassphraseNeverCreatesAReplacement() {
    #expect(throws: VaultEnablePlan.Failure.existingVaultNeedsPassphrase) {
      try resolve(stored: nil, passphrase: "not the passphrase")
    }
    #expect(throws: VaultEnablePlan.Failure.existingVaultNeedsPassphrase) {
      try resolve(stored: VaultSecret.generate(), passphrase: "not the passphrase")
    }
  }

  @Test func unreadableRecoveryFileIsNeverOverwrittenSilently() throws {
    #expect(throws: VaultEnablePlan.Failure.existingVaultUnreadable) {
      try resolve(existing: nil, present: true, stored: VaultSecret.generate())
    }
    let plan = try resolve(existing: nil, present: true, stored: nil, startNew: true)
    #expect(plan.replacesExistingVault)
  }

  @Test func explicitNewVaultReplacesAndIsMarked() throws {
    let plan = try resolve(stored: nil, passphrase: "anything else", startNew: true)
    #expect(plan.replacesExistingVault)
    #expect(plan.secret.rawData != Self.original.rawData)
  }

  @Test func existingPassphraseIsNeededOnlyWithoutAMatchingKey() {
    #expect(!VaultEnablePlan.needsExistingPassphrase(existing: nil, manifestFilePresent: false, stored: nil))
    #expect(VaultEnablePlan.needsExistingPassphrase(existing: nil, manifestFilePresent: true, stored: nil))
    #expect(!VaultEnablePlan.needsExistingPassphrase(existing: Self.manifest, manifestFilePresent: true, stored: Self.original))
    #expect(VaultEnablePlan.needsExistingPassphrase(existing: Self.manifest, manifestFilePresent: true, stored: nil))
    #expect(VaultEnablePlan.needsExistingPassphrase(existing: Self.manifest, manifestFilePresent: true, stored: VaultSecret.generate()))
  }
}
