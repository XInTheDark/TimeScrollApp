import AppKit
import AVFoundation
import Testing
@testable import TimeScroll

struct TimelapseVideoTests {
  @Test func encodesVariableFrameTimesAndFinalHold() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("timelapse-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let writer = try TimelapseVideoWriter(url: url, size: CGSize(width: 320, height: 180))
    for (index, seconds) in [0.0, 0.5, 2.0].enumerated() {
      context.setFillColor(index == 1 ? NSColor.blue.cgColor : NSColor.red.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
      let frame = TimelapseFrame(id: Int64(index), timeMs: Int64(index) * 1000, path: "", format: "png")
      try await writer.append(image: #require(context.makeImage()), frame: frame, at: seconds, timestamp: .topRight, check: {})
    }
    try await writer.finish(at: 2.5)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 2.5) < 0.02)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(size == CGSize(width: 320, height: 180))
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
    #expect(times == [0, 0.5, 2])
    #expect(reader.status == .completed)
  }

  @Test func cancellationInterruptsFrameSubmission() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("timelapse-cancel-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try TimelapseVideoWriter(url: url, size: CGSize(width: 320, height: 180))
    let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let frame = TimelapseFrame(id: 1, timeMs: 0, path: "", format: "png")
    do {
      try await writer.append(image: image, frame: frame, at: 0, timestamp: .hidden, check: { throw CancellationError() })
      Issue.record("Cancelled submission should throw")
    } catch is CancellationError {
      // Expected: no frame is submitted after cancellation.
    }
    writer.cancel()
  }

  @Test func qualityNeverUpscalesAndKeepsEvenDimensions() {
    #expect(TimelapseOptions.Quality.original.size(width: 3025, height: 1965) == CGSize(width: 3024, height: 1964))
    #expect(TimelapseOptions.Quality.fullHD.size(width: 3840, height: 2160) == CGSize(width: 1920, height: 1080))
    #expect(TimelapseOptions.Quality.hd.size(width: 640, height: 480) == CGSize(width: 640, height: 480))
  }
}
