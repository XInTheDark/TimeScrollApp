import Foundation
import Testing
@testable import TimeScroll

/// Keeps choices in memory only (`choicesStore: nil`), so the user's saved choices are untouched,
/// and fixes vault availability so the real vault state can't change the outcome.
@MainActor
struct TimeWarpSheetModelTests {
  private let range = TimelineRange(fromMs: 0, toMs: 600_000)!

  private func record(_ kind: TimeWarpItemKind, _ value: String, source: TimeWarpSource = .front) -> TimeWarpSpanRecord {
    TimeWarpSpanRecord(kind: kind, source: source, value: value, title: nil, appBundleId: "com.a", startMs: 0, endMs: 300_000)
  }

  private func waitUntilLoaded(_ model: TimeWarpSheetModel) async {
    for _ in 0..<200 where model.isLoading { try? await Task.sleep(nanoseconds: 5_000_000) }
  }

  @Test func showLoadsThePlanAndMarksMissingFiles() async {
    let existing = FileManager.default.temporaryDirectory.path
    let records = [record(.page, "https://a/"), record(.folder, existing), record(.document, "/nonexistent/\(UUID().uuidString).txt")]
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in records }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.plan.items(in: .pages).count == 1)
    #expect(model.missingIds.count == 1)
    // Missing files are never offered for opening.
    #expect(model.checkedItems.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.folder, .page])
  }

  @Test func changingTheScopeReloads() async {
    let records = [record(.page, "https://front/"), record(.page, "https://bg/", source: .open)]
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in records }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.plan.items(in: .pages).count == 1)
    model.selection.choices.scope = .everythingOpen
    await waitUntilLoaded(model)
    #expect(model.plan.items(in: .pages).count == 2)
  }

  @Test func emptyRangeHasNothingToOpen() async {
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in [] }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.plan.isEmpty)
    #expect(model.visibleGroups.isEmpty)
    #expect(model.checkedItems.isEmpty)
    #expect(await model.open() == false)
  }

  @Test func hiddenCountFollowsTheMinimum() async {
    let short = TimeWarpSpanRecord(kind: .page, source: .front, value: "https://short/", title: nil, appBundleId: "com.a", startMs: 0, endMs: 10_000)
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in [short] }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.hiddenCount == 1)
    model.selection.choices.minimumMinutes = 0
    #expect(model.hiddenCount == 0)
  }

  @Test func showingANewRangeDropsTheOldItemsAndCantOpenWhileLoading() async {
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { from, _ in
      if from > 0 { Thread.sleep(forTimeInterval: 0.2) }
      return [TimeWarpSpanRecord(kind: .page, source: .front, value: "https://\(from)/", title: nil, appBundleId: "com.a",
                                 startMs: from, endMs: from + 300_000)]
    }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.checkedItems.map(\.value) == ["https://0/"])
    model.show(range: TimelineRange(fromMs: 1_000_000, toMs: 1_600_000)!)
    #expect(model.isLoading)
    #expect(model.plan.isEmpty)
    #expect(model.checkedItems.isEmpty)
    #expect(await model.open() == false)
    await waitUntilLoaded(model)
    #expect(model.checkedItems.map(\.value) == ["https://1000000/"])
  }

  @Test func lockingClearsWhatWasLoaded() async {
    let records = [record(.page, "https://a/")]
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in records }, isAvailable: { true })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(!model.plan.isEmpty)
    model.lock()
    #expect(model.plan.isEmpty)
    #expect(!model.isLoading)
    #expect(model.checkedItems.isEmpty)
  }

  @Test func lockedVaultLoadsNothing() async {
    let loaded = LoadCounter()
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in
      loaded.increment()
      return [TimeWarpSpanRecord(kind: .page, source: .front, value: "https://a/", title: nil, appBundleId: "com.a", startMs: 0, endMs: 300_000)]
    }, isAvailable: { false })
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(model.plan.isEmpty)
    #expect(loaded.value == 0)
    #expect(await model.open() == false)
  }

  @Test func lockDuringALoadDropsItsResult() async {
    var available = true
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in
      Thread.sleep(forTimeInterval: 0.1)
      return [TimeWarpSpanRecord(kind: .page, source: .front, value: "https://a/", title: nil, appBundleId: "com.a", startMs: 0, endMs: 300_000)]
    }, isAvailable: { available })
    model.show(range: range)
    available = false
    await waitUntilLoaded(model)
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(model.plan.isEmpty)
  }

  // MARK: Moments

  private let moment: Int64 = 1_800_000_000_000

  private func momentModel(sessionStart: Int64?, lookups: LoadCounter = LoadCounter(),
                           ranges: RangeLog = RangeLog()) -> TimeWarpSheetModel {
    let moment = moment
    return TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { from, to in
      ranges.append(from, to)
      return [TimeWarpSpanRecord(kind: .page, source: .front, value: "https://now/", title: nil, appBundleId: "com.a",
                                 startMs: moment - 120_000, endMs: moment + 60_000)]
    }, findSessionStart: { _ in
      lookups.increment()
      return sessionStart
    }, isAvailable: { true })
  }

  @Test func aMomentLoadsItsSessionUpToTheMoment() async {
    let ranges = RangeLog()
    let model = momentModel(sessionStart: moment - 40 * 60_000, ranges: ranges)
    model.show(target: .moment(moment))
    await waitUntilLoaded(model)
    #expect(model.target == .moment(moment))
    #expect(model.range == TimelineRange.covering(moment - 40 * 60_000, moment))
    #expect(ranges.last?.to == moment + 1_000)
    #expect(model.effectiveLookback == .session)
    #expect(model.plan.momentMs == moment)
    #expect(model.plan.items(in: .pages).first?.wasFrontAtMoment == true)
  }

  @Test func aMomentOutsideASessionLooksBackAnHour() async {
    let model = momentModel(sessionStart: nil)
    model.show(target: .moment(moment))
    await waitUntilLoaded(model)
    #expect(model.selection.choices.lookback == .session)
    #expect(model.effectiveLookback == .hour)
    #expect(model.range == TimeWarpLookback.hour.range(endingAt: moment, sessionStartMs: nil))
  }

  @Test func changingTheLookbackReloadsWithoutFindingTheSessionAgain() async {
    let lookups = LoadCounter()
    let model = momentModel(sessionStart: moment - 40 * 60_000, lookups: lookups)
    model.show(target: .moment(moment))
    await waitUntilLoaded(model)
    model.selection.choices.lookback = .fifteenMinutes
    await waitUntilLoaded(model)
    #expect(model.range == TimeWarpLookback.fifteenMinutes.range(endingAt: moment, sessionStartMs: nil))
    model.selection.choices.lookback = .session
    await waitUntilLoaded(model)
    #expect(model.range.fromMs == moment - 40 * 60_000)
    #expect(lookups.value == 1)
    // A new moment looks its session up again.
    model.show(target: .moment(moment + 1_000))
    await waitUntilLoaded(model)
    #expect(lookups.value == 2)
  }

  @Test func aBlockIgnoresTheLookbackAndNeverLooksUpASession() async {
    let lookups = LoadCounter()
    let ranges = RangeLog()
    let model = momentModel(sessionStart: 0, lookups: lookups, ranges: ranges)
    model.show(range: range)
    await waitUntilLoaded(model)
    model.selection.choices.lookback = .today
    await waitUntilLoaded(model)
    #expect(model.range == range)
    #expect(ranges.count == 1)
    #expect(lookups.value == 0)
    #expect(model.plan.momentMs == nil)
  }

  // MARK: Already open

  private final class Launched: @unchecked Sendable {
    var values: [String] = []
  }

  private func openingModel(openNow: TimeWarpAlreadyOpen.OpenNow, launched: Launched, reads: LoadCounter = LoadCounter(),
                            available: @escaping @MainActor () -> Bool = { true }) -> TimeWarpSheetModel {
    let records = [record(.page, "https://open/"), record(.page, "https://closed/")]
    return TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in records }, readOpenNow: { _ in
      reads.increment()
      return openNow
    }, launch: { items, _ in
      launched.values += items.map(\.value)
      return TimeWarpLauncher.Result(opened: items.count)
    }, isAvailable: available)
  }

  @Test func alreadyOpenItemsAreSkippedByDefault() async {
    let launched = Launched()
    let model = openingModel(openNow: .init(pages: ["https://open/"]), launched: launched)
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(await model.open())
    #expect(launched.values == ["https://closed/"])
    #expect(model.lastResult?.alreadyOpen == 1)
    #expect(model.lastResult?.wasAllOpen == false)
  }

  @Test func turningSkippingOffOpensEverythingWithoutReading() async {
    let launched = Launched()
    let reads = LoadCounter()
    let model = openingModel(openNow: .init(pages: ["https://open/"]), launched: launched, reads: reads)
    model.selection.choices.skipsOpenItems = false
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(await model.open())
    #expect(Set(launched.values) == ["https://open/", "https://closed/"])
    #expect(reads.value == 0)
  }

  @Test func whenEverythingIsOpenNothingLaunchesAndTheWindowStays() async {
    let launched = Launched()
    let model = openingModel(openNow: .init(pages: ["https://open/", "https://closed/"]), launched: launched)
    model.show(range: range)
    await waitUntilLoaded(model)
    #expect(await model.open() == false)
    #expect(launched.values.isEmpty)
    #expect(model.lastResult?.wasAllOpen == true)
    #expect(!model.isOpening)
  }

  @Test func lockingWhileReadingOpensNothing() async {
    let launched = Launched()
    var available = true
    let records = [record(.page, "https://a/")]
    let model = TimeWarpSheetModel(range: range, choicesStore: nil, loadRecords: { _, _ in records },
                                   readOpenNow: { _ in
      Thread.sleep(forTimeInterval: 0.1)
      return .init()
    }, launch: { items, _ in
      launched.values += items.map(\.value)
      return TimeWarpLauncher.Result(opened: items.count)
    }, isAvailable: { available })
    model.show(range: range)
    await waitUntilLoaded(model)
    async let opened = model.open()
    try? await Task.sleep(nanoseconds: 20_000_000)
    available = false
    #expect(await opened == false)
    #expect(launched.values.isEmpty)
    #expect(!model.isOpening)
  }
}

private final class LoadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class RangeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var ranges: [(from: Int64, to: Int64)] = []
  var count: Int { lock.withLock { ranges.count } }
  var last: (from: Int64, to: Int64)? { lock.withLock { ranges.last } }
  func append(_ from: Int64, _ to: Int64) { lock.withLock { ranges.append((from, to)) } }
}
