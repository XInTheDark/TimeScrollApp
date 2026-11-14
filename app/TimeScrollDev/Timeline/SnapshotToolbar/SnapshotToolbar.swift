import AppKit
import SwiftUI

/// What the snapshot toolbar's buttons do.
struct SnapshotToolbarActions {
  var copyImage: () -> Void
  var copyText: () -> Void
  var save: () -> Void
  var reveal: () -> Void
  var delete: () -> Void
}

/// The floating toolbar over a screen snapshot: previous and next with the date, then copy, save,
/// find in the snapshot, Time Warp, and a menu for the rest.
struct SnapshotToolbar: View {
  @ObservedObject var model: TimelineModel
  @Binding var findQuery: String
  @Binding var isFinding: Bool
  let actions: SnapshotToolbarActions
  @FocusState private var findFocused: Bool

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .medium
    return f
  }()

  var body: some View {
    HStack(spacing: 2) {
      navigation
      SnapshotToolbarDivider()
      Menu {
        Button("Copy Image", action: actions.copyImage)
        Button("Copy Text", action: actions.copyText)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Copy")
      .accessibilityLabel("Copy")
      Button(action: actions.save) { Image(systemName: "square.and.arrow.down") }
        .help("Save snapshot")
        .accessibilityLabel("Save snapshot")
      find
      if let snapshot = model.selected {
        TimeWarpToolbarItems(snapshot: snapshot)
      }
      SnapshotToolbarDivider()
      more
    }
    .buttonStyle(SnapshotToolbarIconStyle())
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .snapshotToolbarSurface()
    .onChange(of: isFinding) { _, finding in findFocused = finding }
  }

  private var navigation: some View {
    HStack(spacing: 2) {
      Button(action: { model.prev() }) { Image(systemName: "chevron.left") }
        .disabled(!(model.selectedIndex + 1 < model.metas.count))
        .help("Previous snapshot")
        .accessibilityLabel("Previous snapshot")
      TimelineDateButton(text: model.selected.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0.startedAtMs) / 1000)) } ?? "",
                         selectedMs: model.selected?.startedAtMs,
                         calendar: model.dayCalendar)
        .padding(.horizontal, 6)
      Button(action: { model.next() }) { Image(systemName: "chevron.right") }
        .disabled(!(model.selectedIndex - 1 >= 0))
        .help("Next snapshot")
        .accessibilityLabel("Next snapshot")
    }
  }

  @ViewBuilder
  private var find: some View {
    if isFinding {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Find in snapshot", text: $findQuery)
          .textFieldStyle(.plain)
          .frame(width: 160)
          .focused($findFocused)
          .onExitCommand(perform: closeFind)
        Button(action: closeFind) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
          .buttonStyle(.plain)
          .help("Close find")
          .accessibilityLabel("Close find")
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
      .onAppear { findFocused = true }
    } else {
      Button { isFinding = true } label: { Image(systemName: "magnifyingglass") }
        .help("Find in snapshot")
        .accessibilityLabel("Find in snapshot")
    }
  }

  private var more: some View {
    Menu {
      Button("Show in Finder", action: actions.reveal)
      if SettingsStore.shared.debugMode, let id = model.selected?.id {
        Button("Copy Snapshot ID") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(String(id), forType: .string)
        }
      }
      Divider()
      Button("Delete Snapshot…", role: .destructive, action: actions.delete)
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More")
    .accessibilityLabel("More")
  }

  private func closeFind() {
    findQuery = ""
    isFinding = false
  }
}
