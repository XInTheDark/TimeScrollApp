import Foundation

/// Computed sessions kept in memory, by day start. Their labels are screen text, so everything is
/// forgotten as soon as captures change.
struct SessionDayMemory {
  struct Entry {
    let params: String
    let sessions: [ActivitySession]
    let checkedAtMs: Int64
    let settled: Bool
  }

  private var entries: [Int64: Entry] = [:]
  private var invalidations: Int64?

  /// Call with the database's current invalidation count before reading.
  mutating func sync(invalidations current: Int64) {
    guard invalidations != current else { return }
    entries.removeAll()
    invalidations = current
  }

  subscript(dayStartMs: Int64) -> Entry? {
    get { entries[dayStartMs] }
    set { entries[dayStartMs] = newValue }
  }

  mutating func removeAll() {
    entries.removeAll()
  }
}
