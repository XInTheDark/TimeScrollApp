import AppKit
import CoreText
import CoreVideo

/// Draws one aspect-fitted snapshot and its optional timestamp into the encoder's buffer.
final class TimelapseRenderer {
  private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
  }()

  func draw(_ image: CGImage, timeMs: Int64, timestamp: TimelapseOptions.Timestamp, into buffer: CVPixelBuffer) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
      throw TimelapseError.encoding
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(bounds)
    let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    guard timestamp != .hidden else { return }

    let fontSize = max(8, min(bounds.width / 38, bounds.height / 24))
    let text = formatter.string(from: Date(timeIntervalSince1970: Double(timeMs) / 1000))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
    ]))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let padding = fontSize * 0.5
    let margin = fontSize * 0.6
    let boxWidth = textWidth + padding * 2, boxHeight = ascent + descent + padding * 2
    let left = timestamp == .topLeft || timestamp == .bottomLeft
    let top = timestamp == .topLeft || timestamp == .topRight
    let box = CGRect(x: left ? margin : bounds.width - margin - boxWidth,
                     y: top ? bounds.height - margin - boxHeight : margin, width: boxWidth, height: boxHeight)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(box)
    context.textPosition = CGPoint(x: box.minX + padding, y: box.minY + padding + descent)
    CTLineDraw(line, context)
  }
}
