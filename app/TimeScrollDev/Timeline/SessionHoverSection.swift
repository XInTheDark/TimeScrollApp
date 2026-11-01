import AppKit
import SwiftUI

/// The session part of the timeline hover preview, shown under the thumbnail's own rows: the time
/// range, and a row per app with its share of the session, then the session's keywords.
struct SessionHoverSection: View {
  let content: SessionHoverContent
  let icons: [String: NSImage]

  var body: some View {
    VStack(alignment: .leading, spacing: SessionHoverContent.spacing) {
      VStack(alignment: .leading, spacing: 2) {
        Text(content.rangeText).font(.caption.weight(.semibold)).lineLimit(1)
        Text(content.summaryText).font(.caption2).foregroundColor(.secondary).lineLimit(1)
      }
      .frame(height: SessionHoverContent.headerHeight, alignment: .leading)

      ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 6) {
          Group {
            if let icon = row.bundleId.flatMap({ icons[$0] }) {
              Image(nsImage: icon).resizable()
            } else {
              RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: AppColor.color(for: row.bundleId)).opacity(0.5))
            }
          }
          .frame(width: 14, height: 14)
          Text(row.name).font(.caption).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 4)
          ShareBar(fraction: row.fraction, color: Color(nsColor: AppColor.color(for: row.bundleId)))
            .frame(width: 52, height: 5)
          Text(row.durationText).font(.caption2).foregroundColor(.secondary).monospacedDigit()
            .frame(width: 42, alignment: .trailing).lineLimit(1)
        }
        .frame(height: SessionHoverContent.rowHeight)
      }

      if let keywords = content.keywordsText {
        Text(keywords)
          .font(.caption2).foregroundColor(.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, minHeight: SessionHoverContent.keywordsHeight, maxHeight: SessionHoverContent.keywordsHeight,
                 alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ShareBar: View {
  let fraction: Double
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.15))
        Capsule().fill(color).frame(width: max(3, proxy.size.width * fraction))
      }
    }
  }
}
