import AppKit

/// Keeps the native save panel's allowed type and filename in sync with its format picker.
@MainActor
final class SnapshotImageFormatAction: NSObject {
  private weak var panel: NSSavePanel?

  init(panel: NSSavePanel) { self.panel = panel }

  @objc func changed(_ sender: NSPopUpButton) {
    guard let panel, SnapshotImageFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
    let format = SnapshotImageFormat.allCases[sender.indexOfSelectedItem]
    panel.allowedContentTypes = [format.contentType]
    panel.nameFieldStringValue = format.filename(for: URL(fileURLWithPath: panel.nameFieldStringValue))
  }
}
