import CommonCrypto
import CryptoKit
import Foundation

/// `Vault/vault-v2.json` in the storage root: the media public key (needed to encrypt while
/// locked) and the master secret sealed with the user's recovery passphrase. It travels with
/// the data when the storage folder moves.
struct VaultManifest: Codable {
    static let currentVersion = 2
    static let recoveryIterations = 600_000
    private static let recoveryAAD = Data("TimeScroll.vault.v2.recovery".utf8)
    private static let fileName = "vault-v2.json"

    let version: Int
    let createdAtMs: Int64
    let mediaPublicKey: Data
    let recoverySalt: Data
    let recoveryIterations: Int
    /// AES-GCM (combined form) of the master secret under the passphrase-derived key.
    let recoverySealedSecret: Data

    static func make(secret: VaultSecret, recoveryPassphrase: String) throws -> VaultManifest {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key = try passphraseKey(recoveryPassphrase, salt: salt, iterations: recoveryIterations)
        guard let sealed = try AES.GCM.seal(secret.rawData, using: key, authenticating: recoveryAAD).combined else {
            throw NSError(domain: "TS.Vault", code: 20, userInfo: [NSLocalizedDescriptionKey: "Could not seal the recovery copy."])
        }
        return VaultManifest(version: currentVersion,
                             createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                             mediaPublicKey: secret.mediaPrivateKey.publicKey.rawRepresentation,
                             recoverySalt: salt,
                             recoveryIterations: recoveryIterations,
                             recoverySealedSecret: sealed)
    }

    /// Recovers the master secret; throws for a wrong passphrase.
    func openRecovery(passphrase: String) throws -> VaultSecret {
        let key = try Self.passphraseKey(passphrase, salt: recoverySalt, iterations: recoveryIterations)
        do {
            let box = try AES.GCM.SealedBox(combined: recoverySealedSecret)
            return try VaultSecret(rawData: AES.GCM.open(box, using: key, authenticating: Self.recoveryAAD))
        } catch {
            throw NSError(domain: "TS.Vault", code: 21, userInfo: [NSLocalizedDescriptionKey: "The recovery passphrase is incorrect."])
        }
    }

    /// True when `secret` is the secret this vault was created with.
    func matches(_ secret: VaultSecret) -> Bool {
        secret.mediaPrivateKey.publicKey.rawRepresentation == mediaPublicKey
    }

    static var fileURL: URL { StoragePaths.vaultDir().appendingPathComponent(fileName) }

    static func load() -> VaultManifest? {
        StoragePaths.withSecurityScope {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(VaultManifest.self, from: data)
        }
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try StoragePaths.withSecurityScope {
            try FileManager.default.createDirectory(at: StoragePaths.vaultDir(), withIntermediateDirectories: true)
            try data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private static func passphraseKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                                     password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress,
                                     salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(iterations),
                                     &derived,
                                     derived.count)
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "TS.Vault", code: 22, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed."])
        }
        return SymmetricKey(data: derived)
    }
}
