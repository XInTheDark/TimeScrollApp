import Foundation
import CryptoKit

struct TSEHeader: Codable {
    let version: Int
    let alg: String
    let createdAtMs: Int64
    let width: Int
    let height: Int
    let mime: String
    let sealedFek: String // base64
    let nonce: String // base64 12 bytes
    /// v2: sender's ephemeral X25519 public key (base64) used to wrap the file key.
    let ephemeralPublicKey: String?
}

/// "TSE" envelopes: each payload gets a random AES-256-GCM file key; the file key is wrapped
/// to the vault's media public key (ephemeral X25519 + HKDF-SHA256 + AES-GCM), so files can be
/// encrypted while the vault is locked and only decrypted once it is unlocked.
///
/// Layout: "TSE1" | UInt32 BE header length | header JSON | ciphertext | 16-byte tag.
/// The header JSON is authenticated as associated data.
final class FileCrypter {
    static let shared = FileCrypter()
    private init() {}
    private let snapshotWriteLock = NSLock()

    private static let magic = Data("TSE1".utf8)
    private static let currentVersion = 2
    private static let wrapInfo = Data("TimeScroll.TSE.v2.fek".utf8)

    func encryptSnapshot(encoded: EncodedImage, timestampMs: Int64) throws -> URL {
        let blob = try seal(encoded.data, timestampMs: timestampMs, width: encoded.width, height: encoded.height,
                            mime: mimeFor(format: encoded.format))
        // Reserve the filename and write atomically while holding one process-wide lock.
        // Multiple capture streams can otherwise choose the same timestamp-based path.
        snapshotWriteLock.lock()
        defer { snapshotWriteLock.unlock() }
        return try StoragePaths.withSecurityScope {
            let (dir, base) = try outputLocation(timestampMs: timestampMs)
            let url = dir.appendingPathComponent(base + ".tse")
            let tmp = url.appendingPathExtension("tmp")
            try blob.write(to: tmp, options: .atomic)
            let _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return url
        }
    }

    func decryptImage(at url: URL) throws -> Data {
        try decryptTSE(at: url).1
    }

    /// Decrypts a .tse file, returning header + payload.
    func decryptTSE(at url: URL) throws -> (TSEHeader, Data) {
        let data = try StoragePaths.withSecurityScope { try Data(contentsOf: url, options: [.mappedIfSafe]) }
        return try open(data)
    }

    /// Reads the cleartext header without decrypting the payload.
    func peekTSEHeader(at url: URL) throws -> TSEHeader {
        let data = try StoragePaths.withSecurityScope { try Data(contentsOf: url, options: [.mappedIfSafe]) }
        return try Self.parse(data).header
    }

    /// Creates a TSE envelope for arbitrary data. Caller is responsible for writing to disk.
    func makeTSEBlob(data: Data, timestampMs: Int64, width: Int, height: Int, mime: String) throws -> Data {
        try seal(data, timestampMs: timestampMs, width: width, height: height, mime: mime)
    }

    /// Envelope for small records (e.g. the locked-capture ingest queue).
    func encryptData(_ data: Data, timestampMs: Int64) throws -> Data {
        try seal(data, timestampMs: timestampMs, width: 0, height: 0, mime: "application/json")
    }

    func decryptData(_ blob: Data) throws -> Data {
        try open(blob).1
    }

    // MARK: - Envelope

    private func seal(_ payload: Data, timestampMs: Int64, width: Int, height: Int, mime: String) throws -> Data {
        let recipient = try VaultKeys.shared.mediaPublicKey()
        let fek = SymmetricKey(size: .bits256)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let wrapKey = try Self.wrapKey(shared: ephemeral.sharedSecretFromKeyAgreement(with: recipient),
                                       ephemeral: ephemeral.publicKey, recipient: recipient)
        guard let sealedFek = try AES.GCM.seal(fek.withUnsafeBytes { Data($0) }, using: wrapKey).combined else {
            throw NSError(domain: "TS.TSE", code: -40)
        }
        let nonce = AES.GCM.Nonce()
        let header = TSEHeader(version: Self.currentVersion,
                               alg: "AES-256-GCM;X25519-HKDF-SHA256",
                               createdAtMs: timestampMs,
                               width: width,
                               height: height,
                               mime: mime,
                               sealedFek: sealedFek.base64EncodedString(),
                               nonce: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
                               ephemeralPublicKey: ephemeral.publicKey.rawRepresentation.base64EncodedString())
        let json = try JSONEncoder().encode(header)
        let box = try AES.GCM.seal(payload, using: fek, nonce: nonce, authenticating: json)
        var out = Self.magic
        var length = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(json)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    private func open(_ blob: Data) throws -> (TSEHeader, Data) {
        let (header, headerData, body) = try Self.parse(blob)
        guard header.version >= 2, let ephemeralB64 = header.ephemeralPublicKey,
              let ephemeralRaw = Data(base64Encoded: ephemeralB64) else {
            throw NSError(domain: "TS.TSE", code: -41, userInfo: [NSLocalizedDescriptionKey: "This file was encrypted by an older TimeScroll vault and cannot be opened."])
        }
        let privateKey = try VaultKeys.shared.mediaPrivateKey()
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let wrapKey = try Self.wrapKey(shared: privateKey.sharedSecretFromKeyAgreement(with: ephemeral),
                                       ephemeral: ephemeral, recipient: privateKey.publicKey)
        let fekRaw = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: header.sealedFek) ?? Data()), using: wrapKey)
        guard body.count >= 16 else { throw NSError(domain: "TS.TSE", code: -4) }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(base64Encoded: header.nonce) ?? Data()),
                                        ciphertext: body.prefix(body.count - 16),
                                        tag: body.suffix(16))
        return (header, try AES.GCM.open(box, using: SymmetricKey(data: fekRaw), authenticating: headerData))
    }

    private static func parse(_ data: Data) throws -> (header: TSEHeader, headerData: Data, body: Data) {
        guard data.count > 8, data.prefix(4) == magic else { throw NSError(domain: "TS.TSE", code: -2) }
        let length = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard data.count >= 8 + Int(length) else { throw NSError(domain: "TS.TSE", code: -3) }
        let headerData = data.subdata(in: 8..<(8 + Int(length)))
        let header = try JSONDecoder().decode(TSEHeader.self, from: headerData)
        return (header, headerData, Data(data.suffix(from: data.startIndex + 8 + Int(length))))
    }

    private static func wrapKey(shared: SharedSecret,
                                ephemeral: Curve25519.KeyAgreement.PublicKey,
                                recipient: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: ephemeral.rawRepresentation + recipient.rawRepresentation,
                                       sharedInfo: wrapInfo,
                                       outputByteCount: 32)
    }

    // MARK: - Paths

    private func outputLocation(timestampMs: Int64) throws -> (dir: URL, base: String) {
        let day = Date(timeIntervalSince1970: TimeInterval(timestampMs)/1000)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        let dir = StoragePaths.snapshotsDir().appendingPathComponent(df.string(from: day), isDirectory: true)
        if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        var name = "snap-\(timestampMs)"
        var candidate = dir.appendingPathComponent(name + ".tse")
        var idx = 2
        while fm.fileExists(atPath: candidate.path) {
            name = "snap-\(timestampMs)-\(idx)"; idx += 1
            candidate = dir.appendingPathComponent(name + ".tse")
        }
        return (dir, name)
    }

    private func mimeFor(format: String) -> String {
        switch format.lowercased() {
        case "heic": return "image/heic"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
