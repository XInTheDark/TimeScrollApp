import CryptoKit
import Foundation

/// In-memory key material for the running app. The media public key is always available once
/// a vault exists (captures encrypt while locked); the master secret is held only while unlocked.
final class VaultKeys {
    static let shared = VaultKeys()
    private init() {}

    private let lock = NSLock()
    private var secret: VaultSecret?
    private var publicKey: Curve25519.KeyAgreement.PublicKey?

    func install(_ secret: VaultSecret) {
        lock.lock(); defer { lock.unlock() }
        self.secret = secret
        publicKey = secret.mediaPrivateKey.publicKey
    }

    /// Forgets the secret (vault lock). The public key stays cached.
    func clearSecret() {
        lock.lock(); defer { lock.unlock() }
        secret = nil
    }

    /// Re-reads (and re-checks) the public key on next use (the storage folder, and its manifest, moved).
    func reloadPublicKey() {
        lock.lock(); defer { lock.unlock() }
        publicKey = secret?.mediaPrivateKey.publicKey
    }

    var databaseKey: Data? {
        lock.lock(); defer { lock.unlock() }
        return secret?.databaseKey
    }

    func mediaPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        lock.lock(); defer { lock.unlock() }
        if let publicKey { return publicKey }
        let raw = try VaultRecipientCheck.recipient(trusted: try Self.trustedPublicKey(),
                                                    manifestKey: VaultManifest.load()?.mediaPublicKey)
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        publicKey = key
        return key
    }

    /// The keychain-pinned public key. Vaults from before pinning derive it once from the
    /// keychain secret, which is equally outside the storage folder, and pin it.
    private static func trustedPublicKey() throws -> Data? {
        if let pinned = try VaultPublicKeyPin.load() { return pinned }
        guard let secret = try VaultKeychainStore.load() else { return nil }
        let raw = secret.mediaPrivateKey.publicKey.rawRepresentation
        do { try VaultPublicKeyPin.save(raw) } catch { fputs("[Vault] could not pin public key: \(error.localizedDescription)\n", stderr) }
        return raw
    }

    func mediaPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        guard let secret else {
            throw NSError(domain: "TS.Vault", code: 31, userInfo: [NSLocalizedDescriptionKey: "The vault is locked."])
        }
        return secret.mediaPrivateKey
    }
}
