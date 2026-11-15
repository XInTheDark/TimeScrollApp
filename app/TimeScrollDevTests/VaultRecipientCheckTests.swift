import Foundation
import Testing
@testable import TimeScroll

/// Locked captures encrypt only to a key trusted outside the storage folder.
struct VaultRecipientCheckTests {
  private let owner = Data(repeating: 1, count: 32)
  private let attacker = Data(repeating: 2, count: 32)

  @Test func trustedKeyMatchingManifestIsUsed() throws {
    #expect(try VaultRecipientCheck.recipient(trusted: owner, manifestKey: owner) == owner)
  }

  @Test func substitutedManifestKeyFailsClosed() {
    #expect(throws: (any Error).self) { try VaultRecipientCheck.recipient(trusted: owner, manifestKey: attacker) }
  }

  @Test func manifestAloneIsNeverTrusted() {
    #expect(throws: (any Error).self) { try VaultRecipientCheck.recipient(trusted: nil, manifestKey: attacker) }
  }

  @Test func missingManifestStillUsesTheTrustedKey() throws {
    #expect(try VaultRecipientCheck.recipient(trusted: owner, manifestKey: nil) == owner)
  }
}
