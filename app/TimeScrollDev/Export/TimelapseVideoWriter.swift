import AVFoundation
import CoreGraphics

/// Owns only the encoder. Frames are supplied sequentially, with backpressure and no image queue.
final class TimelapseVideoWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let renderer = TimelapseRenderer()

  init(url: URL, size: CGSize) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0, AVVideoAllowFrameReorderingKey: false]
    ])
    input.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    guard writer.canAdd(input) else { throw TimelapseError.encoding }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? TimelapseError.encoding }
    writer.startSession(atSourceTime: .zero)
  }

  func append(image: CGImage, frame: TimelapseFrame, at seconds: Double, timestamp: TimelapseOptions.Timestamp,
              check: () throws -> Void) async throws {
    while !input.isReadyForMoreMediaData {
      try check()
      guard writer.status == .writing else { throw writer.error ?? TimelapseError.encoding }
      try await Task.sleep(for: .milliseconds(10))
    }
    try check()
    guard let pool = adaptor.pixelBufferPool else { throw TimelapseError.encoding }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw TimelapseError.encoding }
    try renderer.draw(image, timeMs: frame.timeMs, timestamp: timestamp, into: buffer)
    try check()
    guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000)) else {
      throw writer.error ?? TimelapseError.encoding
    }
  }

  func finish(at seconds: Double) async throws {
    writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 60_000))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? TimelapseError.encoding }
  }

  func cancel() { writer.cancelWriting() }
}
