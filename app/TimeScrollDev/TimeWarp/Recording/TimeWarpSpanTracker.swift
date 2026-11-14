import Foundation

/// Turns observations into span writes. Pure: it decides which spans open, close or move forward,
/// and the recorder carries the writes out and reports back the stored ids.
///
/// - The front app and the front item each have one span; a change ends the old one and starts a new
///   one. The same item in a different app is a different span.
/// - Open items (background tabs, other windows) have a span per app and item, kept until a later
///   look at that app no longer finds them.
/// - No span is stored longer than `hardLimitMs`, so range queries stay on an index.
struct TimeWarpSpanTracker {
  enum Slot: Hashable {
    case frontApp
    case frontItem
    case open(appBundleId: String, item: TimeWarpItem)
  }

  enum Action: Equatable {
    case open(Slot, TimeWarpSpanStart)
    case close(ids: [Int64], endMs: Int64)
  }

  private struct Entry {
    var start: TimeWarpSpanStart
    var id: Int64?
  }

  /// No stored span is longer than this (`DB.timeWarpMaxSpanMs`).
  let hardLimitMs: Int64
  private var entries: [Slot: Entry] = [:]

  init(hardLimitMs: Int64 = DB.timeWarpMaxSpanMs) {
    self.hardLimitMs = hardLimitMs
  }

  var isEmpty: Bool { entries.isEmpty }

  func start(of slot: Slot) -> TimeWarpSpanStart? { entries[slot]?.start }

  var openItemSlots: [Slot] {
    entries.keys.filter { if case .open = $0 { return true } else { return false } }
  }

  // MARK: Observations

  /// The front window now shows `item` in `appBundleId` (either may be nil: nothing recordable).
  /// Spans that end, end at `endMs`, which the recorder moves back over idle time.
  mutating func observeFront(appBundleId: String?, item: TimeWarpItem?, nowMs: Int64, endMs: Int64) -> [Action] {
    var actions: [Action] = []
    let appItem = appBundleId.map { TimeWarpItem(kind: .app, value: $0) }
    actions += replace(.frontApp, with: appItem, appBundleId: appBundleId, source: .front, nowMs: nowMs, endMs: endMs)
    actions += replace(.frontItem, with: item, appBundleId: appBundleId, source: .front, nowMs: nowMs, endMs: endMs)
    return actions
  }

  /// Nothing is in front that may be recorded: locked screen, sleep, a private or excluded window.
  mutating func pauseFront(endMs: Int64) -> [Action] {
    close([.frontApp, .frontItem], endMs: endMs)
  }

  /// Everything `appBundleId` has open now. Items that disappeared end; new ones start.
  mutating func replaceOpenItems(appBundleId: String, items: Set<TimeWarpItem>, nowMs: Int64) -> [Action] {
    var actions: [Action] = []
    let current = Set(entries.keys.compactMap { slot -> TimeWarpItem? in
      if case let .open(app, item) = slot, app == appBundleId { return item }
      return nil
    })
    let gone = current.subtracting(items).map { Slot.open(appBundleId: appBundleId, item: $0) }
    actions += close(gone, endMs: nowMs)
    for item in items.subtracting(current) {
      let slot = Slot.open(appBundleId: appBundleId, item: item)
      let start = TimeWarpSpanStart(item: item, source: .open, appBundleId: appBundleId, startMs: nowMs)
      entries[slot] = Entry(start: start)
      actions.append(.open(slot, start))
    }
    return actions
  }

  /// The app quit, or its items may no longer be recorded.
  mutating func closeOpenItems(appBundleId: String, endMs: Int64) -> [Action] {
    let slots = entries.keys.filter { if case let .open(app, _) = $0 { return app == appBundleId } else { return false } }
    return close(slots, endMs: endMs)
  }

  /// These apps may no longer be recorded (excluded): their front and open spans end.
  mutating func closeApps(_ bundleIds: Set<String>, endMs: Int64) -> [Action] {
    guard !bundleIds.isEmpty else { return [] }
    let slots = entries.compactMap { slot, entry -> Slot? in
      guard let app = entry.start.appBundleId, bundleIds.contains(app) else { return nil }
      return slot
    }
    return close(slots, endMs: endMs)
  }

  /// Recording stops: every span ends.
  mutating func stopAll(endMs: Int64) -> [Action] {
    close(Array(entries.keys), endMs: endMs)
  }

  // MARK: Results of writes

  mutating func didOpen(_ slot: Slot, start: TimeWarpSpanStart, id: Int64?) {
    // A newer observation may have replaced the slot while the write ran.
    guard entries[slot]?.start == start else { return }
    if let id { entries[slot]?.id = id } else { entries[slot] = nil }
  }

  // MARK: Helpers

  private mutating func replace(_ slot: Slot, with item: TimeWarpItem?, appBundleId: String?,
                                source: TimeWarpSource, nowMs: Int64, endMs: Int64) -> [Action] {
    if let existing = entries[slot], let item, existing.start.item == item, existing.start.appBundleId == appBundleId {
      return []
    }
    var actions = close([slot], endMs: endMs)
    if let item {
      let start = TimeWarpSpanStart(item: item, source: source, appBundleId: appBundleId, startMs: nowMs)
      entries[slot] = Entry(start: start)
      actions.append(.open(slot, start))
    }
    return actions
  }

  private mutating func close(_ slots: [Slot], endMs: Int64) -> [Action] {
    // No span may outgrow the stored limit.
    var idsByEnd: [Int64: [Int64]] = [:]
    for slot in slots {
      guard let entry = entries.removeValue(forKey: slot), let id = entry.id else { continue }
      idsByEnd[min(endMs, entry.start.startMs + hardLimitMs), default: []].append(id)
    }
    return idsByEnd.keys.sorted().map { .close(ids: idsByEnd[$0]!.sorted(), endMs: $0) }
  }
}
