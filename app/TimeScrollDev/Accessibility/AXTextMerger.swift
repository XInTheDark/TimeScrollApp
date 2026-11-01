import CoreGraphics

/// Joins per-window text front to back and turns boxes into OCR lines on the captured display.
enum AXTextMerger {
    static func merge(_ windows: [AXWindowText], displayBounds: CGRect, maxTotalChars: Int) -> AXTextExtractor.Capture {
        var text = String()
        var total = 0
        for window in windows where window.count > 0 {
            let allowed = min(window.count, maxTotalChars - total)
            if allowed <= 0 { break }
            if allowed == window.count {
                text.append(window.text)
            } else {
                text.append(contentsOf: window.text.prefix(allowed))
            }
            total += allowed
        }

        var lines: [OCRLine] = []
        if displayBounds.width > 0, displayBounds.height > 0 {
            for window in windows {
                for box in window.boxes {
                    let visible = box.frame.intersection(displayBounds)
                    guard !visible.isNull, visible.width > 1, visible.height > 1 else { continue }
                    lines.append(OCRLine(text: box.text, box: normalized(visible, in: displayBounds)))
                }
            }
        }
        return AXTextExtractor.Capture(text: text, lines: lines)
    }

    /// Vision convention: origin bottom-left, 0...1 of the display.
    static func normalized(_ rect: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: (rect.minX - display.minX) / display.width,
               y: 1 - (rect.maxY - display.minY) / display.height,
               width: rect.width / display.width,
               height: rect.height / display.height)
    }
}
