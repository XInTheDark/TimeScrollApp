import SwiftUI

/// The Stats pane's controls and numbers, with no data loading of its own.
struct StatsContentView: View {
  @Binding var windowIndex: Int
  let summary: StatsSummary
  let onRefresh: () -> Void

  private var windows: [StatsWindow] { StatsWindow.all }

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          Slider(value: sliderValue, in: 0...Double(windows.count - 1), step: 1)
            .frame(maxWidth: 260)
          Text(windows[windowIndex].label)
            .font(.headline)
            .frame(width: 64, alignment: .leading)
        }
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Snapshots:")
            Text("\(summary.snapshotCount)").bold()
          }
          HStack {
            Text("Storage:")
            Text(StatsSummary.byteString(summary.storageBytes)).bold()
          }
          if let databaseBytes = summary.databaseBytes {
            HStack {
              Text("  - Snapshots:")
              Text(StatsSummary.byteString(summary.snapshotBytes)).bold()
            }.font(.footnote)
            HStack {
              Text("  - Database:")
              Text(StatsSummary.byteString(databaseBytes)).bold()
            }.font(.footnote)
          }
          HStack {
            Text("  - Avg snapshot:")
            Text(StatsSummary.byteString(summary.averageSnapshotBytes)).bold()
          }.font(.footnote)
          HStack {
            Text("Usage:")
            Text(StatsSummary.durationString(summary.usageSeconds)).bold()
          }
        }
        HStack {
          Spacer()
          Button("Refresh", action: onRefresh)
            .keyboardShortcut(.init("r"), modifiers: [.command])
        }
      }
      .frame(maxWidth: 420)
      Spacer(minLength: 0)
    }
  }

  private var sliderValue: Binding<Double> {
    Binding(
      get: { Double(windowIndex) },
      set: { windowIndex = max(0, min(windows.count - 1, Int($0.rounded()))) }
    )
  }
}
