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

    /// Re-reads the public key on next use (the storage folder, and its manifest, moved).
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
        guard let manifest = VaultManifest.load() else {
            throw NSError(domain: "TS.Vault", code: 30, userInfo: [NSLocalizedDescriptionKey: "The vault is not set up."])
        }
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: manifest.mediaPublicKey)
        publicKey = key
        return key
    }

    func mediaPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        guard let secret else {
            throw NSError(domain: "TS.Vault", code: 31, userInfo: [NSLocalizedDescriptionKey: "The vault is locked."])
        }
        return secret.mediaPrivateKey
    }
}
