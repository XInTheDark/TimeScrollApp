import Foundation

struct TimelapseFrame: Sendable, Equatable {
  let id: Int64
  let timeMs: Int64
  let path: String
  let format: String
  var thumbPath: String? = nil
}
