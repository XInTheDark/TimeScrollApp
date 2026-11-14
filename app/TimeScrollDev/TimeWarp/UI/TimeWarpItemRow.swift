import AppKit
import SwiftUI

/// One reopenable item: checkbox, icon, title, where it lives, and how long it was in front.
struct TimeWarpItemRow: View {
  let item: TimeWarpPlanItem
  /// Set for a moment's Time Warp, to show how long before it the item was in front.
  var momentMs: Int64? = nil
  let isMissing: Bool
  @Binding var isChecked: Bool

  var body: some View {
    let text = TimeWarpItemText(item: item, momentMs: momentMs, appName: TimeWarpIcons.appName)
    HStack(spacing: 8) {
      Toggle("", isOn: $isChecked)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(isMissing)
        .accessibilityLabel(text.title)
      Image(nsImage: TimeWarpIcons.icon(for: item))
        .resizable()
        .frame(width: 18, height: 18)
        .opacity(isMissing ? 0.5 : 1)
      VStack(alignment: .leading, spacing: 1) {
        Text(text.title)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(isMissing ? .secondary : .primary)
        if let subtitle = text.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      if isMissing {
        Text("Missing")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if text.detail != nil || text.recency != nil {
        VStack(alignment: .trailing, spacing: 1) {
          if let detail = text.detail {
            Text(detail)
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if let recency = text.recency {
            Text(recency)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .fixedSize()
      }
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onTapGesture { if !isMissing { isChecked.toggle() } }
    .help(isMissing ? "No longer at \(item.value)" : text.help)
  }
}
