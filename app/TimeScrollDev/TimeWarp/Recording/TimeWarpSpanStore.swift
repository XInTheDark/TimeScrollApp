import Foundation

/// The writes the recorder needs; `DB` provides them. Tests can substitute their own.
protocol TimeWarpSpanStore: AnyObject {
  func timeWarpOpenSpan(_ start: TimeWarpSpanStart) -> Int64?
  func timeWarpCloseSpans(ids: [Int64], endMs: Int64)
  @discardableResult func timeWarpRecordEvent(_ item: TimeWarpItem, appBundleId: String?, atMs: Int64) -> Bool
  func timeWarpCloseAbandonedSpans()
}

extension DB: TimeWarpSpanStore {}
