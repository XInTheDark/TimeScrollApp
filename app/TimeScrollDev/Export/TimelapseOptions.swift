import Foundation
import CoreGraphics

struct TimelapseOptions: Sendable {
  enum Quality: String, CaseIterable, Identifiable, Sendable {
    case original = "Source resolution", fullHD = "1080p", hd = "720p"
    var id: Self { self }

    func size(width: Int, height: Int) -> CGSize {
      let limit: Double = self == .original ? Double(max(width, height)) : (self == .fullHD ? 1920 : 1280)
      let scale = min(1, limit / Double(max(1, max(width, height))))
      return CGSize(width: max(2, Int(Double(width) * scale) / 2 * 2),
                    height: max(2, Int(Double(height) * scale) / 2 * 2))
    }
  }

  enum Timestamp: String, CaseIterable, Identifiable, Sendable {
    case topRight = "Top right", topLeft = "Top left", bottomRight = "Bottom right", bottomLeft = "Bottom left", hidden = "Off"
    var id: Self { self }
  }

  var start: Date = Calendar.current.startOfDay(for: Date())
  var end: Date = Date()
  var quality: Quality = .original
  var timestamp: Timestamp = .topRight
  var matchRealTime = true
  var speed: Double = 60
  var startMs: Int64 { Int64((start.timeIntervalSince1970 * 1000).rounded()) }
  var endMs: Int64 { Int64((end.timeIntervalSince1970 * 1000).rounded()) }
}
