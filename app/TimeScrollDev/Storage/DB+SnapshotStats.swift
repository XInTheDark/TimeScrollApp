import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Snapshot count and the media bytes they occupy.
struct SnapshotStorage: Equatable, Sendable {
  var count: Int
  var bytes: Int64

  static let empty = SnapshotStorage(count: 0, bytes: 0)
}

extension DB {
    func snapshotCount() throws -> Int {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_snapshot;", -1, &stmt, nil) != SQLITE_OK { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Storage of the snapshots taken at or after `sinceMs`, or of all snapshots when it is nil.
    func snapshotStorage(sinceMs: Int64?) throws -> SnapshotStorage {
        let scan = try onReadQueueSync { db in
            try Self.snapshotStorageScan(sinceMs: sinceMs, db: db)
        }
        // Touches the disk, so it stays off the read connection's queue.
        let unsized = scan.unsizedPaths.reduce(Int64(0)) { $0 &+ Self.fileSize(forSnapshotPath: $1) }
        return SnapshotStorage(count: scan.count, bytes: scan.recordedBytes &+ unsized)
    }

    /// Videos are shared by many snapshots, so bytes are counted once per path. A video still being
    /// written has no recorded size yet; those paths are returned for measuring on disk.
    static func snapshotStorageScan(sinceMs: Int64?, db: OpaquePointer) throws -> (count: Int, recordedBytes: Int64, unsizedPaths: [String]) {
        let lowerBound = sinceMs ?? Int64.min
        let sql = """
        SELECT path, MAX(COALESCE(bytes, 0)), COUNT(*) FROM ts_snapshot
        WHERE started_at_ms >= ? GROUP BY path;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 810) }
        sqlite3_bind_int64(stmt, 1, lowerBound)
        var count = 0
        var recordedBytes: Int64 = 0
        var unsizedPaths: [String] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            count += Int(sqlite3_column_int64(stmt, 2))
            let bytes = sqlite3_column_int64(stmt, 1)
            if bytes > 0 {
                recordedBytes &+= bytes
            } else if let path = sqlite3_column_text(stmt, 0) {
                unsizedPaths.append(String(cString: path))
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 811) }
        return (count, recordedBytes, unsizedPaths)
    }

    private static func fileSize(forSnapshotPath path: String) -> Int64 {
        var size: Int64 = 0
        StoragePaths.withSecurityScope {
            let u = URL(fileURLWithPath: path)
            if let vals = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
                size = Int64(vals.fileSize ?? 0)
            } else if u.pathExtension.lowercased() == "tse" {
                let mov = u.deletingPathExtension().appendingPathExtension("mov")
                if let vals2 = try? mov.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals2.isRegularFile == true {
                    size = Int64(vals2.fileSize ?? 0)
                }
            }
        }
        return size
    }
}
