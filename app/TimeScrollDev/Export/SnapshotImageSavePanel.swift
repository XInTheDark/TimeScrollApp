import AppKit
import UniformTypeIdentifiers

@MainActor
enum SnapshotImageSavePanel {
  static func save(image: NSImage, sourceURL: URL) {
    guard let access = VaultMediaAccess.token(for: sourceURL),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { NSSound.beep(); return }
    let panel = NSSavePanel()
    panel.title = "Save Image As"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = SnapshotImageFormat.png.filename(for: sourceURL)
    let formats = NSPopUpButton()
    formats.addItems(withTitles: SnapshotImageFormat.allCases.map(\.rawValue))
    let label = NSTextField(labelWithString: "Format:")
    let row = NSStackView(views: [label, formats])
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
    accessory.addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
      row.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
      row.leadingAnchor.constraint(greaterThanOrEqualTo: accessory.leadingAnchor, constant: 16),
      row.topAnchor.constraint(greaterThanOrEqualTo: accessory.topAnchor, constant: 12)
    ])
    panel.accessoryView = accessory
    let action = SnapshotImageFormatAction(panel: panel)
    formats.target = action
    formats.action = #selector(SnapshotImageFormatAction.changed(_:))
    guard withExtendedLifetime(action, { panel.runModal() }) == .OK, let destination = panel.url else { return }
    do {
      let format = SnapshotImageFormat.allCases[formats.indexOfSelectedItem]
      let data = try format.encode(cgImage)
      guard VaultMediaAccess.isCurrent(access, for: sourceURL) else { throw TimelapseError.locked }
      try data.write(to: destination, options: .atomic)
    } catch {
      let alert = NSAlert(error: error)
      alert.runModal()
    }
  }
}
