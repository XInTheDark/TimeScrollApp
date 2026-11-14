import Foundation

/// The choices the Time Warp sheet remembers between launches.
struct TimeWarpChoices: Equatable, Sendable {
  static let minimumOptions: [Int] = [0, 1, 5, 15]

  var scope: TimeWarpScope = .visited
  /// Groups whose items start checked.
  var checkedGroups: Set<TimeWarpGroup> = [.pages, .documents, .folders]
  /// Items in front for less than this are not listed (open items and what was in front at a
  /// moment always are).
  var minimumMinutes: Int = 1
  var opensInNewWindow = false
  /// Leave out items that are already open.
  var skipsOpenItems = true
  /// How far back a moment's Time Warp looks.
  var lookback: TimeWarpLookback = .session
}

/// Which items the sheet lists and which are checked. Pure: the plan, the remembered choices and
/// the user's per-item changes in, rows out.
struct TimeWarpSelection: Equatable {
  var choices: TimeWarpChoices
  /// Items the user checked or unchecked by hand, by id.
  var overrides: [String: Bool] = [:]

  func visibleItems(in group: TimeWarpGroup, plan: TimeWarpPlan) -> [TimeWarpPlanItem] {
    let minimumMs = Int64(choices.minimumMinutes) * 60_000
    return plan.items(in: group).filter { item in
      item.wasOpenAtEnd || item.wasFrontAtMoment || item.frontMs >= minimumMs
    }
  }

  func isChecked(_ item: TimeWarpPlanItem) -> Bool {
    if let override = overrides[item.id] { return override }
    return TimeWarpGroup(kind: item.kind).map(choices.checkedGroups.contains) ?? false
  }

  /// The group's checkbox: all, none, or some of its listed items.
  func groupState(_ group: TimeWarpGroup, plan: TimeWarpPlan) -> Bool? {
    let items = visibleItems(in: group, plan: plan)
    let checked = items.filter(isChecked).count
    if checked == 0 { return false }
    return checked == items.count ? true : nil
  }

  mutating func setGroup(_ group: TimeWarpGroup, checked: Bool, plan: TimeWarpPlan) {
    if checked { choices.checkedGroups.insert(group) } else { choices.checkedGroups.remove(group) }
    for item in plan.items(in: group) { overrides[item.id] = nil }
  }

  mutating func setItem(_ item: TimeWarpPlanItem, checked: Bool) {
    let groupDefault = TimeWarpGroup(kind: item.kind).map(choices.checkedGroups.contains) ?? false
    overrides[item.id] = checked == groupDefault ? nil : checked
  }

  func checkedItems(plan: TimeWarpPlan) -> [TimeWarpPlanItem] {
    TimeWarpGroup.allCases.flatMap { visibleItems(in: $0, plan: plan).filter(isChecked) }
  }
}
