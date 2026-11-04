import AppKit
import CoreVideo
import Testing
@testable import TimeScroll

struct TimelapseRendererTests {
  @Test func timestampUsesSelectedCornerAndCanBeHidden() throws {
    let context = try #require(CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
    let image = try #require(context.makeImage())
    for position in TimelapseOptions.Timestamp.allCases {
      var optional: CVPixelBuffer?
      #expect(CVPixelBufferCreate(nil, 960, 540, kCVPixelFormatType_32BGRA,
                                 [kCVPixelBufferCGImageCompatibilityKey: true,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &optional) == kCVReturnSuccess)
      let buffer = try #require(optional)
      try TimelapseRenderer().draw(image, timeMs: 1_798_761_600_000, timestamp: position, into: buffer)
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      // Black background pixels are distinct from the solid blue source, independent of locale/text width.
      var blackByQuadrant = [Int](repeating: 0, count: 4)
      for y in 0..<540 {
        for x in 0..<960 {
          let offset = y * stride + x * 4
          if pixels[offset] < 10 && pixels[offset + 1] < 10 && pixels[offset + 2] < 10 {
            blackByQuadrant[(y < 270 ? 0 : 2) + (x < 480 ? 0 : 1)] += 1
          }
        }
      }
      if position == .hidden {
        #expect(blackByQuadrant.allSatisfy { $0 == 0 })
      } else {
        let top = position == .topLeft || position == .topRight
        let left = position == .topLeft || position == .bottomLeft
        // Pixel-buffer rows start at the top, unlike the compositor's drawing coordinates.
        let expected = (top ? 0 : 2) + (left ? 0 : 1)
        #expect(blackByQuadrant[expected] > 100)
        #expect(blackByQuadrant.enumerated().allSatisfy { $0.offset == expected || $0.element == 0 })
      }
    }
  }
}
