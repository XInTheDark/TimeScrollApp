import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Collects the fragmented MP4 an `AVAssetWriter` produces in memory. With the vault on, a
/// segment's video is encoded here and only its encrypted envelope is written to disk, so no
/// plaintext video ever exists in the storage folder.
final class HEVCSegmentMemoryOutput: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  /// A writer that hands its output to `output` instead of a file. The output interval is
  /// longer than a capture segment (60 s), so data is emitted only on `finishWriting` and the
  /// segment keeps one keyframe, the same size as the file-based writer. (`.indefinite` would
  /// do the same but AVFoundation allows it only for passthrough.)
  static func makeWriter(delivering output: HEVCSegmentMemoryOutput) -> AVAssetWriter {
    let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue) ?? .mpeg4Movie)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.preferredOutputSegmentInterval = CMTime(seconds: 120, preferredTimescale: 1)
    writer.initialSegmentStartTime = .zero
    writer.delegate = output
    return writer
  }

  func assetWriter(_ writer: AVAssetWriter,
                   didOutputSegmentData segmentData: Data,
                   segmentType: AVAssetSegmentType,
                   segmentReport: AVAssetSegmentReport?) {
    lock.lock()
    data.append(segmentData)
    lock.unlock()
  }

  /// The complete movie (initialization segment followed by media segments) and resets.
  func takeData() -> Data {
    lock.lock()
    defer { lock.unlock() }
    let out = data
    data = Data()
    return out
  }
}
