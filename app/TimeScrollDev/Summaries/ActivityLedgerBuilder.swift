import Foundation

/// Makes a ledger from sessions. Reads text only for the sessions with the most time, so the work for a
/// day is bounded however busy it was.
enum ActivityLedgerBuilder {
  static let sessionsWithText = 12

  /// The texts `build` will use.
  static func textIds(for sessions: [ActivitySession]) -> [Int64] {
    topSessions(sessions).flatMap(\.representativeTextIds)
  }

  static func build(startMs: Int64, endMs: Int64, sessions: [ActivitySession], texts: [Int64: String]) -> ActivityLedger {
    var appTime = Tally()
    var terms = Tally()
    var activeMs: Int64 = 0
    for session in sessions {
      let weight = weight(session)
      activeMs += weight
      for app in session.apps { appTime.add(app.name ?? app.bundleId ?? "Unknown", ms: app.ms) }
      for keyword in session.keywords { terms.add(keyword, ms: weight) }
    }

    var ranked: [(timeMs: Int64, lines: [String])] = []
    for session in topSessions(sessions) {
      let screens = session.representativeTextIds.compactMap { texts[$0] }
      for artifact in screens.flatMap(LedgerArtifactScanner.artifacts(in:)) { terms.add(artifact, ms: weight(session)) }
      let lines = ExcerptLineSelector.ranked(texts: screens, keywords: session.keywords)
      if !lines.isEmpty { ranked.append((session.startMs, lines)) }
    }

    return ActivityLedger(startMs: startMs, endMs: endMs, activeMs: activeMs,
                          apps: appTime.top(ActivityLedger.maxApps), terms: terms.top(ActivityLedger.maxTerms),
                          lines: roundRobin(ranked))
  }

  /// The best line of each session, then the second best, and so on.
  private static func roundRobin(_ ranked: [(timeMs: Int64, lines: [String])]) -> [ActivityLedger.Line] {
    var lines: [ActivityLedger.Line] = []
    var depth = 0
    while lines.count < ActivityLedger.maxLines {
      let round = ranked.filter { depth < $0.lines.count }
      guard !round.isEmpty else { break }
      for session in round where lines.count < ActivityLedger.maxLines {
        let text = RepresentativeTextSelector.truncate(session.lines[depth], toBytes: ActivityLedger.maxLineBytes)
        lines.append(.init(timeMs: session.timeMs, text: text))
      }
      depth += 1
    }
    return lines
  }

  private static func topSessions(_ sessions: [ActivitySession]) -> [ActivitySession] {
    Array(sessions.sorted { weight($0) != weight($1) ? weight($0) > weight($1) : $0.id < $1.id }.prefix(sessionsWithText))
  }

  private static func weight(_ session: ActivitySession) -> Int64 {
    max(1, session.durationMs, session.apps.reduce(0) { $0 + $1.ms })
  }
}
