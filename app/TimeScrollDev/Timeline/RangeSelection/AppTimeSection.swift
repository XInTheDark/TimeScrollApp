import AppKit
import SwiftUI

/// Total active time in a range and the apps it went to.
struct AppTimeSection: View {
  let stats: RangeSummaryPanelModel.Stats

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Time per App").font(.subheadline.weight(.semibold))
        Spacer(minLength: 4)
        if case .loaded(let report) = stats, report.totalDwellMs > 0 {
          Text(TimelineRangeFormat.duration(report.totalDwellMs))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    switch stats {
    case .loading:
      ProgressView().controlSize(.small)
    case .unavailable:
      Text("Time per app isn’t available right now.").foregroundStyle(.secondary)
    case .loaded(let report) where report.totalDwellMs == 0:
      Text("No screen activity in this range.").foregroundStyle(.secondary)
    case .loaded(let report):
      let largest = max(report.topApps.first?.dwellMs ?? 0, report.otherDwellMs, 1)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(report.topApps, id: \.app) { entry in
          AppTimeEntryRow(bundleId: entry.app, name: Self.name(for: entry), dwellMs: entry.dwellMs, largestMs: largest)
        }
        if report.otherDwellMs > 0 {
          AppTimeEntryRow(bundleId: nil, name: "Other", dwellMs: report.otherDwellMs, largestMs: largest)
        }
      }
    }
  }

  private static func name(for entry: AppTimeReport.Entry) -> String {
    if entry.app == AppTimeRow.unknownApp { return "Unknown" }
    return entry.name ?? entry.app
  }
}

private struct AppTimeEntryRow: View {
  let bundleId: String?
  let name: String
  let dwellMs: Int64
  let largestMs: Int64
  @State private var icon: NSImage?

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if let icon {
          Image(nsImage: icon).resizable()
        } else {
          Image(systemName: bundleId == nil ? "ellipsis.circle" : "app.dashed")
            .resizable()
            .scaledToFit()
            .padding(1)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 18, height: 18)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(name).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 4)
          Text(TimelineRangeFormat.duration(dwellMs))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.callout)

        GeometryReader { geometry in
          Capsule(style: .continuous)
            .fill(Color.accentColor.opacity(bundleId == nil ? 0.3 : 0.75))
            .frame(width: max(2, geometry.size.width * CGFloat(dwellMs) / CGFloat(largestMs)))
        }
        .frame(height: 3)
      }
    }
    .task(id: bundleId) {
      guard let bundleId, !bundleId.isEmpty else { return }
      AppIconCache.shared.loadIconAsync(for: bundleId) { icon = $0 }
    }
  }
}
