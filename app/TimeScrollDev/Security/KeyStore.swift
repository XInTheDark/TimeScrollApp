import Foundation
import LocalAuthentication
import Security
import AppKit

final class KeyStore {
    static let shared = KeyStore()
    private init() {}

    private let kekTag = "com.muzhen.TimeScroll.kek".data(using: .utf8)!
    // Shared Keychain Access Group suffix (without the AppIdentifierPrefix).
    // This must match the "keychain-access-groups" entitlement present in both
    // the main app and the `timescroll-mcp` helper targets.
    private let accessGroupSuffix = "com.muzhen.TimeScroll.shared"

    // Resolve fully-qualified access groups we can use by reading entitlements at runtime
    // (ensures the TeamID/AppIdentifierPrefix is included correctly). We prioritize the
    // shared group, but also retain any app-specific groups so we can read legacy keys
    // created pre-sharing by the main app target.
    private lazy var accessibleAccessGroups: [String] = {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return [] }
        var groups: [String] = []
        if let val = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) {
            let append: (String) -> Void = { s in if !groups.contains(s) { groups.append(s) } }
            if let arr = val as? [String] {
                arr.forEach { append($0) }
            } else if CFGetTypeID(val) == CFArrayGetTypeID() {
                let cfArr = val as! CFArray
                for i in 0..<CFArrayGetCount(cfArr) {
                    if let s = unsafeBitCast(CFArrayGetValueAtIndex(cfArr, i), to: CFString.self) as String? {
                        append(s)
                    }
                }
            }
        }
        // Prioritize shared group first to prefer converged KEK
        groups.sort { lhs, rhs in
            let l = lhs.hasSuffix(accessGroupSuffix) ? 0 : 1
            let r = rhs.hasSuffix(accessGroupSuffix) ? 0 : 1
            if l != r { return l < r }
            return lhs < rhs
        }
        return groups
    }()
    private var dbKeyPath: URL {
        // Prefer the shared vault directory in the App Group container
        let dir = StoragePaths.sharedVaultDir()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("dbkey.sealed")
    }
    
    private var legacyDbKeyPath: URL {
        // The old location in the user-selected storage root
        return StoragePaths.vaultDir().appendingPathComponent("dbkey.sealed")
    }

    // MARK: KEK
    func ensureKEK() throws {
        // If the key already exists (shared group or legacy), nothing to do.
        if try loadPrivateKey(inSharedGroupFirst: true) != nil { return }

        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .devicePasscode],
            nil)!

        // Prefer generating the key inside the shared keychain access group so
        // both the app and helper can access the same key material.
        var commonAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: kekTag,
                kSecAttrAccessControl as String: access
            ]
        ]
        if let grp = accessibleAccessGroups.first(where: { $0.hasSuffix(accessGroupSuffix) }) {
            commonAttrs[kSecAttrAccessGroup as String] = grp
            var privAttrs = (commonAttrs[kSecPrivateKeyAttrs as String] as! [String: Any])
            privAttrs[kSecAttrAccessGroup as String] = grp
            commonAttrs[kSecPrivateKeyAttrs as String] = privAttrs
        }

        // Try Secure Enclave first
        var attrsSE = commonAttrs
        attrsSE[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        if SecKeyCreateRandomKey(attrsSE as CFDictionary, &error) == nil {
            // Fallback to software key (still within the shared access group)
            var attrsSW = commonAttrs
            attrsSW.removeValue(forKey: kSecAttrTokenID as String)
            guard SecKeyCreateRandomKey(attrsSW as CFDictionary, &error) != nil else {
                throw error!.takeRetainedValue() as Error
            }
        }
    }

    func publicKey() throws -> SecKey {
        guard let priv = try loadPrivateKey() else { throw NSError(domain: "TS.Key", code: -1) }
        return SecKeyCopyPublicKey(priv)!
    }

    private func baseKeyQuery(includeAccessGroup: Bool, group: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: kekTag,
            kSecReturnRef as String: true
        ]
        if includeAccessGroup {
            let grp = group ?? accessibleAccessGroups.first(where: { $0.hasSuffix(accessGroupSuffix) })
            q[kSecAttrAccessGroup as String] = grp
        }
        return q
    }

    private func loadPrivateKey(inSharedGroupFirst: Bool = true, context: LAContext? = nil) throws -> SecKey? {
        // Try multiple locations:
        // 1) Shared group (preferred)
        // 2) Other accessible groups (e.g., main app default) for legacy migration
        // 3) Process default (no group) as last resort
        var groupCandidates: [String?] = []
        if inSharedGroupFirst {
            if let shared = accessibleAccessGroups.first(where: { $0.hasSuffix(accessGroupSuffix) }) { groupCandidates.append(shared) }
            // Add other non-shared groups next
            for g in accessibleAccessGroups where !g.hasSuffix(accessGroupSuffix) { groupCandidates.append(g) }
        } else {
            // Start with process default, then try groups
            groupCandidates.append(nil)
            for g in accessibleAccessGroups { groupCandidates.append(g) }
        }
        
        // fputs("[KeyStore] loadPrivateKey candidates: \(groupCandidates.map { $0 ?? "nil" }.joined(separator: ", "))\n", stderr)

        for grp in groupCandidates {
            var item: CFTypeRef?
            var query = baseKeyQuery(includeAccessGroup: grp != nil, group: grp)
            if let ctx = context {
                query[kSecUseAuthenticationContext as String] = ctx
            }
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let found = item, CFGetTypeID(found) == SecKeyGetTypeID() {
                // fputs("[KeyStore] loadPrivateKey found key in group: \(grp ?? "nil")\n", stderr)
                return (found as! SecKey)
            }
            if status == errSecItemNotFound { continue }
            if status != errSecItemNotFound && status != errSecSuccess {
                fputs("[KeyStore] loadPrivateKey error in group \(grp ?? "nil"): \(status)\n", stderr)
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        return nil
    }

    func requestPrivateKeyAccess(presentingWindow: NSWindow?) async throws -> SecKey {
        try ensureKEK()
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
        // Load key using the authenticated context
        guard let priv = try loadPrivateKey(context: ctx) else { throw NSError(domain: "TS.Key", code: -2) }
        return priv
    }
    
    func authenticateAndUnwrapDbKey(presentingWindow: NSWindow? = nil) async throws -> Data {
        try ensureKEK()
        let ctx = LAContext()
        ctx.localizedReason = "Unlock TimeScroll Vault"
        var authError: NSError?
        if !ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            fputs("[KeyStore] canEvaluatePolicy failed: \(authError?.localizedDescription ?? "unknown")\n", stderr)
            throw authError ?? NSError(domain: "TS.Key", code: -3)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock TimeScroll Vault") { ok, err in
                if ok {
                    fputs("[KeyStore] evaluatePolicy success\n", stderr)
                    cont.resume()
                } else {
                    fputs("[KeyStore] evaluatePolicy failed: \(err?.localizedDescription ?? "unknown")\n", stderr)
                    cont.resume(throwing: err ?? NSError(domain: "TS.Key", code: -4))
                }
            }
        }
        return try unwrapDbKey(context: ctx)
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
        // Write to App Group container (no security scope needed for writing to shared container)
        try sealed.write(to: dbKeyPath, options: .atomic)
    }

    func unwrapDbKey(context: LAContext? = nil) throws -> Data {
        try ensureKEK()
        
        // Migration: Check if key exists in new location. If not, and exists in old location, migrate it.
        let fm = FileManager.default
        if !fm.fileExists(atPath: dbKeyPath.path) && fm.fileExists(atPath: legacyDbKeyPath.path) {
            // Attempt to copy from legacy path to new path
            // We need security scope for the legacy path (it's in user storage)
            try StoragePaths.withSecurityScope {
                try fm.copyItem(at: legacyDbKeyPath, to: dbKeyPath)
            }
            fputs("[KeyStore] Migrated dbkey.sealed to shared container\n", stderr)
        }
        
        // Read from the (now potentially migrated) path.
        // since we moved it to App Group, we can just read it directly.
        let sealed = try Data(contentsOf: dbKeyPath)

        // 1) Try with shared-group key first
        if let sharedPriv = try loadPrivateKey(inSharedGroupFirst: true, context: context) {
            var err: Unmanaged<CFError>?
            if let clear = SecKeyCreateDecryptedData(sharedPriv, .eciesEncryptionCofactorX963SHA256AESGCM, sealed as CFData, &err) as Data? {
                fputs("[KeyStore] unwrapDbKey success with shared key\n", stderr)
                return clear
            } else {
                fputs("[KeyStore] unwrapDbKey shared key failed: \(err?.takeUnretainedValue().localizedDescription ?? "unknown")\n", stderr)
            }
            // If it failed due to wrong key, try legacy key path next.
        } else {
            fputs("[KeyStore] unwrapDbKey no shared key found\n", stderr)
        }

        // 2) Fallback: try legacy (no-access-group) key, and if it works, re-wrap
        guard let legacyPriv = try loadPrivateKey(inSharedGroupFirst: false, context: context) else {
            fputs("[KeyStore] unwrapDbKey no legacy key found\n", stderr)
            throw NSError(domain: "TS.Key", code: -10)
        }
        var err: Unmanaged<CFError>?
        guard let clear = SecKeyCreateDecryptedData(legacyPriv, .eciesEncryptionCofactorX963SHA256AESGCM, sealed as CFData, &err) as Data? else {
            fputs("[KeyStore] unwrapDbKey legacy key failed: \(err?.takeUnretainedValue().localizedDescription ?? "unknown")\n", stderr)
            throw err!.takeRetainedValue() as Error
        }
        fputs("[KeyStore] unwrapDbKey success with legacy key\n", stderr)

        // Ensure a shared-group key exists
        try ensureKEK()
        let sharedPub = try publicKey()
        if let rewrapped = SecKeyCreateEncryptedData(sharedPub, .eciesEncryptionCofactorX963SHA256AESGCM, clear as CFData, &err) as Data? {
            // Atomically replace sealed blob so future reads use shared-group key
            // Write to App Group container
            try rewrapped.write(to: dbKeyPath, options: .atomic)
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
