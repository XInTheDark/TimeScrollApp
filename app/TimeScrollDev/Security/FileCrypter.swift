import Foundation
import CryptoKit
import Security

struct TSEHeader: Codable {
    let version: Int
    let alg: String
    let createdAtMs: Int64
    let width: Int
    let height: Int
    let mime: String
    let sealedFek: String // base64
    let nonce: String // base64 12 bytes
}

final class FileCrypter {
    static let shared = FileCrypter()
    private init() {}

    func encryptSnapshot(encoded: EncodedImage, timestampMs: Int64) throws -> URL {
    let fek = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(encoded.data, using: fek, nonce: nonce)
        // Wrap FEK with KEK public key
    let pub = try KeyStore.shared.publicKey()
    let fekData = fek.withUnsafeBytes { Data($0) }
        var err: Unmanaged<CFError>?
        guard let sealedFek = SecKeyCreateEncryptedData(pub, .eciesEncryptionCofactorX963SHA256AESGCM, fekData as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let header = TSEHeader(
            version: 1,
            alg: "AES-256-GCM",
            createdAtMs: timestampMs,
            width: encoded.width,
            height: encoded.height,
            mime: mimeFor(format: encoded.format),
            sealedFek: sealedFek.base64EncodedString(),
            nonce: nonce.withUnsafeBytes { Data($0) }.base64EncodedString()
        )

        let json = try JSONEncoder().encode(header)
        var blob = Data()
        blob.append("TSE1".data(using: .utf8)!)
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
        blob.append(json)
        // CryptoKit provides ciphertext and tag explicitly when nonce provided
    blob.append(sealedBox.ciphertext)
    sealedBox.tag.withUnsafeBytes { blob.append(contentsOf: $0) }

        // Write atomically to Snapshots dir with .tse
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
        let data = try StoragePaths.withSecurityScope { try Data(contentsOf: url) }
        guard data.count > 8 else { throw NSError(domain: "TS.TSE", code: -1) }
        let magic = String(data: data.prefix(4), encoding: .utf8)
        guard magic == "TSE1" else { throw NSError(domain: "TS.TSE", code: -2) }
        let lenBE = data.subdata(in: 4..<8)
        let len = lenBE.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard data.count >= 8 + Int(len) else { throw NSError(domain: "TS.TSE", code: -3) }
        let headerData = data.subdata(in: 8..<(8+Int(len)))
        let header = try JSONDecoder().decode(TSEHeader.self, from: headerData)
        let body = data.suffix(from: 8 + Int(len))

    // Unwrap FEK
    let sealedFek = Data(base64Encoded: header.sealedFek) ?? Data()
    // Use synchronous key access; SecKey operations will prompt if necessary
    let priv = try KeyStore.shared.currentPrivateKey()
        var err: Unmanaged<CFError>?
        guard let fekRaw = SecKeyCreateDecryptedData(priv, .eciesEncryptionCofactorX963SHA256AESGCM, sealedFek as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let fek = SymmetricKey(data: fekRaw)
        let nonceData = Data(base64Encoded: header.nonce) ?? Data()
        let nonce = try AES.GCM.Nonce(data: nonceData)
        // body = ciphertext + tag (16)
        guard body.count >= 16 else { throw NSError(domain: "TS.TSE", code: -4) }
        let cipher = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
        let clear = try AES.GCM.open(sealed, using: fek)
        return clear
    }

    // MARK: - Generic data envelope (.iq1)
    func encryptData(_ data: Data, timestampMs: Int64) throws -> Data {
        let fek = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: fek, nonce: nonce)
        let pub = try KeyStore.shared.publicKey()
        let fekData = fek.withUnsafeBytes { Data($0) }
        var err: Unmanaged<CFError>?
        guard let sealedFek = SecKeyCreateEncryptedData(pub, .eciesEncryptionCofactorX963SHA256AESGCM, fekData as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let header = TSEHeader(
            version: 1,
            alg: "AES-256-GCM",
            createdAtMs: timestampMs,
            width: 0, height: 0,
            mime: "application/json",
            sealedFek: sealedFek.base64EncodedString(),
            nonce: nonce.withUnsafeBytes { Data($0) }.base64EncodedString()
        )
        let json = try JSONEncoder().encode(header)
        var out = Data()
        out.append("TSE1".data(using: .utf8)!)
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(json)
    out.append(sealedBox.ciphertext)
    sealedBox.tag.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    func decryptData(_ blob: Data) throws -> Data {
        guard blob.count > 8 else { throw NSError(domain: "TS.TSE", code: -11) }
        let magic = String(data: blob.prefix(4), encoding: .utf8)
        guard magic == "TSE1" else { throw NSError(domain: "TS.TSE", code: -12) }
        let lenBE = blob.subdata(in: 4..<8)
        let len = lenBE.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard blob.count >= 8 + Int(len) else { throw NSError(domain: "TS.TSE", code: -13) }
        let headerData = blob.subdata(in: 8..<(8+Int(len)))
        let header = try JSONDecoder().decode(TSEHeader.self, from: headerData)
        let body = blob.suffix(from: 8 + Int(len))
    let sealedFek = Data(base64Encoded: header.sealedFek) ?? Data()
    let priv = try KeyStore.shared.currentPrivateKey()
        var err: Unmanaged<CFError>?
        guard let fekRaw = SecKeyCreateDecryptedData(priv, .eciesEncryptionCofactorX963SHA256AESGCM, sealedFek as CFData, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let fek = SymmetricKey(data: fekRaw)
        let nonceData = Data(base64Encoded: header.nonce) ?? Data()
        let nonce = try AES.GCM.Nonce(data: nonceData)
        guard body.count >= 16 else { throw NSError(domain: "TS.TSE", code: -14) }
        let cipher = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
        return try AES.GCM.open(sealed, using: fek)
    }

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
