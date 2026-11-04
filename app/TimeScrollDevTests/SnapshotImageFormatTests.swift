import AppKit
import ImageIO
import Testing
@testable import TimeScroll

struct SnapshotImageFormatTests {
  @Test func movieAndVaultSourcesAlwaysSuggestImageFilenames() {
    for ext in ["mov", "tse", "jpg", "png"] {
      let source = URL(fileURLWithPath: "/tmp/snapshot.\(ext)")
      #expect(SnapshotImageFormat.png.filename(for: source) == "snapshot.png")
      #expect(SnapshotImageFormat.jpeg.filename(for: source) == "snapshot.jpg")
    }
  }

  @Test func encodedBytesMatchTheSelectedImageFormat() throws {
    let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
    let image = try #require(context.makeImage())
    for format in SnapshotImageFormat.allCases {
      let data = try format.encode(image)
      let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
      #expect(CGImageSourceGetType(source) as String? == format.contentType.identifier)
      let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(decoded.width == 96 && decoded.height == 64)
    }
  }
}
