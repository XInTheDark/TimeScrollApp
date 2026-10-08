import Foundation
import Compression
import CryptoKit
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    /// Stores a snapshot's text and indexes it. `indexedContent` (when given) is what goes into
    /// the full-text index instead of the whole text, e.g. only lines new since an anchor snapshot.
    func updateFTS(rowId: Int64, content: String, indexedContent: String? = nil) throws {
        try withWriteSavepoint {
            try openIfNeeded()
            guard let db = db else { return }
            try storeTextArtifacts(rowId: rowId, content: content, indexedContent: indexedContent, db: db)
        }
    }

    func textContent(snapshotId: Int64) throws -> String? {
        try onReadQueueSync { db -> String? in
            var cache: [Int64: String?] = [:]
            var visited: Set<Int64> = []
            return try resolvedTextContent(snapshotId: snapshotId, db: db, visited: &visited, cache: &cache)
        }
    }

    func ftsCount() throws -> Int {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM ts_snapshot WHERE text_store_id IS NOT NULL OR text_ref_id IS NOT NULL;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func hydrateSearchResultContents(_ results: [SearchResult]) throws -> [SearchResult] {
        guard !results.isEmpty else { return results }
        return try onReadQueueSync { db in

            var cache: [Int64: String?] = [:]
            return try results.map { result in
                var visited: Set<Int64> = []
                let content = try resolvedTextContent(snapshotId: result.id, db: db, visited: &visited, cache: &cache) ?? result.content
                return SearchResult(id: result.id,
                                    startedAtMs: result.startedAtMs,
                                    endedAtMs: result.endedAtMs,
                                    path: result.path,
                                    appBundleId: result.appBundleId,
                                    appName: result.appName,
                                    thumbPath: result.thumbPath,
                                    captureKind: result.captureKind,
                                    audioSourceKind: result.audioSourceKind,
                                    audioAssetId: result.audioAssetId,
                                    audioDurationMs: result.audioDurationMs,
                                    content: content)
            }
        }
    }

}

/// Text storage internals, shared with `TextIndexBackfill`.
extension DB {
    func storeTextArtifacts(rowId: Int64, content: String, indexedContent: String? = nil, db: OpaquePointer) throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try clearTextArtifacts(rowId: rowId, clearReference: false, db: db)
            return
        }

        let stored = TextStorageCodec.encode(content)
        let storeId = try upsertTextStore(payload: stored, db: db)
        try updateSnapshotTextStoreId(rowId: rowId, textStoreId: storeId, db: db)
        // Full text lives once in ts_text_store; the contentless index only holds postings.
        deleteLegacyPreviewText(rowId: rowId, db: db)
        try Self.indexText(rowId: rowId, content: indexedContent ?? content, db: db)
    }

    func resolvedTextContent(snapshotId: Int64,
                             db: OpaquePointer,
                             visited: inout Set<Int64>,
                             cache: inout [Int64: String?]) throws -> String? {
        if let cached = cache[snapshotId] {
            return cached
        }
        guard visited.insert(snapshotId).inserted else { return nil }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT text_ref_id, text_store_id FROM ts_snapshot WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let refId = sqlite3_column_int64(stmt, 0)
        let storeId = sqlite3_column_int64(stmt, 1)

        let content: String?
        if refId > 0 {
            content = try resolvedTextContent(snapshotId: refId, db: db, visited: &visited, cache: &cache)
        } else if storeId > 0, let restored = loadStoredText(textStoreId: storeId, db: db) {
            content = restored
        } else {
            content = previewText(rowId: snapshotId, db: db)
        }

        cache[snapshotId] = content
        return content
    }

    func upsertTextStore(payload: TextStorageCodec.Payload, db: OpaquePointer) throws -> Int64 {
        let sha = payload.sha256

        var lookup: OpaquePointer?
        defer { sqlite3_finalize(lookup) }
        if sqlite3_prepare_v2(db, "SELECT id FROM ts_text_store WHERE sha256=? LIMIT 1;", -1, &lookup, nil) != SQLITE_OK {
            throw NSError(domain: "TS.DB", code: 301)
        }
        sqlite3_bind_text(lookup, 1, sha, -1, SQLITE_TRANSIENT)
        if sqlite3_step(lookup) == SQLITE_ROW {
            return sqlite3_column_int64(lookup, 0)
        }
        sqlite3_finalize(lookup)
        lookup = nil

        var insert: OpaquePointer?
        defer { sqlite3_finalize(insert) }
        let sql = "INSERT INTO ts_text_store(sha256, codec, original_bytes, data) VALUES(?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 302)
        }
        sqlite3_bind_text(insert, 1, sha, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(insert, 2, payload.codec, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insert, 3, Int64(payload.originalBytes))
        _ = payload.data.withUnsafeBytes { raw in
            sqlite3_bind_blob(insert, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(insert) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 303)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func updateSnapshotTextStoreId(rowId: Int64, textStoreId: Int64, db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE ts_snapshot SET text_ref_id=NULL, text_store_id=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 304)
        }
        sqlite3_bind_int64(stmt, 1, textStoreId)
        sqlite3_bind_int64(stmt, 2, rowId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 305)
        }
    }

    /// Removes a pre-text-store preview row, if the legacy table still exists.
    func deleteLegacyPreviewText(rowId: Int64, db: OpaquePointer) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM ts_text WHERE rowid=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, rowId)
        _ = sqlite3_step(stmt)
    }

    func clearTextArtifacts(rowId: Int64, clearReference: Bool, db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = clearReference
            ? "UPDATE ts_snapshot SET text_ref_id=NULL, text_store_id=NULL WHERE id=?;"
            : "UPDATE ts_snapshot SET text_store_id=NULL WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 314)
        }
        sqlite3_bind_int64(stmt, 1, rowId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 315)
        }
        deleteLegacyPreviewText(rowId: rowId, db: db)
        try Self.removeFromTextIndex(rowId: rowId, db: db)
    }

    func loadStoredText(textStoreId: Int64, db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT codec, original_bytes, data FROM ts_text_store WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, textStoreId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let codec = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? TextStorageCodec.rawCodecIdentifier
        let originalBytes = Int(sqlite3_column_int64(stmt, 1))
        let blobLength = Int(sqlite3_column_bytes(stmt, 2))
        let data: Data
        if let blob = sqlite3_column_blob(stmt, 2), blobLength > 0 {
            data = Data(bytes: blob, count: blobLength)
        } else {
            data = Data()
        }
        return TextStorageCodec.decode(data, originalBytes: originalBytes, codec: codec)
    }

    func previewText(rowId: Int64, db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT content FROM ts_text WHERE rowid=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_int64(stmt, 1, rowId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }
}

