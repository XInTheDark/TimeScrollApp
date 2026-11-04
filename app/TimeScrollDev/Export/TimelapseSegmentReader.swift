import AVFoundation
import CoreImage

/// Decodes a segment once in presentation order, retaining at most the current and next sample.
final class TimelapseSegmentReader {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let entry: HEVCAssetCache.Entry
  private let context: CIContext
  private let maxPixel: CGFloat?
  private var current: CMSampleBuffer?
  private var next: CMSampleBuffer?
  private var lastRequest: Double = -1

  init(entry: HEVCAssetCache.Entry, context: CIContext, maxPixel: CGFloat?) async throws {
    self.entry = entry
    self.context = context
    self.maxPixel = maxPixel
    reader = try AVAssetReader(asset: entry.asset)
    guard let track = try await entry.asset.loadTracks(withMediaType: .video).first else { throw TimelapseError.encoding }
    output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw TimelapseError.encoding }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? TimelapseError.encoding }
    next = output.copyNextSampleBuffer()
  }

  deinit { reader.cancelReading() }

  func image(at offsetMs: Int64, check: () throws -> Void) throws -> CGImage? {
    let seconds = Double(offsetMs) / 1000
    guard seconds >= lastRequest else { return nil }
    lastRequest = seconds
    while let sample = next, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= seconds + 0.003 {
      try check()
      current = sample
      next = output.copyNextSampleBuffer()
    }
    guard let sample = current,
          abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - seconds) <= 0.003,
          let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
    try check()
    var image = CIImage(cvPixelBuffer: buffer)
    if let maxPixel {
      let scale = min(1, maxPixel / max(image.extent.width, image.extent.height))
      if scale < 1 {
        image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
      }
    }
    return autoreleasepool { context.createCGImage(image, from: image.extent) }
  }
}
