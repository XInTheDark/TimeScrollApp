import AppKit
import SwiftUI

/// Shown above the timeline while selecting: the range as editable dates, what it holds, and what
/// can be done with it.
struct RangeSelectionBar: View {
  @ObservedObject var selection: TimelineRangeSelection
  @ObservedObject var actions: RangeActionsModel
  let timeline: TimelineModel
  /// When nothing is selected, the fields start from this range.
  let fallbackRange: TimelineRange
  let onSearch: (TimelineRange) -> Void
  let onExport: (TimelineRange) -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      presetsMenu
      dateFields
      Divider().frame(height: 20)
      status
        .frame(minWidth: 40, alignment: .leading)
        .layoutPriority(-1)
      Spacer(minLength: 8)
      trailing
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var shownRange: TimelineRange { selection.range ?? fallbackRange }

  private var presetsMenu: some View {
    Menu {
      ForEach(TimelineRangePreset.allCases) { preset in
        Button(preset.rawValue) {
          guard let range = preset.range(now: Date(), calendar: .current) else { return }
          apply(range)
        }
      }
    } label: {
      Image(systemName: "calendar")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Common ranges")
    .accessibilityLabel("Common ranges")
    .disabled(actions.isDeleting)
  }

  private var dateFields: some View {
    HStack(spacing: 6) {
      ExportDatePicker(date: dateBinding(get: \.fromMs) { shownRange.withFrom($0) })
        .fixedSize()
        .accessibilityLabel("From")
      Image(systemName: "arrow.right")
        .font(.caption)
        .foregroundStyle(.secondary)
      ExportDatePicker(date: dateBinding(get: \.toMs) { shownRange.withTo($0) })
        .fixedSize()
        .accessibilityLabel("To")
    }
    .disabled(actions.isDeleting)
  }

  private func dateBinding(get: KeyPath<TimelineRange, Int64>, set: @escaping (Int64) -> TimelineRange) -> Binding<Date> {
    Binding(
      get: { Date(timeIntervalSince1970: TimeInterval(shownRange[keyPath: get]) / 1000) },
      set: { apply(set(Int64($0.timeIntervalSince1970 * 1000))) })
  }

  private func apply(_ range: TimelineRange) {
    selection.select(range)
    timeline.reveal(range)
  }

  @ViewBuilder
  private var status: some View {
    if actions.deleteFailed {
      Label("Some items couldn’t be deleted.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .lineLimit(1)
        .font(.callout)
    } else if let range = selection.range {
      HStack(spacing: 6) {
        Text(TimelineRangeFormat.duration(range.durationMs)).fontWeight(.medium)
        if let count = actions.count {
          ViewThatFits(in: .horizontal) {
            Text(TimelineRangeFormat.counts(count))
            Text("\(count.total.formatted()) \(count.total == 1 ? "item" : "items")")
          }
          .foregroundStyle(.secondary)
          .help(TimelineRangeFormat.counts(count))
        } else {
          ProgressView().controlSize(.mini)
        }
      }
      .lineLimit(1)
      .font(.callout)
    } else {
      ViewThatFits(in: .horizontal) {
        Text("Drag on the timeline, or enter dates.")
        Text("Drag on the timeline.")
      }
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .font(.callout)
    }
  }

  @ViewBuilder
  private var trailing: some View {
    if actions.isDeleting {
      HStack(spacing: 8) {
        ProgressView(value: deleteProgress).frame(width: 120)
        Text("Deleting…").font(.callout).foregroundStyle(.secondary)
      }
    } else {
      ViewThatFits(in: .horizontal) {
        actionButtons(showsAllTitles: true)
        actionButtons(showsAllTitles: false)
      }
    }
  }

  private var deleteProgress: Double {
    guard let total = actions.count?.total, total > 0 else { return 0 }
    return min(1, Double(actions.deletedCount) / Double(total))
  }

  private func actionButtons(showsAllTitles: Bool) -> some View {
    HStack(spacing: 8) {
      actionButton("Search in Range", systemImage: "magnifyingglass", showsTitle: showsAllTitles) {
        if let range = selection.range { onSearch(range) }
      }
      .disabled(selection.range == nil)

      actionButton("Export Timelapse…", systemImage: "film", showsTitle: showsAllTitles) {
        if let range = selection.range { onExport(range) }
      }
      .disabled(selection.range == nil)

      Button { selection.requestSummary() } label: {
        Label("Summarize", systemImage: "text.alignleft")
      }
      .buttonStyle(.borderedProminent)
      .disabled(selection.range == nil)

      Button(role: .destructive, action: onDelete) {
        if showsAllTitles {
          Label("Delete…", systemImage: "trash")
        } else {
          Image(systemName: "trash")
        }
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Delete")
      .disabled(!canDelete)
      .help(deleteHelp)

      Button("Done") { selection.end() }
        .buttonStyle(.bordered)
    }
    .fixedSize()
  }

  private func actionButton(_ title: String, systemImage: String, showsTitle: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      if showsTitle {
        Label(title, systemImage: systemImage)
      } else {
        Image(systemName: systemImage)
      }
    }
    .buttonStyle(.bordered)
    .help(title)
    .accessibilityLabel(title)
  }

  private var canDelete: Bool {
    guard selection.range != nil, timeline.hasDeletableRows else { return false }
    return (actions.count?.total ?? 0) > 0
  }

  private var deleteHelp: String {
    timeline.hasDeletableRows ? "Delete everything shown in this range" : "Clear your search to delete a range"
  }
}
