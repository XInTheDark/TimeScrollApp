import Foundation

extension TimelineModel {
  /// Shows the earliest capture of `day` (local time), with the timeline opened around it.
  func openDay(_ day: Date) {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    let fromMs = Int64(start.timeIntervalSince1970 * 1000)
    let toMs = Int64(end.timeIntervalSince1970 * 1000)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let first = (try? DB.shared.firstSnapshot(fromMs: fromMs, toMs: toMs)) ?? nil else { return }
      DispatchQueue.main.async {
        self?.openSnapshot(id: first.id, anchorStartedAtMs: first.startedAtMs)
      }
    }
  }
}
