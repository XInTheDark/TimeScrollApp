import Foundation
import CoreGraphics
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    private static let ocrBoxPruneWindowKey = "maintenance.lastOCRBoxPruneAtMs"
    private static let ocrBoxPruneIntervalMs: Int64 = 6 * 60 * 60 * 1000

    static func createOCRLayoutTableIfNeeded(db: OpaquePointer) {
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ts_ocr_layout (snapshot_id INTEGER PRIMARY KEY, data BLOB NOT NULL);", nil, nil, nil)
    }

    func replaceBoxes(snapshotId: Int64, boxes: [OCRLine]) throws {
        try withWriteSavepoint {
            try openIfNeeded()
            guard let db = db else { return }
            try Self.writeOCRLayout(snapshotId: snapshotId, boxes: boxes, db: db)
        }
    }

    /// Stores all OCR lines of a snapshot as one compressed blob (empty input removes it).
    static func writeOCRLayout(snapshotId: Int64, boxes: [OCRLine], db: OpaquePointer) throws {
        // Older captures kept one row per line; drop any for this snapshot.
        _ = sqlite3_exec(db, "DELETE FROM ts_ocr_boxes WHERE snapshot_id=\(snapshotId);", nil, nil, nil)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard let blob = OCRLayoutCodec.encode(boxes) else {
            _ = sqlite3_exec(db, "DELETE FROM ts_ocr_layout WHERE snapshot_id=\(snapshotId);", nil, nil, nil)
            return
        }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ts_ocr_layout(snapshot_id, data) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 12)
        }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 13) }
    }

    /// SQL deleting OCR layout data (both storage forms) for the selected snapshot ids.
    static func ocrLayoutDeletionSQL(snapshotIdsSQL: String) -> String {
        """
        DELETE FROM ts_ocr_layout WHERE snapshot_id IN (\(snapshotIdsSQL));
        DELETE FROM ts_ocr_boxes WHERE snapshot_id IN (\(snapshotIdsSQL));

        """
    }

    func pruneOldOCRBoxesIfConfigured(force: Bool = false) {
        let ranAtMs = try? onQueueSync { () -> Int64? in
            try openIfNeeded()
            guard let db = db else { return nil }
            return Self.pruneOldOCRBoxesIfConfigured(db: db, force: force)
        }
        // Record outside the DB queue: defaults writes post notifications synchronously.
        if let ranAtMs = ranAtMs ?? nil {
            UserDefaults.standard.set(Double(ranAtMs), forKey: Self.ocrBoxPruneWindowKey)
        }
    }

    func boxesWithText(for snapshotId: Int64, matchingContains query: String?) throws -> [OCRBoxRow] {
        let rows = try onReadQueueSync { db -> [OCRBoxRow] in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT data FROM ts_ocr_layout WHERE snapshot_id=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, snapshotId)
                if sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) {
                    let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                    return OCRLayoutCodec.decode(blob)
                }
            }
            return Self.legacyBoxes(snapshotId: snapshotId, db: db)
        }
        guard let query, !query.isEmpty else { return rows }
        return rows.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }
    }

    private static func legacyBoxes(snapshotId: Int64, db: OpaquePointer) -> [OCRBoxRow] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT text,x,y,w,h FROM ts_ocr_boxes WHERE snapshot_id=?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        var rows: [OCRBoxRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            rows.append(OCRBoxRow(text: text, rect: CGRect(x: sqlite3_column_double(stmt, 1),
                                                          y: sqlite3_column_double(stmt, 2),
                                                          width: sqlite3_column_double(stmt, 3),
                                                          height: sqlite3_column_double(stmt, 4))))
        }
        return rows
    }
}

private extension DB {
    /// Returns the run timestamp when a prune completed so the caller can record it.
    static func pruneOldOCRBoxesIfConfigured(db: OpaquePointer, force: Bool) -> Int64? {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "settings.recentOCRBoxesOnly") != nil
            ? defaults.bool(forKey: "settings.recentOCRBoxesOnly")
            : false
        guard enabled else { return nil }

        let days = defaults.object(forKey: "settings.degradeAfterDays") != nil
            ? defaults.integer(forKey: "settings.degradeAfterDays")
            : SettingsStore.defaultDegradeAfterDays
        guard days > 0 else { return nil }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lastRun = Int64(defaults.object(forKey: ocrBoxPruneWindowKey) != nil
            ? defaults.double(forKey: ocrBoxPruneWindowKey)
            : 0)
        if !force, nowMs - lastRun < ocrBoxPruneIntervalMs {
            return nil
        }

        let cutoffMs = nowMs - Int64(days) * 86_400_000
        let sql = ocrLayoutDeletionSQL(snapshotIdsSQL: "SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoffMs)")
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK ? nowMs : nil
    }
}
