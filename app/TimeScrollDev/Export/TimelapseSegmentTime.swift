import Foundation

/// Recording segments use the local wall-clock minute in their filename.
enum TimelapseSegmentTime {
  static func startMs(for url: URL) -> Int64? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.hasPrefix("seg-") else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    guard let date = formatter.date(from: String(name.dropFirst(4).prefix(19))) else { return nil }
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
}
