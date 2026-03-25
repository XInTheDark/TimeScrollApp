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

    func replaceBoxes(snapshotId: Int64, boxes: [OCRLine]) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            var del: OpaquePointer?
            defer { sqlite3_finalize(del) }
            if sqlite3_prepare_v2(db, "DELETE FROM ts_ocr_boxes WHERE snapshot_id=?;", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_int64(del, 1, snapshotId)
                _ = sqlite3_step(del)
            }

            guard !boxes.isEmpty else { return }

            var ins: OpaquePointer?
            defer { sqlite3_finalize(ins) }
            if sqlite3_prepare_v2(db, "INSERT INTO ts_ocr_boxes(snapshot_id, text, x, y, w, h) VALUES(?, ?, ?, ?, ?, ?);", -1, &ins, nil) != SQLITE_OK {
                return
            }
            for b in boxes {
                sqlite3_bind_int64(ins, 1, snapshotId)
                sqlite3_bind_text(ins, 2, b.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(ins, 3, Double(b.box.origin.x))
                sqlite3_bind_double(ins, 4, Double(b.box.origin.y))
                sqlite3_bind_double(ins, 5, Double(b.box.size.width))
                sqlite3_bind_double(ins, 6, Double(b.box.size.height))
                _ = sqlite3_step(ins)
                sqlite3_reset(ins)
            }

            Self.pruneOldOCRBoxesIfConfigured(db: db, force: false)
        }
    }

    func pruneOldOCRBoxesIfConfigured(force: Bool = false) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            Self.pruneOldOCRBoxesIfConfigured(db: db, force: force)
        }
    }

    enum BoxMatch {
        case equals
        case prefix
        case contains
    }

    func boxes(for snapshotId: Int64, matching query: String?, match: BoxMatch = .contains) throws -> [CGRect] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var sql = "SELECT x,y,w,h FROM ts_ocr_boxes WHERE snapshot_id=?"
        if let q = query, !q.isEmpty {
            switch match {
            case .equals:
                sql += " AND text = ? COLLATE NOCASE"
            case .prefix, .contains:
                sql += " AND text LIKE ? COLLATE NOCASE"
            }
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        if let q = query, !q.isEmpty {
            switch match {
            case .equals:
                sqlite3_bind_text(stmt, 2, q, -1, SQLITE_TRANSIENT)
            case .prefix:
                let pat = "\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            case .contains:
                let pat = "%\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            }
        }
        var rects: [CGRect] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let x = sqlite3_column_double(stmt, 0)
            let y = sqlite3_column_double(stmt, 1)
            let w = sqlite3_column_double(stmt, 2)
            let h = sqlite3_column_double(stmt, 3)
            rects.append(CGRect(x: x, y: y, width: w, height: h))
        }
        return rects
        }
    }

    func boxesWithText(for snapshotId: Int64, matchingContains query: String?) throws -> [OCRBoxRow] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = "SELECT text,x,y,w,h FROM ts_ocr_boxes WHERE snapshot_id=?"
            if let q = query, !q.isEmpty {
                sql += " AND text LIKE ? COLLATE NOCASE"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
            sqlite3_bind_int64(stmt, 1, snapshotId)
            if let q = query, !q.isEmpty {
                let pat = "%\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            }
            var rows: [OCRBoxRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let x = sqlite3_column_double(stmt, 1)
                let y = sqlite3_column_double(stmt, 2)
                let w = sqlite3_column_double(stmt, 3)
                let h = sqlite3_column_double(stmt, 4)
                rows.append(OCRBoxRow(text: text, rect: CGRect(x: x, y: y, width: w, height: h)))
            }
            return rows
        }
    }

}

private extension DB {
    static func pruneOldOCRBoxesIfConfigured(db: OpaquePointer, force: Bool) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "settings.recentOCRBoxesOnly") != nil
            ? defaults.bool(forKey: "settings.recentOCRBoxesOnly")
            : false
        guard enabled else { return }

        let days = defaults.object(forKey: "settings.degradeAfterDays") != nil
            ? defaults.integer(forKey: "settings.degradeAfterDays")
            : SettingsStore.defaultDegradeAfterDays
        guard days > 0 else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lastRun = Int64(defaults.object(forKey: ocrBoxPruneWindowKey) != nil
            ? defaults.double(forKey: ocrBoxPruneWindowKey)
            : 0)
        if !force, nowMs - lastRun < ocrBoxPruneIntervalMs {
            return
        }

        let cutoffMs = nowMs - Int64(days) * 86_400_000
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        DELETE FROM ts_ocr_boxes
        WHERE snapshot_id IN (
            SELECT id
            FROM ts_snapshot
            WHERE started_at_ms < ?
        );
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, cutoffMs)
        if sqlite3_step(stmt) == SQLITE_DONE {
            defaults.set(Double(nowMs), forKey: ocrBoxPruneWindowKey)
        }
    }
}
