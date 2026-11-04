import ImageIO
import UniformTypeIdentifiers
import Foundation

enum SnapshotImageFormat: String, CaseIterable {
  case png = "PNG", jpeg = "JPEG"

  var contentType: UTType { self == .png ? .png : .jpeg }
  var filenameExtension: String { self == .png ? "png" : "jpg" }

  func filename(for source: URL) -> String {
    source.deletingPathExtension().lastPathComponent + "." + filenameExtension
  }

  func encode(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, contentType.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image,
                               [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
  }
}
