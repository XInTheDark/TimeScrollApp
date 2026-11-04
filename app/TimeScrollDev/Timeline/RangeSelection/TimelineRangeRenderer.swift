import AppKit

/// Draws the selected range over the timeline tracks: a tint between two edges with grab handles.
@MainActor
enum TimelineRangeRenderer {
  private static let handleSize = NSSize(width: 5, height: 22)

  static func draw(lowerX: CGFloat, upperX: CGFloat, in rect: NSRect) {
    let accent = NSColor.controlAccentColor
    accent.withAlphaComponent(0.2).setFill()
    NSRect(x: lowerX, y: rect.minY, width: max(1, upperX - lowerX), height: rect.height).fill(using: .sourceOver)

    accent.setFill()
    for x in [lowerX, upperX] {
      NSRect(x: x - 0.75, y: rect.minY, width: 1.5, height: rect.height).fill()
      let handle = NSRect(x: x - handleSize.width / 2, y: rect.midY - handleSize.height / 2,
                          width: handleSize.width, height: handleSize.height)
      NSBezierPath(roundedRect: handle, xRadius: 2.5, yRadius: 2.5).fill()
    }
  }
}
