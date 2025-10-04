import Foundation
import LocalAuthentication
import Security
import AppKit

final class KeyStore {
    static let shared = KeyStore()
    private init() {}

    private let kekTag = "com.muzhen.TimeScroll.kek".data(using: .utf8)!
    private var dbKeyPath: URL {
        let dir = StoragePaths.vaultDir()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("dbkey.sealed")
    }

    // MARK: KEK
    func ensureKEK() throws {
        if try loadPrivateKey() != nil { return }
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .devicePasscode],
            nil)!
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: kekTag,
                kSecAttrAccessControl as String: access
            ]
        ]
        if SecKeyCreateRandomKey(attrs as CFDictionary, &error) == nil {
            // Fallback to software key if Secure Enclave unavailable (omit token id)
            let attrsSW: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: kekTag,
                    kSecAttrAccessControl as String: access
                ]
            ]
            guard SecKeyCreateRandomKey(attrsSW as CFDictionary, &error) != nil else {
                throw error!.takeRetainedValue() as Error
            }
        }
    }

    func publicKey() throws -> SecKey {
        guard let priv = try loadPrivateKey() else { throw NSError(domain: "TS.Key", code: -1) }
        return SecKeyCopyPublicKey(priv)!
    }

    private func loadPrivateKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: kekTag,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return (item as! SecKey)
    }

    func requestPrivateKeyAccess(presentingWindow: NSWindow?) async throws -> SecKey {
        try ensureKEK()
        guard let priv = try loadPrivateKey() else { throw NSError(domain: "TS.Key", code: -2) }
        // Evaluate LA to ensure we can use the key without extra prompts for a short session
        let ctx = LAContext()
        ctx.localizedReason = "Unlock TimeScroll Vault"
        var authError: NSError?
        if !ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            throw authError ?? NSError(domain: "TS.Key", code: -3)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock TimeScroll Vault") { ok, err in
                if ok { cont.resume() } else { cont.resume(throwing: err ?? NSError(domain: "TS.Key", code: -4)) }
            }
        }
        // Do a lightweight no-op private key use by unwrapping an empty blob (or just return key)
        return priv
    }

    // Non-async accessor for use in background contexts where LA prompting will occur on key use
    func currentPrivateKey() throws -> SecKey {
        try ensureKEK()
        guard let priv = try loadPrivateKey() else { throw NSError(domain: "TS.Key", code: -2) }
        return priv
    }

    // MARK: DB key
    func createAndWrapDbKeyIfMissing() throws {
        if FileManager.default.fileExists(atPath: dbKeyPath.path) { return }
        try ensureKEK()
        let dbKey = randomBytes(count: 32)
        let pub = try publicKey()
        var err: Unmanaged<CFError>?
        guard let sealed = SecKeyCreateEncryptedData(pub, .eciesEncryptionCofactorX963SHA256AESGCM, dbKey as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        try StoragePaths.withSecurityScope { try sealed.write(to: dbKeyPath, options: .atomic) }
    }

    func unwrapDbKey() throws -> Data {
        try ensureKEK()
        guard let priv = try loadPrivateKey() else { throw NSError(domain: "TS.Key", code: -10) }
        let sealed = try StoragePaths.withSecurityScope { try Data(contentsOf: dbKeyPath) }
        var err: Unmanaged<CFError>?
        guard let clear = SecKeyCreateDecryptedData(priv, .eciesEncryptionCofactorX963SHA256AESGCM, sealed as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        return clear
    }

    func forgetSession() {
        // Nothing to do; LA session expires naturally
    }

    // MARK: Utils
    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(rc == errSecSuccess)
        return Data(bytes)
    }
}
