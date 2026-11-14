import AppKit
import Foundation

/// State of the Time Warp sheet: the plan for the range, what is checked, and opening. A moment is
/// shown as the block its look-back gives, ending at the moment.
@MainActor
final class TimeWarpSheetModel: ObservableObject {
  @Published private(set) var target: TimeWarpTarget
  /// The block shown: the picked range, or a moment's look-back.
  @Published private(set) var range: TimelineRange
  /// Start of the session a moment is in; nil for a block, or a moment outside any session.
  @Published private(set) var sessionStartMs: Int64?
  @Published private(set) var plan: TimeWarpPlan
  @Published private(set) var isLoading = false
  @Published private(set) var isOpening = false
  @Published private(set) var lastResult: TimeWarpLauncher.Result?
  /// Files and folders that no longer exist.
  @Published private(set) var missingIds: Set<String> = []
  @Published var selection: TimeWarpSelection {
    didSet {
      guard selection.choices != oldValue.choices else { return }
      choicesStore?.save(selection.choices)
      if selection.choices.scope != oldValue.choices.scope
        || (target.momentMs != nil && selection.choices.lookback != oldValue.choices.lookback) { reload() }
    }
  }

  private let loadRecords: @Sendable (Int64, Int64) -> [TimeWarpSpanRecord]
  private let findSessionStart: @Sendable (Int64) -> Int64?
  private let readOpenNow: @Sendable ([TimeWarpPlanItem]) -> TimeWarpAlreadyOpen.OpenNow
  private let launch: @MainActor ([TimeWarpPlanItem], Bool) async -> TimeWarpLauncher.Result
  /// The session lookup for the moment shown, so changing the look-back doesn't repeat it.
  private var sessionLookup: (momentMs: Int64, startMs: Int64?)?
  /// False while the vault is locked: nothing is read, shown or opened.
  private let isAvailable: @MainActor () -> Bool
  private let choicesStore: TimeWarpChoicesStore?
  private var loadTask: Task<Void, Never>?

  /// `choicesStore` nil keeps choices in memory only (previews and tests).
  init(range: TimelineRange, choicesStore: TimeWarpChoicesStore? = TimeWarpChoicesStore(),
       loadRecords: @escaping @Sendable (Int64, Int64) -> [TimeWarpSpanRecord] = { from, to in
         (try? DB.shared.timeWarpSpans(fromMs: from, toMs: to)) ?? []
       },
       findSessionStart: @escaping @Sendable (Int64) -> Int64? = { TimeWarpSessionLookup.sessionStart(containing: $0) },
       readOpenNow: @escaping @Sendable ([TimeWarpPlanItem]) -> TimeWarpAlreadyOpen.OpenNow = { TimeWarpAlreadyOpen.read(for: $0) },
       launch: @escaping @MainActor ([TimeWarpPlanItem], Bool) async -> TimeWarpLauncher.Result = { await TimeWarpLauncher.open($0, inNewWindow: $1) },
       isAvailable: @escaping @MainActor () -> Bool = TimeWarpSheetModel.vaultIsOpen) {
    target = .range(range)
    self.range = range
    self.choicesStore = choicesStore
    self.loadRecords = loadRecords
    self.findSessionStart = findSessionStart
    self.readOpenNow = readOpenNow
    self.launch = launch
    self.isAvailable = isAvailable
    let choices = choicesStore?.load() ?? TimeWarpChoices()
    selection = TimeWarpSelection(choices: choices)
    plan = .empty(fromMs: range.fromMs, toMs: range.toMs, scope: choices.scope)
  }

  /// A plan already built, shown as is (previews and tests).
  init(target: TimeWarpTarget, range: TimelineRange, sessionStartMs: Int64? = nil, plan: TimeWarpPlan, choices: TimeWarpChoices) {
    self.target = target
    self.range = range
    self.sessionStartMs = sessionStartMs
    self.plan = plan
    choicesStore = nil
    loadRecords = { _, _ in [] }
    findSessionStart = { _ in nil }
    readOpenNow = { _ in TimeWarpAlreadyOpen.OpenNow() }
    launch = { _, _ in TimeWarpLauncher.Result() }
    isAvailable = { true }
    selection = TimeWarpSelection(choices: choices)
  }

  static func vaultIsOpen() -> Bool {
    !VaultManager.shared.isVaultEnabled || VaultManager.shared.isUnlocked
  }

  func show(range: TimelineRange) {
    show(target: .range(range))
  }