enum TextStorageCodec {
    struct Payload {
        let sha256: String
        let codec: String
        let originalBytes: Int
        let data: Data
    }

    static let compressedCodecIdentifier = "lzfse"
    static let rawCodecIdentifier = "identity"

    static func hash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ text: String) -> Payload {
        let source = Data(text.utf8)
        let sha = hash(for: text)
        guard !source.isEmpty else {
            return Payload(sha256: sha,
                           codec: rawCodecIdentifier,
                           originalBytes: 0,
                           data: Data())
        }

        if let compressed = compressBuffer(source), compressed.count < source.count {
            return Payload(sha256: sha,
                           codec: compressedCodecIdentifier,
                           originalBytes: source.count,
                           data: compressed)
        }

        return Payload(sha256: sha,
                       codec: rawCodecIdentifier,
                       originalBytes: source.count,
                       data: source)
    }

    static func decode(_ data: Data, originalBytes: Int, codec: String) -> String? {
        switch codec {
        case compressedCodecIdentifier:
            if originalBytes == 0 { return "" }
            guard let clear = decompressBuffer(data, originalBytes: originalBytes) else { return nil }
            return String(data: clear, encoding: .utf8)
        case rawCodecIdentifier:
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private static func compressBuffer(_ input: Data) -> Data? {
        if input.isEmpty { return Data() }

        let algorithm = COMPRESSION_LZFSE
        return input.withUnsafeBytes { sourceRaw -> Data? in
            guard let sourceBase = sourceRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let scratchSize = compression_encode_scratch_buffer_size(algorithm)
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
            defer { scratch.deallocate() }

            var capacity = max(64, input.count / 2)
            let maxCapacity = max(input.count + 256, 512)
            while capacity <= maxCapacity {
                let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { destination.deallocate() }
                let written = compression_encode_buffer(destination,
                                                        capacity,
                                                        sourceBase,
                                                        input.count,
                                                        scratch,
                                                        algorithm)
                if written > 0 {
                    return Data(bytes: destination, count: written)
                }
                capacity *= 2
            }
            return nil
        }
    }

    private static func decompressBuffer(_ input: Data, originalBytes: Int) -> Data? {
        if input.isEmpty { return Data() }

        let algorithm = COMPRESSION_LZFSE
        return input.withUnsafeBytes { sourceRaw -> Data? in
            guard let sourceBase = sourceRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let capacity = max(originalBytes, 64)
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = compression_decode_buffer(destination,
                                                    capacity,
                                                    sourceBase,
                                                    input.count,
                                                    nil,
                                                    algorithm)
            guard written > 0 || originalBytes == 0 else { return nil }
            return Data(bytes: destination, count: written)
        }
    }
}

enum IndexedTextProjection {
    static let maxIndexedCharacters = 48_000

    /// The normalized text that is written to the full-text index (capped in size).
    static func indexDocument(from text: String) -> String {
        normalizeForIndexing(text)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeForIndexing(_ text: String) -> String {
        var lines: [String] = []
        lines.reserveCapacity(64)

        text.enumerateLines { rawLine, _ in
            let normalized = normalizeLine(rawLine)
            if !normalized.isEmpty {
                lines.append(normalized)
            }
        }

        if lines.isEmpty {
            return String(collapseWhitespace(text).prefix(maxIndexedCharacters))
        }

        var combined = lines.joined(separator: "\n")
        if combined.count > maxIndexedCharacters {
            combined = String(combined.prefix(maxIndexedCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return combined
    }

    private static func normalizeLine(_ line: String) -> String {
        line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
