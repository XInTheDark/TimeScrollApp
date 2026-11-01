import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    /// Stems (see `OrphanSegmentPlanner.stem`) of every HEVC segment a snapshot row references.
    /// Throws when the database cannot be read (e.g. the vault is locked), so a caller never
    /// mistakes that for "nothing is referenced".
    func referencedSegmentStems() throws -> Set<String> {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { throw NSError(domain: "TS.DB", code: 90, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT path FROM ts_snapshot WHERE path LIKE '%seg-%';", -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "TS.DB", code: 91, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            var stems = Set<String>()
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0),
                   let stem = OrphanSegmentPlanner.stem(ofFileName: (String(cString: c) as NSString).lastPathComponent) {
                    stems.insert(stem)
                }
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else {
                throw NSError(domain: "TS.DB", code: 92, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            return stems
        }
    }
}
