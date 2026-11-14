import SwiftUI

/// The date shown in the snapshot toolbar. Clicking it opens or closes the day calendar.
struct TimelineDateButton: View {
  let text: String
  let selectedMs: Int64?
  @ObservedObject var calendar: DayCalendarController
  @State private var isHovering = false

  var body: some View {
    Button {
      calendar.toggle(showing: selectedMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    } label: {
      Text(text)
        .font(.system(size: 14, weight: .medium).monospacedDigit())
        .foregroundStyle(.primary)
        // Highlight outside the text's own bounds so the pill's layout stays exactly as before.
        .background {
          Capsule()
            .fill(Color.primary.opacity(calendar.isPresented ? 0.16 : (isHovering ? 0.08 : 0)))
            .padding(.horizontal, -8)
            .padding(.vertical, -3)
        }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(calendar.isPresented ? "Close calendar" : "Pick a day")
    .accessibilityLabel(calendar.isPresented ? "Close calendar" : "Pick a day")
  }
}
