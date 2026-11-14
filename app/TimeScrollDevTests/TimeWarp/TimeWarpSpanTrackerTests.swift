import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpSpanTrackerTests {
  private let page = TimeWarpItem(kind: .page, value: "https://a.com/")
  private let other = TimeWarpItem(kind: .page, value: "https://b.com/")

  /// Gives every opened span the next id, like the database would.
  private final class FakeStore: TimeWarpSpanStore {
    var nextId: Int64 = 1
    var spans: [Int64: (start: TimeWarpSpanStart, endMs: Int64, isOpen: Bool)] = [:]
    var events: [TimeWarpItem] = []

    func timeWarpOpenSpan(_ start: TimeWarpSpanStart) -> Int64? {
      defer { nextId += 1 }
      spans[nextId] = (start, start.startMs, true)
      return nextId
    }
    func timeWarpCloseSpans(ids: [Int64], endMs: Int64) {
      for id in ids where spans[id]?.isOpen == true { spans[id]!.endMs = max(spans[id]!.start.startMs, endMs); spans[id]!.isOpen = false }
    }
    func timeWarpRecordEvent(_ item: TimeWarpItem, appBundleId: String?, atMs: Int64) -> Bool { events.append(item); return true }
    func timeWarpCloseAbandonedSpans() {}
  }

  private func run(_ tracker: inout TimeWarpSpanTracker, _ store: FakeStore, nowMs: Int64,
                   _ body: (inout TimeWarpSpanTracker) -> [TimeWarpSpanTracker.Action]) {
    let actions = body(&tracker)
    TimeWarpSpanWriter.apply(actions, to: &tracker, store: store)
  }

  @Test func firstObservationOpensAppAndItem() {
    var tracker = TimeWarpSpanTracker()
    let actions = tracker.observeFront(appBundleId: "com.google.Chrome", item: page, nowMs: 100, endMs: 100)
    #expect(actions.count == 2)
    #expect(tracker.start(of: .frontApp)?.item == TimeWarpItem(kind: .app, value: "com.google.Chrome"))
    #expect(tracker.start(of: .frontItem)?.item == page)
  }

  @Test func sameItemAgainDoesNothing() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100) }
    #expect(tracker.observeFront(appBundleId: "com.a", item: page, nowMs: 200, endMs: 200).isEmpty)
  }

  @Test func changingItemClosesOldAtEndAndOpensNew() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100) }
    run(&tracker, store, nowMs: 500) { $0.observeFront(appBundleId: "com.a", item: other, nowMs: 500, endMs: 450) }
    let pageSpan = store.spans.values.first { $0.start.item == page }!
    #expect(pageSpan.isOpen == false)
    #expect(pageSpan.endMs == 450)
    #expect(store.spans.values.contains { $0.start.item == other && $0.isOpen && $0.start.startMs == 500 })
    // The app did not change, so its span continues.
    #expect(store.spans.values.filter { $0.start.item.kind == .app }.count == 1)
  }

  @Test func sameItemInAnotherAppIsANewSpan() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100) }
    run(&tracker, store, nowMs: 200) { $0.observeFront(appBundleId: "com.b", item: page, nowMs: 200, endMs: 200) }
    #expect(store.spans.values.filter { $0.start.item == page }.count == 2)
  }

  @Test func pauseClosesFrontButKeepsOpenItems() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100) }
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.a", items: [page, other], nowMs: 100) }
    run(&tracker, store, nowMs: 300) { $0.pauseFront(endMs: 300) }
    #expect(tracker.start(of: .frontItem) == nil)
    #expect(tracker.openItemSlots.count == 2)
    #expect(store.spans.values.filter { $0.isOpen }.count == 2)
  }

  @Test func replaceOpenItemsDiffs() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.a", items: [page, other], nowMs: 100) }
    let actions = tracker.replaceOpenItems(appBundleId: "com.a", items: [other], nowMs: 200)
    #expect(actions.count == 1)
    guard case let .close(ids, endMs) = actions.first else { Issue.record("expected close"); return }
    #expect(endMs == 200)
    #expect(ids.count == 1)
    #expect(tracker.replaceOpenItems(appBundleId: "com.a", items: [other], nowMs: 300).isEmpty)
  }

  @Test func emptyOpenItemsCloseEverythingForThatAppOnly() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.a", items: [page], nowMs: 100) }
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.b", items: [page], nowMs: 100) }
    run(&tracker, store, nowMs: 200) { $0.closeOpenItems(appBundleId: "com.a", endMs: 200) }
    #expect(tracker.openItemSlots == [.open(appBundleId: "com.b", item: page)])
  }

  @Test func closingExcludedAppsEndsOnlyTheirSpans() {
    var tracker = TimeWarpSpanTracker()
    let store = FakeStore()
    run(&tracker, store, nowMs: 100) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100) }
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.a", items: [other], nowMs: 100) }
    run(&tracker, store, nowMs: 100) { $0.replaceOpenItems(appBundleId: "com.b", items: [other], nowMs: 100) }
    run(&tracker, store, nowMs: 400) { $0.closeApps(["com.a"], endMs: 300) }
    #expect(tracker.start(of: .frontApp) == nil)
    #expect(tracker.start(of: .frontItem) == nil)
    #expect(tracker.openItemSlots == [.open(appBundleId: "com.b", item: other)])
    let stillOpen = store.spans.values.filter(\.isOpen)
    #expect(stillOpen.count == 1)
    #expect(stillOpen.first?.start.appBundleId == "com.b")
    #expect(store.spans.values.filter { !$0.isOpen }.allSatisfy { $0.endMs == 300 })
    let none = tracker.closeApps([], endMs: 500)
    let unknown = tracker.closeApps(["com.z"], endMs: 500)
    #expect(none.isEmpty)
    #expect(unknown.isEmpty)
  }

  @Test func closeNeverExceedsTheHardLimit() {
    var tracker = TimeWarpSpanTracker(hardLimitMs: 1_500)
    let store = FakeStore()
    run(&tracker, store, nowMs: 0) { $0.observeFront(appBundleId: "com.a", item: page, nowMs: 0, endMs: 0) }
    run(&tracker, store, nowMs: 99_000) { $0.stopAll(endMs: 99_000) }
    #expect(store.spans.values.allSatisfy { !$0.isOpen && $0.endMs == 1_500 })
  }

  @Test func failedWriteForgetsTheSlot() {
    var tracker = TimeWarpSpanTracker()
    let actions = tracker.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100)
    for case let .open(slot, start) in actions { tracker.didOpen(slot, start: start, id: nil) }
    #expect(tracker.isEmpty)
    // The next look tries again.
    #expect(tracker.observeFront(appBundleId: "com.a", item: page, nowMs: 200, endMs: 200).count == 2)
  }

  @Test func staleWriteResultIsIgnored() {
    var tracker = TimeWarpSpanTracker()
    let first = tracker.observeFront(appBundleId: "com.a", item: page, nowMs: 100, endMs: 100)
    _ = tracker.observeFront(appBundleId: "com.a", item: other, nowMs: 200, endMs: 200)
    for case let .open(slot, start) in first where slot == .frontItem { tracker.didOpen(slot, start: start, id: 7) }
    #expect(tracker.start(of: .frontItem)?.item == other)
    // The newer span has no id yet, so stopping writes no close for it.
    #expect(tracker.stopAll(endMs: 300).allSatisfy { if case let .close(ids, _) = $0 { return !ids.contains(7) } else { return false } })
  }
}
