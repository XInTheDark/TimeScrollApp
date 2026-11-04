import Foundation

/// A finished summary of one calendar day or week.
struct StoredRangeSummary: Equatable {
  let startMs: Int64
  let endMs: Int64
  let model: String
  let promptVersion: Int
  let text: String
  let createdAtMs: Int64
}
