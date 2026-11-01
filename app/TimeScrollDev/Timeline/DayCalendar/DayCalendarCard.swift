import SwiftUI

/// Month calendar floating over the stage. Each day is shaded by how long capture ran that day;
/// days without captures are disabled. Clicking a day jumps the timeline there.
struct DayCalendarCard: View {
  @ObservedObject var calendar: DayCalendarController
  @ObservedObject var model: TimelineModel

  private let cal = Calendar.current
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

  private var selectedDay: Date? {
    model.selected.map { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.startedAtMs) / 1000)) }
  }

  /// Recorded time that gets the strongest shade: the month's busiest day, but at least an hour.
  private var shadeReferenceMs: Int64 {
    max(3_600_000, calendar.activity.values.map(\.coveredMs).max() ?? 0)
  }

  var body: some View {
    VStack(spacing: 10) {
      header
      weekdayRow
      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(0..<leadingBlankCount, id: \.self) { _ in Color.clear.frame(height: 34) }
        ForEach(days, id: \.self) { day in dayCell(day) }
      }
    }
    .padding(14)
    .frame(width: 310)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 4) {
      Text(calendar.visibleMonth.formatted(.dateTime.month(.wide).year()))
        .font(.headline)
      if calendar.isLoading {
        ProgressView().controlSize(.small).padding(.leading, 4)
      }
      Spacer()
      Button { calendar.stepMonth(by: -1) } label: { Image(systemName: "chevron.left") }
        .help("Previous month")
        .accessibilityLabel("Previous month")
      Button { calendar.stepMonth(by: 1) } label: { Image(systemName: "chevron.right") }
        .disabled(!canStepForward)
        .help("Next month")
        .accessibilityLabel("Next month")
      Button { calendar.dismiss() } label: { Image(systemName: "xmark.circle.fill") }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .help("Close calendar")
        .accessibilityLabel("Close calendar")
    }
    .buttonStyle(.borderless)
  }

  private var canStepForward: Bool {
    guard let next = cal.date(byAdding: .month, value: 1, to: calendar.visibleMonth) else { return false }
    return next <= Date()
  }

  private var weekdayRow: some View {
    LazyVGrid(columns: columns, spacing: 0) {
      ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol).font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var weekdaySymbols: [String] {
    let symbols = cal.veryShortStandaloneWeekdaySymbols
    let first = cal.firstWeekday - 1
    return Array(symbols[first...] + symbols[..<first])
  }

  // MARK: - Days

  private var days: [Date] {
    guard let range = cal.range(of: .day, in: .month, for: calendar.visibleMonth) else { return [] }
    return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: calendar.visibleMonth) }
  }

  private var leadingBlankCount: Int {
    let weekday = cal.component(.weekday, from: calendar.visibleMonth)
    return (weekday - cal.firstWeekday + 7) % 7
  }

  private func dayCell(_ day: Date) -> some View {
    let activity = calendar.activity[day]
    let hasCaptures = (activity?.snapshotCount ?? 0) > 0
    let isSelected = day == selectedDay
    let isToday = cal.isDateInToday(day)
    return Button { model.openDay(day) } label: {
      Text("\(cal.component(.day, from: day))")
        .font(.system(size: 13, weight: isSelected ? .bold : .regular).monospacedDigit())
        .foregroundStyle(hasCaptures ? Color.primary : Color.secondary.opacity(0.5))
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(shade(for: activity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : (isToday ? Color.primary.opacity(0.4) : .clear),
                          lineWidth: isSelected ? 2 : 1)
        )
    }
    .buttonStyle(.plain)
    .disabled(!hasCaptures)
    .help(tooltip(for: activity, day: day))
  }

  /// Square-root scale so short days stay visible next to long ones.
  private func shade(for activity: DayActivity?) -> Color {
    guard let activity, activity.snapshotCount > 0 else { return Color.primary.opacity(0.04) }
    let share = min(1, Double(activity.coveredMs) / Double(shadeReferenceMs))
    return Color.accentColor.opacity(0.15 + 0.6 * share.squareRoot())
  }

  private func tooltip(for activity: DayActivity?, day: Date) -> String {
    let title = day.formatted(date: .complete, time: .omitted)
    guard let activity, activity.snapshotCount > 0 else { return "\(title): no captures" }
    return "\(title)\n\(Self.duration(activity.coveredMs)) recorded · \(activity.snapshotCount) snapshots"
  }

  private static func duration(_ ms: Int64) -> String {
    let minutes = Int(ms / 60_000)
    if minutes < 1 { return "<1m" }
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
  }
}

/// Shows the calendar above the stage while it is open.
struct DayCalendarHost: View {
  @ObservedObject var calendar: DayCalendarController
  @ObservedObject var model: TimelineModel

  var body: some View {
    if calendar.isPresented {
      DayCalendarCard(calendar: calendar, model: model)
        .transition(.opacity)
    }
  }
}
