import SwiftUI
import AppKit

/// One search result card per activity session: its apps, label and span, the best match's
/// snippet, a strip of matching screens, and (on demand) every match in the session.
struct SearchSessionCardView: View {
  let group: SearchSessionGroup
  /// The best hit with its text loaded, for the snippet.
  let bestRow: SearchResultDisplayRow
  let query: String
  let intelligentAccuracy: Bool
  let onOpen: (SearchResult) -> Void

  @State private var isExpanded = false
  @State private var expandedRows: [SearchResultDisplayRow]?
  @State private var isHovering = false

  static let stripCount = 5
  static let maxExpanded = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button { onOpen(group.best) } label: { summary }
        .buttonStyle(.plain)

      filmstrip

      if group.hits.count > 1 {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
          if isExpanded { loadExpandedRowsIfNeeded() }
        } label: {
          Label(isExpanded ? "Hide matches" : "Show all \(group.hits.count) matches",
                systemImage: isExpanded ? "chevron.up" : "chevron.down")
            .font(.subheadline)
        }
        .buttonStyle(.link)
      }

      if isExpanded { expandedMatches }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundShape.fill(isHovering ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor).opacity(0.60)))
    .overlay(backgroundShape.stroke(isHovering ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
    }
  }

  // MARK: - Summary

  private var summary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        appIcons
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
            .lineLimit(1)
          if let keywords, !keywords.isEmpty {
            Text(keywords)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .trailing, spacing: 2) {
          Text(timeText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(detailText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .fixedSize()
      }

      snippet
        .font(.body)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
  }

  private var appIcons: some View {
    let bundleIds = group.session.map { $0.titleApps.compactMap(\.bundleId) } ?? group.best.appBundleId.map { [$0] } ?? []
    return ZStack(alignment: .leading) {
      if bundleIds.isEmpty {
        SearchResultIdentityIcon(row: group.best, size: 28, cornerRadius: 7)
      }
      ForEach(Array(bundleIds.prefix(3).enumerated()), id: \.offset) { index, bundleId in
        AppBundleIconView(bundleId: bundleId, size: 28, cornerRadius: 7)
          .offset(x: CGFloat(index) * 16)
      }
    }
    .frame(width: 28 + CGFloat(max(0, min(3, bundleIds.count) - 1)) * 16, height: 28, alignment: .leading)
  }

  private var snippet: Text {
    if let attributed = bestRow.snippet, !attributed.characters.isEmpty { return Text(attributed) }
    return Text(bestRow.fallbackSnippet).foregroundColor(.secondary)
  }

  // MARK: - Matches

  private var filmstrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(group.hits.prefix(Self.stripCount)) { hit in
          Button { onOpen(hit) } label: {
            SearchResultThumbnailView(row: hit, maxPixel: 260, width: 128, height: 80)
          }
          .buttonStyle(.plain)
          .help(Self.timeFormatter.string(from: date(hit.startedAtMs)))
        }
        if group.hits.count > Self.stripCount {
          Text("+\(group.hits.count - Self.stripCount)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 80)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.08)))
        }
      }
    }
  }

  @ViewBuilder
  private var expandedMatches: some View {
    if let expandedRows {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
        ForEach(expandedRows) { row in
          Button { onOpen(row.result) } label: { SearchTileView(row: row) }
            .buttonStyle(.plain)
        }
      }
      if group.hits.count > expandedRows.count {
        Text("Showing the first \(expandedRows.count) of \(group.hits.count) matches.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }
  }

  private func loadExpandedRowsIfNeeded() {
    guard expandedRows == nil else { return }
    let hits = Array(group.hits.prefix(Self.maxExpanded))
    let query = query
    let intelligentAccuracy = intelligentAccuracy
    DispatchQueue.global(qos: .userInitiated).async {
      let hydrated = (try? DB.shared.hydrateSearchResultContents(hits)) ?? hits
      let rows = hydrated.map { SearchResultDisplayRow(result: $0, query: query, intelligentAccuracy: intelligentAccuracy) }
      DispatchQueue.main.async { expandedRows = rows }
    }
  }

  // MARK: - Text

  private var title: String {
    group.session?.title
      ?? group.best.appName
      ?? group.best.audioSourceKind?.displayName
      ?? group.best.appBundleId
      ?? group.best.captureKind.displayName
  }

  private var keywords: String? {
    group.session?.keywords.joined(separator: ", ")
  }

  private var timeText: String {
    guard let session = group.session, session.durationMs >= 60_000 else {
      return Self.timeFormatter.string(from: date(group.session?.startMs ?? group.best.startedAtMs))
    }
    return Self.intervalFormatter.string(from: date(session.startMs), to: date(session.endMs))
  }

  private var detailText: String {
    let matches = group.hits.count == 1 ? "1 match" : "\(group.hits.count) matches"
    guard let session = group.session, session.durationMs >= 60_000,
          let duration = Self.durationFormatter.string(from: TimeInterval(session.durationMs) / 1000) else { return matches }
    return "\(matches) · \(duration)"
  }

  private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

  private var backgroundShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let intervalFormatter: DateIntervalFormatter = {
    let formatter = DateIntervalFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
}
