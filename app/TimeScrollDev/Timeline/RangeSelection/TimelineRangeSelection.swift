import Foundation

/// Whether the timeline is selecting, what is selected, and whether its summary is open. Views that
/// show it observe it directly, so a drag doesn't re-evaluate the whole timeline view.
@MainActor
final class TimelineRangeSelection: ObservableObject {
  @Published private(set) var isActive = false
  @Published private(set) var range: TimelineRange?
  @Published private(set) var isSummaryOpen = false
  /// Changes each time the user asks for a summary.
  @Published private(set) var summaryRequest = 0
  /// Changes when the Delete key asks to delete the range.
  @Published private(set) var deleteRequest = 0

  func begin() {
    isActive = true
  }

  func end() {
    isActive = false
    range = nil
    isSummaryOpen = false
  }

  func toggle() {
    if isActive { end() } else { begin() }
  }

  func select(_ range: TimelineRange) {
    guard isActive else { return }
    self.range = range
  }

  func requestSummary() {
    guard isActive, range != nil else { return }
    isSummaryOpen = true
    summaryRequest &+= 1
  }

  func requestDelete() {
    guard isActive, range != nil else { return }
    deleteRequest &+= 1
  }

  func closeSummary() {
    isSummaryOpen = false
  }
}
