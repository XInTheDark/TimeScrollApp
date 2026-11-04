import AppKit
import SwiftUI

/// Shows the selection bar while selecting, and carries out its delete.
struct RangeSelectionBarSlot: View {
  @ObservedObject var selection: TimelineRangeSelection
  @ObservedObject var timeline: TimelineModel
  let onSearch: (TimelineRange) -> Void
  @StateObject private var actions = RangeActionsModel()

  var body: some View {
    // A container that stays when empty: modifiers on an empty Group may never run.
    VStack(spacing: 0) {
      if selection.isActive {
        Divider()
        RangeSelectionBar(selection: selection, actions: actions, timeline: timeline,
                          fallbackRange: fallbackRange, onSearch: onSearch,
                          onExport: { TimelapseExportWindowController.shared.present(range: $0) },
                          onDelete: confirmAndDelete)
      }
    }
    .onChange(of: selection.range) { _, range in
      actions.refreshCount(for: range.flatMap { timeline.shownRows(in: $0) })
    }
    .onChange(of: selection.deleteRequest) { _, _ in confirmAndDelete() }
  }

  /// The selected snapshot's day, or today.
  private var fallbackRange: TimelineRange {
    let calendar = Calendar.current
    let anchor = timeline.selected.map { Date(timeIntervalSince1970: TimeInterval($0.startedAtMs) / 1000) } ?? Date()
    let start = calendar.startOfDay(for: anchor)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return TimelineRange(fromMs: Int64(start.timeIntervalSince1970 * 1000), toMs: Int64(end.timeIntervalSince1970 * 1000))!
  }

  private func confirmAndDelete() {
    guard let range = selection.range, let filter = timeline.shownRows(in: range),
          let count = actions.count, count.total > 0, !actions.isDeleting else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete \(TimelineRangeFormat.counts(count))?"
    var details = "From \(TimelineRangeFormat.period(range)). This permanently deletes them from disk, along with any summaries that cover this time."
    if filter.isFiltered { details += " Only items matching your filters are deleted." }
    alert.informativeText = details
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    selection.closeSummary()
    Task {
      if await actions.delete(filter) {
        timeline.removeRows(matching: filter)
        selection.end()
      } else {
        NSSound.beep()
        timeline.load()
        actions.refreshCount(for: filter)
      }
    }
  }
}
