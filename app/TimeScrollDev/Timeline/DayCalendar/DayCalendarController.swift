import Foundation

/// State of the day-picker calendar: whether it is open, which month it shows, and how much was
/// recorded on each day of that month. Opening and closing is explicit (the calendar never
/// dismisses itself), so the user can click through several days.
@MainActor
final class DayCalendarController: ObservableObject {
  @Published private(set) var isPresented = false
  /// First day of the month on display.
  @Published private(set) var visibleMonth = Date()
  @Published private(set) var activity: [Date: DayActivity] = [:]
  @Published private(set) var isLoading = false

  private let calendar = Calendar.current
  private var loadToken = 0

  func toggle(showing date: Date?) {
    if isPresented { dismiss() } else { present(showing: date) }
  }

  func present(showing date: Date?) {
    visibleMonth = monthStart(of: date ?? Date())
    isPresented = true
    loadActivity()
  }

  func dismiss() {
    isPresented = false
    loadToken &+= 1
    isLoading = false
  }

  func stepMonth(by delta: Int) {
    guard let month = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
    show(month: month)
  }

  func show(month: Date) {
    visibleMonth = monthStart(of: month)
    loadActivity()
  }

  private func monthStart(of date: Date) -> Date {
    calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  private func loadActivity() {
    loadToken &+= 1
    let token = loadToken
    let month = visibleMonth
    let calendar = calendar
    let end = calendar.date(byAdding: .month, value: 1, to: month) ?? month.addingTimeInterval(31 * 86_400)
    let fromMs = Int64(month.timeIntervalSince1970 * 1000)
    let toMs = Int64(end.timeIntervalSince1970 * 1000)
    isLoading = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let rows = (try? DB.shared.captureIntervals(fromMs: fromMs, toMs: toMs)) ?? []
      let result = DayActivityCalculator.activity(intervals: rows, calendar: calendar)
      DispatchQueue.main.async {
        guard let self, token == self.loadToken else { return }
        self.activity = result
        self.isLoading = false
      }
    }
  }
}
