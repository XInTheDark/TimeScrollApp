import AppKit
import AVFoundation
import Testing
@testable import TimeScroll

struct TimelapseReaderTests {
  @Test func sequentialReaderKeepsExactFramesAndRecoversOnlyTheirOwnPreviews() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("seg-2026-11-01-07-57-00-d1.mov")
    let start = try #require(TimelapseSegmentTime.startMs(for: url))
    let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let writer = try TimelapseVideoWriter(url: url, size: CGSize(width: 320, height: 180))
    for (index, offset) in [7294, 14800, 19799].enumerated() {
      context.setFillColor(index == 1 ? NSColor.green.cgColor : NSColor.red.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
      let frame = TimelapseFrame(id: Int64(index), timeMs: start + Int64(offset), path: url.path, format: "hevc")
      try await writer.append(image: #require(context.makeImage()), frame: frame, at: Double(offset) / 1000, timestamp: .hidden, check: {})
    }
    try await writer.finish(at: 24.7967)
    let loader = TimelapseImageLoader(maxPixel: 160)
    func frame(_ offset: Int64, preview: String? = nil) -> TimelapseFrame {
      TimelapseFrame(id: offset, timeMs: start + offset, path: url.path, format: "hevc", thumbPath: preview)
    }
    let red = try #require(try await loader.load(frame(7294), check: {}))
    let green = try #require(try await loader.load(frame(14800), check: {}))
    #expect(red.image.width == 160 && !red.usedPreview)
    #expect(green.image.width == 160 && !green.usedPreview)
    func pixel(_ image: CGImage) throws -> [UInt8] {
      let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
    }
    #expect(try pixel(red.image)[0] > 200)
    #expect(try pixel(green.image)[1] > 200)
    let third = try await loader.load(frame(19799), check: {})
    #expect(third != nil)
    // The source movie ended: do not reuse its last image under a different snapshot's timestamp.
    let unavailable = try await loader.load(frame(26083), check: {})
    #expect(unavailable == nil)
    let preview = directory.appendingPathComponent("saved-preview.png")
    try SnapshotImageFormat.png.encode(#require(context.makeImage())).write(to: preview)
    let recovered = try #require(try await loader.load(frame(33584, preview: preview.path), check: {}))
    #expect(recovered.usedPreview)
    let missing = try await loader.load(frame(41092, preview: directory.appendingPathComponent("missing.png").path), check: {})
    #expect(missing == nil)
    var cancelled = false
    do {
      _ = try await loader.load(frame(46089), check: { throw CancellationError() })
    } catch is CancellationError { cancelled = true }
    #expect(cancelled)
  }
}
