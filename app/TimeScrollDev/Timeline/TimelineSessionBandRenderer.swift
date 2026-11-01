import AppKit

/// Draws the session band above the screen row: alternating neutral tints, the session holding the
/// selection in the accent color, and each band's fitted label. Only the visible slice is drawn.
@MainActor
enum TimelineSessionBandRenderer {
  nonisolated static let height: CGFloat = 12
  static let font = NSFont.systemFont(ofSize: 9.5, weight: .medium)

  static func labelWidth(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

  static func draw(bands: [TimelineSessionBand], selectedIndex: Int?, in row: NSRect, visibleRect: NSRect,
                   needsToDraw: (NSRect) -> Bool) {
    var index = TimelineSessionBandPlanner.firstIndex(endingAtOrAfter: visibleRect.minX - 1, in: bands)
    // A run drawn from its head can reach into view while its first bands lie left of it.
    if index < bands.count { index = bands[index].runHead }
    while index < bands.count, bands[index].x0 <= visibleRect.maxX + 1 {
      let band = bands[index]
      index += 1
      if band.isRunTail { continue }
      let rect = NSRect(x: band.x0, y: row.minY, width: band.drawX1 - band.x0, height: row.height)
      guard needsToDraw(rect) else { continue }
      let isSelected = selectedIndex.map { $0 >= band.sessionIndex && $0 <= band.runLast } ?? false
      let fill = isSelected
        ? NSColor.controlAccentColor.withAlphaComponent(0.28)
        : NSColor.labelColor.withAlphaComponent(band.sessionIndex.isMultiple(of: 2) ? 0.07 : 0.12)
      fill.setFill()
      let radius = min(4, rect.width / 2)
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

      guard let label = band.label else { continue }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ]
      let textHeight = font.ascender - font.descender
      // Keep the label readable while its band runs off the left edge.
      let textX = max(rect.minX, min(visibleRect.minX, rect.maxX - labelWidth(label) - 2 * TimelineSessionBandPlanner.labelPadding))
      let origin = NSPoint(x: textX + TimelineSessionBandPlanner.labelPadding, y: rect.midY - textHeight / 2)
      (label as NSString).draw(at: origin, withAttributes: attributes)
    }
  }
}
