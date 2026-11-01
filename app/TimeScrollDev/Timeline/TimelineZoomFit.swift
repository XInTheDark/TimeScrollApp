import CoreGraphics

/// The zoom (ms per point) at which a time span fills a target width on the timeline axis.
enum TimelineZoomFit {
  /// `timesAsc` are the capture times within the span. On the compressed axis each gap between
  /// captures is drawn at most `compressedGapWidth` wide, so width does not scale linearly with zoom;
  /// the zoom is found by bisection (width shrinks as ms per point grows).
  static func msPerPoint(timesAsc: [Int64], targetWidth: CGFloat, isCompressed: Bool, compressedGapWidth: CGFloat,
                         range: ClosedRange<Double>) -> Double {
    guard let first = timesAsc.first, let last = timesAsc.last, last > first, targetWidth > 0 else { return range.lowerBound }
    guard isCompressed else {
      return min(max(Double(last - first) / Double(targetWidth), range.lowerBound), range.upperBound)
    }

    func width(_ msPerPoint: Double) -> CGFloat {
      var total: CGFloat = 0
      for index in 1..<timesAsc.count {
        total += min(CGFloat(Double(timesAsc[index] - timesAsc[index - 1]) / msPerPoint), compressedGapWidth)
      }
      return total
    }

    if width(range.lowerBound) <= targetWidth { return range.lowerBound }
    if width(range.upperBound) >= targetWidth { return range.upperBound }
    var low = log(range.lowerBound)
    var high = log(range.upperBound)
    for _ in 0..<40 {
      let mid = (low + high) / 2
      if width(exp(mid)) > targetWidth { low = mid } else { high = mid }
    }
    return exp(high)
  }
}
