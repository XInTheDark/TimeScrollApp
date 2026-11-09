import SwiftUI

/// The File and View menu items for the timeline. Items that act on the main window are disabled
/// while another window is in front; Export works from anywhere.
struct TimelineCommands: Commands {
  @FocusedObject private var actions: TimelineMenuActions?

  var body: some Commands {
    CommandGroup(after: .saveItem) {
      Divider()
      item("Snapshot Actions…", .showSnapshotActions)
      item("Show in Finder", .revealInFinder)
      item("Save Snapshot…", .saveSnapshot)
      Divider()
      Button("Export…") { TimelapseExportWindowController.shared.present() }
    }
    CommandGroup(before: .toolbar) {
      Toggle("Select", isOn: selectionBinding)
        .disabled(!isAllowed(.toggleSelection))
    }
  }

  private func item(_ title: String, _ command: TimelineMenuCommand) -> some View {
    Button(title) { actions?.perform(command) }
      .disabled(!isAllowed(command))
  }

  private func isAllowed(_ command: TimelineMenuCommand) -> Bool {
    actions?.allows(command) ?? false
  }

  private var selectionBinding: Binding<Bool> {
    Binding(
      get: { actions?.isSelecting ?? false },
      set: { _ in actions?.perform(.toggleSelection) }
    )
  }
}
