import Foundation

/// Search hits from one activity session, shown as one card.
struct SearchSessionGroup: Identifiable, Equatable {
  /// Nil for a hit outside any session (audio with no screen activity, or sessions unavailable).
  let session: ActivitySession?
  /// In result order; the first is the best match.
  let hits: [SearchResult]

  var id: String { session.map { "s\($0.id)" } ?? "h\(hits.first?.id ?? 0)" }
  var best: SearchResult { hits[0] }
}

/// Groups ranked search hits by the session they fall in. Groups keep the order of their best hit,
/// so keyword results stay newest first and AI results stay most relevant first.
enum SearchSessionGrouper {
  /// Audio and the last captures of a session can sit slightly past its last screen capture.
  static let matchToleranceMs: Int64 = 60_000

  /// `sessions` must be sorted by start and must not overlap.
  static func group(_ hits: [SearchResult], sessions: [ActivitySession]) -> [SearchSessionGroup] {
    var order: [Int64?] = []
    var hitsBySession: [Int64: [SearchResult]] = [:]
    var sessionById: [Int64: ActivitySession] = [:]
    var loose: [SearchResult] = []
    for hit in hits {
      guard let session = session(containing: hit.startedAtMs, in: sessions) else {
        order.append(nil)
        loose.append(hit)
        continue
      }
      if hitsBySession[session.id] == nil {
        order.append(session.id)
        sessionById[session.id] = session
      }
      hitsBySession[session.id, default: []].append(hit)
    }

    var looseIndex = 0
    return order.map { id in
      guard let id, let session = sessionById[id], let grouped = hitsBySession[id] else {
        defer { looseIndex += 1 }
        return SearchSessionGroup(session: nil, hits: [loose[looseIndex]])
      }
      return SearchSessionGroup(session: session, hits: grouped)
    }
  }

  /// The session whose span (plus tolerance) holds `timeMs`; the closest one when tolerances overlap.
  static func session(containing timeMs: Int64, in sessions: [ActivitySession]) -> ActivitySession? {
    // First session ending at or after the time, less the tolerance.
    var low = 0
    var high = sessions.count
    while low < high {
      let mid = (low + high) / 2
      if sessions[mid].endMs + matchToleranceMs < timeMs { low = mid + 1 } else { high = mid }
    }
    var best: (session: ActivitySession, distance: Int64)?
    var index = low
    while index < sessions.count, sessions[index].startMs - matchToleranceMs <= timeMs {
      let session = sessions[index]
      let distance = timeMs < session.startMs ? session.startMs - timeMs : max(0, timeMs - session.endMs)
      if best == nil || distance < best!.distance { best = (session, distance) }
      if distance == 0 { break }
      index += 1
    }
    return best?.session
  }
}
