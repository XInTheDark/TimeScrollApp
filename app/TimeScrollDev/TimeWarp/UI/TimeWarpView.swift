import AppKit
import SwiftUI

/// The Time Warp sheet: what was in front (or open) during a block of time, to reopen.
struct TimeWarpView: View {
  @ObservedObject var model: TimeWarpSheetModel
  let onClose: () -> Void
  @State private var isConfirmingOpen = false

  /// Opening more than this many items at once asks first.
  static let confirmAbove = 20

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(minWidth: 420, idealWidth: 540, minHeight: 360, idealHeight: 560)
    .background(Color(nsColor: .windowBackgroundColor))
    .confirmationDialog("Open \(model.checkedItems.count) items?", isPresented: $isConfirmingOpen) {
      Button(openTitle) { open() }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func open() {
    Task {
      if await model.open() { onClose() }
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Time Warp")
          .font(.title2.weight(.semibold))
        Text(TimeWarpHeaderText.heading(target: model.target, range: model.range))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let moment = model.target.momentMs {
        lookbackRow(moment: moment)
      }
      Picker("Show", selection: $model.selection.choices.scope) {
        Text("What you used").tag(TimeWarpScope.visited)
        Text("Everything that was open").tag(TimeWarpScope.everythingOpen)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Show")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func lookbackRow(moment: Int64) -> some View {
    HStack(spacing: 10) {
      Picker("Look back", selection: lookbackBinding) {
        ForEach(TimeWarpLookback.allCases) { lookback in
          Text(lookback.title).tag(lookback)
            .selectionDisabled(lookback == .session && isSessionUnavailable)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      if !model.isLoading {
        Text(TimeWarpHeaderText.lookbackSummary(range: model.range, momentMs: moment))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
  }

  private var isSessionUnavailable: Bool { !model.isLoading && model.sessionStartMs == nil }

  /// Shows the look-back in use, which differs from the saved choice when the moment has no session.
  private var lookbackBinding: Binding<TimeWarpLookback> {
    Binding(
      get: { model.isLoading ? model.selection.choices.lookback : model.effectiveLookback },
      set: { model.selection.choices.lookback = $0 })
  }

  /// The next longer look-back that gives a longer block, for an empty moment.
  private var longerLookback: TimeWarpLookback? {
    guard model.target.momentMs != nil else { return nil }
    var next = model.effectiveLookback.longer
    if next == .session && model.sessionStartMs == nil { next = next?.longer }
    return next
  }

  private func expandTitle(_ lookback: TimeWarpLookback) -> String {
    switch lookback {
    case .fifteenMinutes, .hour: return "Look Back \(lookback.title)"
    case .session: return "Look Back to Session Start"
    case .today: return "Look Back to Start of Day"
    }
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if model.isLoading && model.plan.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.visibleGroups.isEmpty && model.plan.notes.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
          if model.selection.choices.scope == .everythingOpen && !model.plan.hasOpenItems {
            openItemsNotice
          }
          if !model.plan.notes.isEmpty { notesSection }
          ForEach(model.visibleGroups) { group in
            groupSection(group)
          }
        }
        .padding(16)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      Text("Nothing to reopen from this time.")
        .font(.headline)
      if !TimeWarpSettings.isEnabled() {
        Text("Time Warp is off.")
          .foregroundStyle(.secondary)
        Button("Open Settings…") { (NSApp.delegate as? AppDelegate)?.openPreferences() }
      } else if model.hiddenCount > 0 {
        Text(hiddenText)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Show All") { model.selection.choices.minimumMinutes = 0 }
      } else if let longer = longerLookback {
        Button(expandTitle(longer)) { model.selection.choices.lookback = longer }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var openItemsNotice: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text("Open tabs and windows weren’t recorded at this time.")
          .fixedSize(horizontal: false, vertical: true)
        if !TimeWarpSettings.recordsOpenItems() {
          Button("Open Settings…") { (NSApp.delegate as? AppDelegate)?.openPreferences() }
            .buttonStyle(.link)
        }
      }
    }
    .font(.callout)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
  }

  private var notesSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Warp Points")
        .font(.headline)
      ForEach(model.plan.notes) { note in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "mappin")
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text(note.note.isEmpty ? "Warp point" : note.note)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Text(TimeWarpItemText.time(note.timeMs))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func groupSection(_ group: TimeWarpGroup) -> some View {
    let items = model.selection.visibleItems(in: group, plan: model.plan)
    let openable = items.filter { !model.missingIds.contains($0.id) }
    return VStack(alignment: .leading, spacing: 4) {
      Group {
        if openable.isEmpty {
          Toggle(isOn: .constant(false)) { groupLabel(group, count: items.count) }
            .disabled(true)
        } else {
          // Each source writes through the group setter, so the group's choice is remembered.
          Toggle(sources: openable.map { groupBinding(for: $0, in: group) }, isOn: \.self) { groupLabel(group, count: items.count) }
        }
      }
      .toggleStyle(.checkbox)
      ForEach(items) { item in
        TimeWarpItemRow(item: item, momentMs: model.target.momentMs, isMissing: model.missingIds.contains(item.id),
                        isChecked: binding(for: item))
          .padding(.leading, 20)
      }
    }
  }

  private func groupLabel(_ group: TimeWarpGroup, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(group.title).font(.headline)
      Text("\(count)")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private func binding(for item: TimeWarpPlanItem) -> Binding<Bool> {
    Binding(
      get: { model.selection.isChecked(item) && !model.missingIds.contains(item.id) },
      set: { model.selection.setItem(item, checked: $0) })
  }

  private func groupBinding(for item: TimeWarpPlanItem, in group: TimeWarpGroup) -> Binding<Bool> {
    Binding(
      get: { model.selection.isChecked(item) && !model.missingIds.contains(item.id) },
      set: { model.selection.setGroup(group, checked: $0, plan: model.plan) })
  }

  // MARK: Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      // One row when it fits, otherwise the open options wrap below the filter.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          minimumPicker
          skipOpenToggle
          newWindowToggle
          Spacer(minLength: 0)
        }
        VStack(alignment: .leading, spacing: 6) {
          minimumPicker
          HStack(spacing: 12) {
            skipOpenToggle
            newWindowToggle
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          minimumPicker
          skipOpenToggle
          newWindowToggle
        }
      }
      HStack(spacing: 8) {
        status
          .layoutPriority(-1)
        Spacer(minLength: 8)
        Button("Cancel", action: onClose)
          .keyboardShortcut(.cancelAction)
        Button(openTitle) {
          if model.checkedItems.count > Self.confirmAbove { isConfirmingOpen = true } else { open() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.checkedItems.isEmpty || model.isOpening || model.isLoading)
      }
    }
    .padding(16)
  }

  private var minimumPicker: some View {
    Picker("Hide items in front for less than", selection: $model.selection.choices.minimumMinutes) {
      ForEach(TimeWarpChoices.minimumOptions, id: \.self) { minutes in
        Text(minutes == 0 ? "Show all" : "Hide under \(minutes) min").tag(minutes)
      }
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel("Hide items in front for less than")
  }

  private var skipOpenToggle: some View {
    Toggle("Skip what’s already open", isOn: $model.selection.choices.skipsOpenItems)
      .toggleStyle(.checkbox)
      .fixedSize()
      .help("Leaves out tabs, files, folders and apps that are open now")
  }

  private var newWindowToggle: some View {
    Toggle("Open pages in a new window", isOn: $model.selection.choices.opensInNewWindow)
      .toggleStyle(.checkbox)
      .fixedSize()
  }

  @ViewBuilder
  private var status: some View {
    if let result = model.lastResult, result.wasAllOpen {
      Label("Already open", systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Everything you chose is already open.")
    } else if let result = model.lastResult, !result.isComplete {
      let count = result.notOpened
      Label("\(count) \(count == 1 ? "item" : "items") couldn’t be opened.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .lineLimit(1)
        .help(result.refused > 0 ? "TimeScroll doesn’t open programs or scripts."
              : result.failed > 0 ? "The app that opens it reported an error." : "Moved or deleted since.")
    } else if model.hiddenCount > 0 && !model.visibleGroups.isEmpty {
      Text(hiddenText)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var hiddenText: String {
    let count = model.hiddenCount
    let minutes = model.selection.choices.minimumMinutes
    return "\(count) \(count == 1 ? "item" : "items") in front for under \(minutes) min hidden."
  }

  private var openTitle: String {
    let count = model.checkedItems.count
    return count == 0 ? "Open" : "Open \(count) \(count == 1 ? "Item" : "Items")"
  }
}
