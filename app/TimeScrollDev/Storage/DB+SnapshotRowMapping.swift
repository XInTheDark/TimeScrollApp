import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

struct SearchRowUnified: Hashable {
    let id: Int64
    let startedAtMs: Int64
    let endedAtMs: Int64?
    let path: String
    let appBundleId: String?
    let appName: String?
    let thumbPath: String?
    let captureKind: CaptureKind
    let audioSourceKind: AudioSourceKind?
    let audioAssetId: Int64?
    let audioDurationMs: Int64?
    let content: String?
}

extension DB {
    func makeSnapshotMeta(from row: SearchRowUnified) -> SnapshotMeta {
        SnapshotMeta(id: row.id,
                     startedAtMs: row.startedAtMs,
                     endedAtMs: row.endedAtMs,
                     path: row.path,
                     appBundleId: row.appBundleId,
                     appName: row.appName,
                     thumbPath: row.thumbPath,
                     captureKind: row.captureKind,
                     audioSourceKind: row.audioSourceKind,
                     audioAssetId: row.audioAssetId,
                     audioDurationMs: row.audioDurationMs)
    }

    func makeSearchResult(from row: SearchRowUnified, contentOverride: String? = nil) -> SearchResult {
        SearchResult(id: row.id,
                     startedAtMs: row.startedAtMs,
                     endedAtMs: row.endedAtMs,
                     path: row.path,
                     appBundleId: row.appBundleId,
                     appName: row.appName,
                     thumbPath: row.thumbPath,
                     captureKind: row.captureKind,
                     audioSourceKind: row.audioSourceKind,
                     audioAssetId: row.audioAssetId,
                     audioDurationMs: row.audioDurationMs,
                     content: contentOverride ?? row.content ?? "")
    }

    func makeSearchRowUnified(from stmt: OpaquePointer?, contentColumn: Int32? = nil) -> SearchRowUnified? {
        guard let stmt,
              let pathC = sqlite3_column_text(stmt, 3) else {
            return nil
        }

        let id = sqlite3_column_int64(stmt, 0)
        let startedAtMs = sqlite3_column_int64(stmt, 1)
        let endedAtMs = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
        let path = String(cString: pathC)
        let appBundleId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let appName = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let thumbPath = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let captureKind = captureKindValue(from: sqlite3_column_text(stmt, 7))
        let audioSourceKind = audioSourceKindValue(from: sqlite3_column_text(stmt, 8))
        let audioAssetId = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 9)
        let audioDurationMs: Int64? = {
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                return sqlite3_column_int64(stmt, 10)
            }
            if captureKind == .audio, let endedAtMs {
                return max(0, endedAtMs - startedAtMs)
            }
            return nil
        }()
        let content = contentColumn.flatMap { sqlite3_column_text(stmt, $0).map { String(cString: $0) } } ?? nil

        return SearchRowUnified(id: id,
                                startedAtMs: startedAtMs,
                                endedAtMs: endedAtMs,
                                path: path,
                                appBundleId: appBundleId,
                                appName: appName,
                                thumbPath: thumbPath,
                                captureKind: captureKind,
                                audioSourceKind: audioSourceKind,
                                audioAssetId: audioAssetId,
                                audioDurationMs: audioDurationMs,
                                content: content)
    }
}
