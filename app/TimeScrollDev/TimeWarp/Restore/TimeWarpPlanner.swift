import Foundation

/// Builds a Time Warp plan from stored records. Pure, so it can be tested without a database.
///
/// - Time in front is each span's overlap with the block, summed per item.
/// - A visit is a stretch in front; returning within `visitGapMs` continues the same visit.
/// - "Everything that was open" is the state at the end of the block: the open items whose spans
///   reach the latest moment open items were recorded in the block (the block's end, or when
///   recording stopped before it).
/// - For a moment (`momentMs`), items rank by time in front weighted toward the moment
///   (`TimeWarpRecency`), and what was in front at the moment, or last before it, comes first.
enum TimeWarpPlanner {
  static let visitGapMs: Int64 = 5_000

  static func plan(records: [TimeWarpSpanRecord], fromMs: Int64, toMs: Int64, scope: TimeWarpScope,
                   momentMs: Int64? = nil) -> TimeWarpPlan {
    guard toMs > fromMs else { return .empty(fromMs: fromMs, toMs: toMs, scope: scope) }
    func overlap(_ record: TimeWarpSpanRecord) -> Int64 {
      max(0, min(record.endMs, toMs) - max(record.startMs, fromMs))
    }

    var front: [TimeWarpItem: Accumulator] = [:]
    var notes: [TimeWarpPointNote] = []
    let openRecords = records.filter { $0.source == .open && $0.startMs < toMs && $0.endMs >= fromMs }

    for record in records.sorted(by: { $0.startMs < $1.startMs }) {
      switch record.source {
      case .front:
        let spent = overlap(record)
        guard spent > 0 else { continue }
        let item = TimeWarpItem(kind: record.kind, value: record.value, title: record.title)
        let score = momentMs.map {
          TimeWarpRecency.weightedMs(startMs: max(record.startMs, fromMs), endMs: min(record.endMs, toMs), momentMs: $0)
        } ?? 0
        front[item, default: Accumulator()].add(record, spentMs: spent, gapMs: visitGapMs, momentScore: score)
      case .event:
        guard record.kind == .warpPoint, record.startMs >= fromMs, record.startMs < toMs else { continue }
        notes.append(TimeWarpPointNote(timeMs: record.startMs, note: record.value, appBundleId: record.appBundleId))
      case .open:
        continue
      }
    }

    var items: [TimeWarpItem: TimeWarpPlanItem] = [:]
    for (item, accumulated) in front {
      items[item] = accumulated.planItem(for: item)
    }
    if let momentMs {
      for item in frontAtMoment(records: records, fromMs: fromMs, toMs: toMs, momentMs: momentMs) {
        items[item]?.wasFrontAtMoment = true
      }
    }

    if scope == .everythingOpen, let latest = openRecords.map(\.endMs).max() {
      let anchor = min(toMs, latest)
      for record in openRecords where record.startMs <= anchor && record.endMs >= anchor {
        let item = TimeWarpItem(kind: record.kind, value: record.value, title: record.title)
        if let existing = items[item] {
          items[item] = existing.markedOpen()
        } else {
          items[item] = TimeWarpPlanItem(kind: record.kind, value: record.value, title: record.title,
                                         appBundleId: record.appBundleId, frontMs: 0, visits: 0,
                                         lastSeenMs: min(record.endMs, toMs), wasOpenAtEnd: true)
        }
      }
    }

    var groups: [TimeWarpGroup: [TimeWarpPlanItem]] = [:]
    for item in items.values {
      guard let group = TimeWarpGroup(kind: item.kind) else { continue }
      groups[group, default: []].append(item)
    }
    for group in groups.keys {
      groups[group]?.sort { lhs, rhs in
        if momentMs != nil {
          if lhs.wasFrontAtMoment != rhs.wasFrontAtMoment { return lhs.wasFrontAtMoment }
          if lhs.momentScore != rhs.momentScore { return lhs.momentScore > rhs.momentScore }
        }
        if lhs.frontMs != rhs.frontMs { return lhs.frontMs > rhs.frontMs }
        if lhs.lastSeenMs != rhs.lastSeenMs { return lhs.lastSeenMs > rhs.lastSeenMs }
        return (lhs.title ?? lhs.value) < (rhs.title ?? rhs.value)
      }
    }
    return TimeWarpPlan(fromMs: fromMs, toMs: toMs, scope: scope, momentMs: momentMs, groups: groups,
                        notes: notes.sorted { $0.timeMs < $1.timeMs }, hasOpenItems: !openRecords.isEmpty)
  }

  /// What was in front at the moment, or last before it when nothing was (idle or not recording).
  private static func frontAtMoment(records: [TimeWarpSpanRecord], fromMs: Int64, toMs: Int64, momentMs: Int64) -> Set<TimeWarpItem> {
    let front = records.filter { $0.source == .front && $0.startMs < min(toMs, momentMs + 1) && $0.endMs > fromMs }
    guard let latest = front.map(\.endMs).max() else { return [] }
    let anchor = min(momentMs, latest)
    return Set(front.filter { $0.startMs <= anchor && $0.endMs >= anchor }
      .map { TimeWarpItem(kind: $0.kind, value: $0.value, title: $0.title) })
  }

  private struct Accumulator {
    var frontMs: Int64 = 0
    var visits = 0
    var lastEndMs: Int64?
    var lastSeenMs: Int64 = .min
    var title: String?
    var titleSeenMs: Int64 = .min
    var msByApp: [String: Int64] = [:]
    var momentScore: Double = 0

    mutating func add(_ record: TimeWarpSpanRecord, spentMs: Int64, gapMs: Int64, momentScore: Double) {
      frontMs += spentMs
      self.momentScore += momentScore
      if let lastEndMs, record.startMs - lastEndMs <= gapMs {} else { visits += 1 }
      lastEndMs = max(lastEndMs ?? record.endMs, record.endMs)
      lastSeenMs = max(lastSeenMs, record.endMs)
      if let title = record.title, record.startMs >= titleSeenMs {
        self.title = title
        titleSeenMs = record.startMs
      }
      if let app = record.appBundleId { msByApp[app, default: 0] += spentMs }
    }

    func planItem(for item: TimeWarpItem) -> TimeWarpPlanItem {
      let app = msByApp.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
      return TimeWarpPlanItem(kind: item.kind, value: item.value, title: title, appBundleId: item.kind == .app ? item.value : app,
                              frontMs: frontMs, visits: max(1, visits), lastSeenMs: lastSeenMs, wasOpenAtEnd: false,
                              momentScore: momentScore)
    }
  }
}

private extension TimeWarpPlanItem {
  func markedOpen() -> TimeWarpPlanItem {
    TimeWarpPlanItem(kind: kind, value: value, title: title, appBundleId: appBundleId, frontMs: frontMs,
                     visits: visits, lastSeenMs: lastSeenMs, wasOpenAtEnd: true,
                     wasFrontAtMoment: wasFrontAtMoment, momentScore: momentScore)
  }
}
