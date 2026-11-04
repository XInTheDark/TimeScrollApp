import SwiftUI

/// Shows the summary panel beside the viewer and keeps its model on the selected range.
struct RangeSummaryPanelSlot: View {
  @ObservedObject var selection: TimelineRangeSelection
  let isTimelineFiltered: () -> Bool
  @StateObject private var model = RangeSummaryPanelModel()

  private static let rangeChangeDelay: Duration = .milliseconds(300)

  var body: some View {
    // A container that stays when empty: modifiers on an empty Group may never run.
    HStack(spacing: 0) {
      if selection.isSummaryOpen, let range = selection.range {
        Divider()
        RangeSummaryPanel(model: model, title: TimelineRangeFormat.period(range), isTimelineFiltered: isTimelineFiltered(),
                          onClose: { selection.closeSummary() })
      }
    }
    .onChange(of: selection.summaryRequest) { _, _ in
      if let range = selection.range { model.show(range, generate: true) }
    }
    .onChange(of: selection.isSummaryOpen) { _, isOpen in
      if !isOpen { model.close() }
    }
    // Waits for a drag to settle. Changing the range never starts the model.
    .task(id: selection.range) {
      guard selection.isSummaryOpen, let range = selection.range else { return }
      try? await Task.sleep(for: Self.rangeChangeDelay)
      guard !Task.isCancelled else { return }
      model.show(range, generate: false)
    }
  }
}
