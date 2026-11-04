import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// One session's distinct screens that have embeddings from a single model, spread evenly over the
/// session. Vectors from different models can't be compared, so only the best covered model is used.
struct SessionEmbeddingCandidates: Equatable {
  let candidates: [EmbeddingRepresentativeSelector.Candidate]
  /// All of the model's embedded screens, including any thinned out of `candidates`.
  let embeddedTextCount: Int
  let screenTextCount: Int
}

extension DB {
  static let sessionEmbeddingCandidateLimit = 1_000

  static func sessionEmbeddingCandidates(fromMs: Int64, throughMs: Int64, limit: Int = sessionEmbeddingCandidateLimit,
                                         db: OpaquePointer) -> SessionEmbeddingCandidates {
    let sql = """
    SELECT s.text_store_id, e.provider, e.model, e.dim, e.vec
    FROM ts_snapshot s
    LEFT JOIN ts_embedding e ON e.snapshot_id = s.id AND e.model NOT LIKE ?
    WHERE s.capture_kind = 'screen' AND s.text_store_id IS NOT NULL AND s.started_at_ms >= ? AND s.started_at_ms <= ?
    ORDER BY s.started_at_ms ASC, s.id ASC;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let empty = SessionEmbeddingCandidates(candidates: [], embeddedTextCount: 0, screenTextCount: 0)
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return empty }
    sqlite3_bind_text(stmt, 1, "%\(SnapshotEmbeddingWriter.stagingModelSuffix)", -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 2, fromMs)
    sqlite3_bind_int64(stmt, 3, throughMs)

    var screenTexts = Set<Int64>()
    var groups: [String: SessionEmbeddingGroup] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      let textId = sqlite3_column_int64(stmt, 0)
      screenTexts.insert(textId)
      guard let provider = sqlite3_column_text(stmt, 1), let model = sqlite3_column_text(stmt, 2) else { continue }
      let dim = Int(sqlite3_column_int(stmt, 3))
      let key = "\(String(cString: provider))\u{1}\(String(cString: model))\u{1}\(dim)"
      // The blob is read only for screens the group keeps.
      groups[key, default: SessionEmbeddingGroup(limit: limit)].add(textId: textId) {
        let length = Int(sqlite3_column_bytes(stmt, 4))
        guard dim > 0, length >= dim * MemoryLayout<Float>.size, let blob = sqlite3_column_blob(stmt, 4) else { return nil }
        return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dim))
      }
    }
    let best = groups.sorted { $0.value.seenCount != $1.value.seenCount ? $0.value.seenCount > $1.value.seenCount : $0.key < $1.key }.first?.value
    return SessionEmbeddingCandidates(candidates: best?.candidates ?? [], embeddedTextCount: best?.seenCount ?? 0,
                                      screenTextCount: screenTexts.count)
  }
}
