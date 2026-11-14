import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpSelectionTests {
  private func item(_ kind: TimeWarpItemKind, _ value: String, frontMs: Int64 = 600_000, open: Bool = false) -> TimeWarpPlanItem {
    TimeWarpPlanItem(kind: kind, value: value, title: nil, appBundleId: nil, frontMs: frontMs, visits: 1, lastSeenMs: 0, wasOpenAtEnd: open)
  }

  private func plan(_ items: [TimeWarpPlanItem]) -> TimeWarpPlan {
    var groups: [TimeWarpGroup: [TimeWarpPlanItem]] = [:]
    for item in items { groups[TimeWarpGroup(kind: item.kind)!, default: []].append(item) }
    return TimeWarpPlan(fromMs: 0, toMs: 1, scope: .visited, groups: groups, notes: [], hasOpenItems: false)
  }

  @Test func defaultsCheckPagesDocumentsAndFolders() {
    let selection = TimeWarpSelection(choices: TimeWarpChoices())
    let plan = plan([item(.page, "p"), item(.document, "d"), item(.folder, "f"), item(.app, "a")])
    #expect(Set(selection.checkedItems(plan: plan).map(\.value)) == ["p", "d", "f"])
  }

  @Test func minimumTimeHidesShortItemsButNotOpenOnes() {
    var choices = TimeWarpChoices()
    choices.minimumMinutes = 5
    let selection = TimeWarpSelection(choices: choices)
    let plan = plan([item(.page, "short", frontMs: 60_000), item(.page, "long", frontMs: 300_000),
                     item(.page, "open", frontMs: 0, open: true)])
    #expect(selection.visibleItems(in: .pages, plan: plan).map(\.value) == ["long", "open"])
  }

  @Test func showAllListsEverything() {
    var choices = TimeWarpChoices()
    choices.minimumMinutes = 0
    let selection = TimeWarpSelection(choices: choices)
    #expect(selection.visibleItems(in: .pages, plan: plan([item(.page, "a", frontMs: 1)])).count == 1)
  }

  @Test func itemOverridesAndGroupState() {
    var selection = TimeWarpSelection(choices: TimeWarpChoices())
    let a = item(.page, "a")
    let b = item(.page, "b")
    let plan = plan([a, b])
    #expect(selection.groupState(.pages, plan: plan) == true)
    selection.setItem(a, checked: false)
    #expect(selection.groupState(.pages, plan: plan) == nil)
    selection.setItem(b, checked: false)
    #expect(selection.groupState(.pages, plan: plan) == false)
    // Setting an item back to its group's default removes the override.
    selection.setItem(a, checked: true)
    selection.setItem(b, checked: true)
    #expect(selection.overrides.isEmpty)
  }

  @Test func groupToggleResetsItemsAndIsRemembered() {
    var selection = TimeWarpSelection(choices: TimeWarpChoices())
    let a = item(.app, "a")
    let plan = plan([a])
    selection.setItem(a, checked: true)
    selection.setGroup(.apps, checked: false, plan: plan)
    #expect(!selection.isChecked(a))
    selection.setGroup(.apps, checked: true, plan: plan)
    #expect(selection.choices.checkedGroups.contains(.apps))
    #expect(selection.isChecked(a))
  }

  @Test func emptyGroupIsUnchecked() {
    #expect(TimeWarpSelection(choices: TimeWarpChoices()).groupState(.pages, plan: plan([])) == false)
  }

  @Test func whatWasInFrontAtAMomentShowsUnderTheMinimum() {
    var choices = TimeWarpChoices()
    choices.minimumMinutes = 15
    var now = item(.page, "now", frontMs: 5_000)
    now.wasFrontAtMoment = true
    let plan = plan([now, item(.page, "short", frontMs: 5_000)])
    #expect(TimeWarpSelection(choices: choices).visibleItems(in: .pages, plan: plan).map(\.value) == ["now"])
  }
}
