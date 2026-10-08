import CryptoKit
import Foundation

/// The vault's single master secret. Every key the vault uses is derived from it, so storing
/// (and recovering) this one value is enough to restore access to all encrypted data.
struct VaultSecret {
    static let byteCount = 32
    private static let salt = Data("TimeScroll.vault.v2".utf8)

    let rawData: Data

    static func generate() -> VaultSecret {
        VaultSecret(validated: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    init(rawData: Data) throws {
        guard rawData.count == Self.byteCount else {
            throw NSError(domain: "TS.Vault", code: 10, userInfo: [NSLocalizedDescriptionKey: "Vault key has an unexpected length."])
        }
        self.rawData = rawData
    }

    private init(validated rawData: Data) { self.rawData = rawData }

    /// SQLCipher key for the encrypted database.
    var databaseKey: Data { derive(info: "database") }

    /// Private half of the media key pair; the public half encrypts captures while locked.
    var mediaPrivateKey: Curve25519.KeyAgreement.PrivateKey {
        // Any 32 bytes form a valid X25519 private key (clamped by CryptoKit).
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: derive(info: "media-x25519"))
    }

    private func derive(info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rawData),
                               salt: Self.salt,
                               info: Data(info.utf8),
                               outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}
