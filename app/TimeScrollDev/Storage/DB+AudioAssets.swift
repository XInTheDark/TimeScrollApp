import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

struct AudioAssetRecord: Identifiable, Hashable {
    let id: Int64
    let startedAtMs: Int64
    let endedAtMs: Int64
    let path: String
    let sourceKind: AudioSourceKind
    let bytes: Int64?
    let durationMs: Int64?
    let mime: String
    let sampleRate: Int?
    let channels: Int?
    let transcriptSegments: [AudioTranscriptSegment]
    let transcriptionStatus: AudioTranscriptionStatus
    let transcriptionError: String?
    let transcriptionModelID: String?
}

struct AudioPersistenceIDs: Sendable {
    let assetID: Int64
    let snapshotID: Int64
}

struct AudioTranscriptionJob: Sendable {
    let snapshotID: Int64
    let asset: AudioAssetRecord
}

extension DB {
    @discardableResult
    func insertAudioAsset(startedAtMs: Int64,
                          endedAtMs: Int64,
                          path: String,
                          sourceKind: AudioSourceKind,
                          bytes: Int64?,
                          durationMs: Int64?,
                          mime: String,
                          sampleRate: Int?,
                          channels: Int?,
                          transcriptSegments: [AudioTranscriptSegment],
                          transcriptionStatus: AudioTranscriptionStatus = .completed,
                          transcriptionError: String? = nil,
                          transcriptionModelID: String? = nil) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { throw NSError(domain: "TS.DB", code: 500) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT INTO ts_audio_asset(started_at_ms, ended_at_ms, path, source_kind, bytes, duration_ms, mime, sample_rate, channels, transcript_json, transcription_status, transcription_error, transcription_model_id)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "TS.DB", code: 501)
            }
            sqlite3_bind_int64(stmt, 1, startedAtMs)
            sqlite3_bind_int64(stmt, 2, endedAtMs)
            sqlite3_bind_text(stmt, 3, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, sourceKind.rawValue, -1, SQLITE_TRANSIENT)
            if let bytes { sqlite3_bind_int64(stmt, 5, bytes) } else { sqlite3_bind_null(stmt, 5) }
            if let durationMs { sqlite3_bind_int64(stmt, 6, durationMs) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_bind_text(stmt, 7, mime, -1, SQLITE_TRANSIENT)
            if let sampleRate { sqlite3_bind_int(stmt, 8, Int32(sampleRate)) } else { sqlite3_bind_null(stmt, 8) }
            if let channels { sqlite3_bind_int(stmt, 9, Int32(channels)) } else { sqlite3_bind_null(stmt, 9) }
            if let data = try? JSONEncoder().encode(transcriptSegments) {
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 10, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_text(stmt, 11, transcriptionStatus.rawValue, -1, SQLITE_TRANSIENT)
            if let transcriptionError { sqlite3_bind_text(stmt, 12, transcriptionError, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
            if let transcriptionModelID { sqlite3_bind_text(stmt, 13, transcriptionModelID, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 13) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw NSError(domain: "TS.DB", code: 502)
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func audioAsset(id: Int64) throws -> AudioAssetRecord? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            let sql = "SELECT id, started_at_ms, ended_at_ms, path, source_kind, bytes, duration_ms, mime, sample_rate, channels, transcript_json, transcription_status, transcription_error, transcription_model_id FROM ts_audio_asset WHERE id=? LIMIT 1;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.makeAudioAssetRecord(from: stmt)
        }
    }

    func audioAsset(forSnapshotId snapshotId: Int64) throws -> AudioAssetRecord? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            let sql = """
            SELECT a.id, a.started_at_ms, a.ended_at_ms, a.path, a.source_kind, a.bytes, a.duration_ms, a.mime, a.sample_rate, a.channels, a.transcript_json, a.transcription_status, a.transcription_error, a.transcription_model_id
            FROM ts_audio_asset a
            JOIN ts_snapshot s ON s.audio_asset_id = a.id
            WHERE s.id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt, 1, snapshotId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.makeAudioAssetRecord(from: stmt)
        }
    }

    func purgeOrphanedAudioAssets() {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let select = "SELECT path FROM ts_audio_asset WHERE id NOT IN (SELECT DISTINCT audio_asset_id FROM ts_snapshot WHERE audio_asset_id IS NOT NULL);"
            guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    paths.append(String(cString: c))
                }
            }
            for path in paths {
                _ = try? FileManager.default.removeItem(atPath: path)
            }
            _ = sqlite3_exec(db, "DELETE FROM ts_audio_asset WHERE id NOT IN (SELECT DISTINCT audio_asset_id FROM ts_snapshot WHERE audio_asset_id IS NOT NULL);", nil, nil, nil)
        }
    }

    func insertPendingAudioCapture(startedAtMs: Int64,
                                   endedAtMs: Int64,
                                   path: String,
                                   sourceKind: AudioSourceKind,
                                   sourceDisplayName: String,
                                   bytes: Int64,
                                   durationMs: Int64,
                                   mime: String,
                                   sampleRate: Int?,
                                   channels: Int?,
                                   modelID: String) throws -> AudioPersistenceIDs {
        try onQueueSync {
            try openIfNeeded()
            guard let db else { throw NSError(domain: "TS.DB", code: 503) }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "TS.DB", code: 504)
            }
            do {
                let assetID = try insertAudioAsset(startedAtMs: startedAtMs,
                                                   endedAtMs: endedAtMs,
                                                   path: path,
                                                   sourceKind: sourceKind,
                                                   bytes: bytes,
                                                   durationMs: durationMs,
                                                   mime: mime,
                                                   sampleRate: sampleRate,
                                                   channels: channels,
                                                   transcriptSegments: [],
                                                   transcriptionStatus: .pending,
                                                   transcriptionModelID: modelID)
                let snapshotID = try insertSnapshot(startedAtMs: startedAtMs,
                                                    endedAtMs: endedAtMs,
                                                    path: path,
                                                    text: "",
                                                    appBundleId: nil,
                                                    appName: sourceDisplayName,
                                                    boxes: [],
                                                    bytes: bytes,
                                                    width: nil,
                                                    height: nil,
                                                    format: URL(fileURLWithPath: path).pathExtension,
                                                    hash64: nil,
                                                    thumbPath: nil,
                                                    textRefId: nil,
                                                    captureKind: .audio,
                                                    sourceKind: sourceKind,
                                                    audioAssetId: assetID)
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "TS.DB", code: 505)
                }
                return AudioPersistenceIDs(assetID: assetID, snapshotID: snapshotID)
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    func completeAudioTranscription(assetID: Int64,
                                    snapshotID: Int64,
                                    segments: [AudioTranscriptSegment],
                                    text: String) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db else { throw NSError(domain: "TS.DB", code: 506) }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "TS.DB", code: 507)
            }
            do {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "UPDATE ts_audio_asset SET transcript_json=?, transcription_status=?, transcription_error=NULL WHERE id=?;"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "TS.DB", code: 508)
                }
                let data = try JSONEncoder().encode(segments)
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_text(stmt, 2, AudioTranscriptionStatus.completed.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, assetID)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 509) }
                try updateFTS(rowId: snapshotID, content: text)
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "TS.DB", code: 510)
                }
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    func failAudioTranscription(assetID: Int64, errorMessage: String) throws {
        try updateAudioTranscriptionState(assetID: assetID,
                                          status: .failed,
                                          errorMessage: errorMessage,
                                          modelID: nil)
    }

    func markAudioTranscriptionPending(assetID: Int64, modelID: String) throws {
        try updateAudioTranscriptionState(assetID: assetID,
                                          status: .pending,
                                          errorMessage: nil,
                                          modelID: modelID)
    }

    func nextPendingAudioTranscription() throws -> AudioTranscriptionJob? {
        try onQueueSync { () -> AudioTranscriptionJob? in
            try openIfNeeded()
            guard let db else { return nil }
            let sql = """
            SELECT a.id, a.started_at_ms, a.ended_at_ms, a.path, a.source_kind, a.bytes, a.duration_ms, a.mime, a.sample_rate, a.channels, a.transcript_json, a.transcription_status, a.transcription_error, a.transcription_model_id, s.id
            FROM ts_audio_asset a
            JOIN ts_snapshot s ON s.audio_asset_id = a.id
            WHERE a.transcription_status = ?
            ORDER BY a.started_at_ms ASC, a.id ASC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, AudioTranscriptionStatus.pending.rawValue, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let asset = Self.makeAudioAssetRecord(from: stmt) else { return nil }
            return AudioTranscriptionJob(snapshotID: sqlite3_column_int64(stmt, 14), asset: asset)
        }
    }

    func hasPendingAudioTranscriptions(modelID: String) throws -> Bool {
        try onQueueSync {
            try openIfNeeded()
            guard let db else { return false }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT 1 FROM ts_audio_asset WHERE transcription_status=? AND transcription_model_id=? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, AudioTranscriptionStatus.pending.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, modelID, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    private func updateAudioTranscriptionState(assetID: Int64,
                                               status: AudioTranscriptionStatus,
                                               errorMessage: String?,
                                               modelID: String?) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db else { throw NSError(domain: "TS.DB", code: 511) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE ts_audio_asset SET transcription_status=?, transcription_error=?, transcription_model_id=COALESCE(?, transcription_model_id) WHERE id=?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "TS.DB", code: 512)
            }
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            if let errorMessage { sqlite3_bind_text(stmt, 2, errorMessage, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
            if let modelID { sqlite3_bind_text(stmt, 3, modelID, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int64(stmt, 4, assetID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 513) }
        }
    }

    private static func makeAudioAssetRecord(from stmt: OpaquePointer?) -> AudioAssetRecord? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        let startedAtMs = sqlite3_column_int64(stmt, 1)
        let endedAtMs = sqlite3_column_int64(stmt, 2)
        guard let pathC = sqlite3_column_text(stmt, 3),
              let sourceC = sqlite3_column_text(stmt, 4) else {
            return nil
        }
        let path = String(cString: pathC)
        let sourceKind = AudioSourceKind(rawValue: String(cString: sourceC)) ?? .microphone
        let bytes = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 5)
        let durationMs = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6)
        let mime = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "audio/mp4"
        let sampleRate = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
        let channels = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        let segments: [AudioTranscriptSegment] = {
            let size = Int(sqlite3_column_bytes(stmt, 10))
            guard let blob = sqlite3_column_blob(stmt, 10), size > 0 else { return [] }
            let data = Data(bytes: blob, count: size)
            return (try? JSONDecoder().decode([AudioTranscriptSegment].self, from: data)) ?? []
        }()
        let statusRaw = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        let status = statusRaw.flatMap { AudioTranscriptionStatus(rawValue: $0) } ?? .completed
        let transcriptionError = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        let transcriptionModelID = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
        return AudioAssetRecord(id: id,
                                startedAtMs: startedAtMs,
                                endedAtMs: endedAtMs,
                                path: path,
                                sourceKind: sourceKind,
                                bytes: bytes,
                                durationMs: durationMs,
                                mime: mime,
                                sampleRate: sampleRate,
                                channels: channels,
                                transcriptSegments: segments,
                                transcriptionStatus: status,
                                transcriptionError: transcriptionError,
                                transcriptionModelID: transcriptionModelID)
    }
}