  func show(target: TimeWarpTarget) {
    self.target = target
    sessionLookup = nil
    sessionStartMs = nil
    range = Self.resolve(target, lookback: selection.choices.lookback, sessionStartMs: nil)
    selection.overrides.removeAll()
    lastResult = nil
    // The previous range's items must not stay openable under the new heading while this loads.
    clearPlan()
    reload()
  }

  /// The vault locked: forget everything shown and any load in flight.
  func lock() {
    loadTask?.cancel()
    loadTask = nil
    sessionLookup = nil
    selection.overrides.removeAll()
    lastResult = nil
    clearPlan()
    isLoading = false
  }

  private func clearPlan() {
    plan = .empty(fromMs: range.fromMs, toMs: range.toMs, scope: selection.choices.scope)
    missingIds = []
  }

  func reload() {
    loadTask?.cancel()
    guard isAvailable() else {
      lock()
      return
    }
    isLoading = true
    let target = target
    let lookback = selection.choices.lookback
    let scope = selection.choices.scope
    let loadRecords = loadRecords
    let findSessionStart = findSessionStart
    let known = sessionLookup.flatMap { $0.momentMs == target.momentMs ? $0.startMs : nil as Int64?? }
    loadTask = Task { [weak self] in
      let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
        let sessionStart = target.momentMs.flatMap { moment in known ?? findSessionStart(moment) }
        let range = Self.resolve(target, lookback: lookback, sessionStartMs: sessionStart)
        let plan = TimeWarpPlanner.plan(records: loadRecords(range.fromMs, range.toMs), fromMs: range.fromMs, toMs: range.toMs,
                                        scope: scope, momentMs: target.momentMs)
        let files = plan.groups.values.joined().filter { [.document, .folder].contains($0.kind) }
        return Loaded(range: range, sessionStartMs: sessionStart, plan: plan,
                      missing: Set(files.filter { !FileManager.default.fileExists(atPath: $0.value) }.map(\.id)))
      }.value
      guard !Task.isCancelled, let self, self.isAvailable() else { return }
      if let moment = target.momentMs { self.sessionLookup = (moment, loaded.sessionStartMs) }
      self.sessionStartMs = loaded.sessionStartMs
      self.range = loaded.range
      self.plan = loaded.plan
      self.missingIds = loaded.missing
      self.isLoading = false
    }
  }

  private struct Loaded: Sendable {
    let range: TimelineRange
    let sessionStartMs: Int64?
    let plan: TimeWarpPlan
    let missing: Set<String>
  }

  nonisolated static func resolve(_ target: TimeWarpTarget, lookback: TimeWarpLookback, sessionStartMs: Int64?) -> TimelineRange {
    switch target {
    case let .range(range): return range
    case let .moment(ms): return lookback.range(endingAt: ms, sessionStartMs: sessionStartMs)
    }
  }

  /// The look-back in use; "This Session" falls back when the moment isn't in one.
  var effectiveLookback: TimeWarpLookback {
    selection.choices.lookback.effective(sessionStartMs: sessionStartMs)
  }

  var checkedItems: [TimeWarpPlanItem] { selection.checkedItems(plan: plan).filter { !missingIds.contains($0.id) } }

  var visibleGroups: [TimeWarpGroup] {
    TimeWarpGroup.allCases.filter { !selection.visibleItems(in: $0, plan: plan).isEmpty }
  }

  /// Items recorded but hidden by the minimum time.
  var hiddenCount: Int {
    TimeWarpGroup.allCases.reduce(0) { $0 + plan.items(in: $1).count - selection.visibleItems(in: $1, plan: plan).count }
  }

  func open() async -> Bool {
    let items = checkedItems
    guard !items.isEmpty, !isOpening, !isLoading, isAvailable() else { return false }
    isOpening = true
    var toOpen = items
    var skipped = 0
    if selection.choices.skipsOpenItems {
      let readOpenNow = readOpenNow
      let openNow = await Task.detached(priority: .userInitiated) { readOpenNow(items) }.value
      let open = TimeWarpAlreadyOpen.ids(of: items, openNow: openNow)
      toOpen = items.filter { !open.contains($0.id) }
      skipped = items.count - toOpen.count
      // The vault may have locked while open windows were read.
      guard isAvailable() else {
        isOpening = false
        return false
      }
    }
    var result = toOpen.isEmpty ? TimeWarpLauncher.Result() : await launch(toOpen, selection.choices.opensInNewWindow)
    result.alreadyOpen = skipped
    isOpening = false
    lastResult = result
    // When everything was already open, stay so the user sees why nothing happened.
    return result.isComplete && !result.wasAllOpen
  }
}
