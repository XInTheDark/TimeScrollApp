import Foundation

/// One screen capture as the segmenter sees it.
struct SessionSample: Equatable {
  let timeMs: Int64
  /// Interned app index; -1 when unknown.
  let app: Int32
  /// Index into the sketch table; -1 when the capture has no text yet.
  let sketch: Int32
}

/// Splits a time-ordered run of captures into sessions with TextTiling (Hearst, 1997) over time:
///
/// 1. An idle gap longer than `hardBreakMs` always ends a session.
/// 2. Captures are pooled into 30 s units. For every gap between units, the units in a short window
///    before it are compared with the window after it: cosine similarity of their words (weighted by
///    rarity, so menu bars and other text that is always on screen count for little), blended with
///    cosine similarity of their app mix (time spent per app). Moving back and forth between the same
///    few apps keeps both windows alike, so it does not split a session; switching to other work does.
/// 3. A gap is a boundary where similarity dips well below the peaks on either side (its depth score).
/// 4. Sessions shorter than the minimum merge across their weaker boundary.
///
/// Cost is linear in the number of sketch entries: windows slide, and their dot products and norms
/// are updated per entry that enters or leaves a window rather than recomputed.
enum SessionSegmenter {
  struct Parameters: Equatable {
    var unitMs: Int64 = 30_000
    var windowUnits = 8
    var hardBreakMs: Int64 = 15 * 60_000
    var textWeight = 0.7
    var depthThreshold = 0.40
    var minSessionMs: Int64 = 3 * 60_000
    /// Gaps with fewer units than this on either side (block edges) are never boundaries.
    var minEdgeUnits = 2
    /// A capture counts toward its app until the next capture, at most this long.
    var dwellCapMs: Int64 = 60_000

    init() {}

    init(sensitivity: SessionSensitivity) {
      depthThreshold = sensitivity.depthThreshold
      minSessionMs = sensitivity.minSessionMs
    }
  }

  struct Result: Equatable {
    /// Sample index ranges, in order, covering every sample.
    let ranges: [Range<Int>]
    /// Deterministic count of inner-loop steps, so tests can check the cost stays linear.
    let work: Int
  }

  static func segment(samples: [SessionSample], sketches: [[UInt32]], parameters: Parameters) -> Result {
    guard !samples.isEmpty else { return Result(ranges: [], work: 0) }
    var work = 0
    let vocabulary = Vocabulary(sketches: sketches, work: &work)
    let units = makeUnits(samples: samples, sketches: vocabulary.denseSketches, parameters: parameters, work: &work)
    let weights = vocabulary.squaredIDFWeights(units: units, work: &work)
    let appCount = Int((samples.map(\.app).max() ?? -1) + 2)

    var ranges: [Range<Int>] = []
    var blockStartUnit = 0
    for unitIndex in 1...units.count where unitIndex == units.count || units[unitIndex].block != units[unitIndex - 1].block {
      let blockUnits = blockStartUnit..<unitIndex
      let boundaries = boundaries(in: blockUnits, units: units, weights: weights, appCount: appCount,
                                  parameters: parameters, work: &work)
      ranges += mergeShortSessions(units: units, blockUnits: blockUnits, boundaries: boundaries,
                                   samples: samples, parameters: parameters)
      blockStartUnit = unitIndex
    }
    return Result(ranges: ranges, work: work)
  }

  // MARK: - Units

  struct Unit {
    let block: Int
    let samples: Range<Int>
    /// Distinct dense word ids seen in the unit.
    let words: [Int32]
    /// (app slot, dwell ms); app slot 0 is "unknown".
    let apps: [(slot: Int, ms: Double)]
  }

  private static func makeUnits(samples: [SessionSample], sketches: [[Int32]], parameters: Parameters, work: inout Int) -> [Unit] {
    var units: [Unit] = []
    var block = 0
    var blockStartMs = samples[0].timeMs
    var unitStart = 0
    var unitBucket: Int64 = 0

    func dwell(at index: Int) -> Double {
      let next = index + 1 < samples.count ? samples[index + 1].timeMs - samples[index].timeMs : 0
      let capped = next > parameters.hardBreakMs || next <= 0 ? min(5_000, parameters.dwellCapMs) : min(next, parameters.dwellCapMs)
      return Double(max(1, capped))
    }

    func closeUnit(end: Int) {
      var sketchIds: [Int32] = []
      var apps: [(slot: Int, ms: Double)] = []
      for index in unitStart..<end {
        let sample = samples[index]
        if sample.sketch >= 0, !sketchIds.contains(sample.sketch) { sketchIds.append(sample.sketch) }
        let slot = Int(sample.app) + 1
        if let at = apps.firstIndex(where: { $0.slot == slot }) {
          apps[at].ms += dwell(at: index)
        } else {
          apps.append((slot, dwell(at: index)))
        }
        work += 1
      }
      var words: [Int32] = []
      for id in sketchIds { words += sketches[Int(id)] }
      work += words.count
      if sketchIds.count > 1 {
        words.sort()
        var unique = 0
        for word in words where unique == 0 || words[unique - 1] != word {
          words[unique] = word
          unique += 1
        }
        words.removeSubrange(unique...)
      }
      units.append(Unit(block: block, samples: unitStart..<end, words: words, apps: apps))
    }

    for index in 1..<samples.count + 1 {
      if index == samples.count {
        closeUnit(end: index)
        break
      }
      let gap = samples[index].timeMs - samples[index - 1].timeMs
      if gap > parameters.hardBreakMs {
        closeUnit(end: index)
        block += 1
        blockStartMs = samples[index].timeMs
        unitStart = index
        unitBucket = 0
        continue
      }
      let bucket = (samples[index].timeMs - blockStartMs) / max(1, parameters.unitMs)
      if bucket != unitBucket {
        closeUnit(end: index)
        unitStart = index
        unitBucket = bucket
      }
    }
    return units
  }

  // MARK: - Boundaries

  /// Unit indices (within `blockUnits`) that start a new session, with their depth scores.
  private static func boundaries(in blockUnits: Range<Int>, units: [Unit], weights: [Double], appCount: Int,
                                 parameters: Parameters, work: inout Int) -> [(unit: Int, depth: Double)] {
    let edge = max(1, parameters.minEdgeUnits)
    guard blockUnits.count >= 2 * edge else { return [] }
    let window = max(edge, parameters.windowUnits)

    var text = SlidingPair(size: weights.count)
    var apps = SlidingPair(size: appCount)
    func add(_ unit: Int, toLeft: Bool, _ delta: Double) {
      for word in units[unit].words { text.update(Int(word), weight: weights[Int(word)], left: toLeft, delta: delta) }
      for app in units[unit].apps { apps.update(app.slot, weight: 1, left: toLeft, delta: delta * app.ms) }
      work += units[unit].words.count + units[unit].apps.count
    }

    let first = blockUnits.lowerBound
    let end = blockUnits.upperBound
    // Window state for the gap before unit `first + 1`.
    add(first, toLeft: true, 1)
    for unit in (first + 1)..<min(end, first + 1 + window) { add(unit, toLeft: false, 1) }

    var gaps: [Int] = []
    var similarity: [Double] = []
    for gap in (first + 1)..<end {
      if gap > first + 1 {
        add(gap - 1, toLeft: true, 1)
        if gap - 1 - window >= first { add(gap - 1 - window, toLeft: true, -1) }
        add(gap - 1, toLeft: false, -1)
        if gap - 1 + window < end { add(gap - 1 + window, toLeft: false, 1) }
      }
      guard gap - first >= edge, end - gap >= edge else { continue }
      let appSimilarity = apps.cosine ?? 1
      let score = text.cosine.map { parameters.textWeight * $0 + (1 - parameters.textWeight) * appSimilarity } ?? appSimilarity
      gaps.append(gap)
      similarity.append(score)
    }
    guard !gaps.isEmpty else { return [] }

    let smoothed = similarity.indices.map { index -> Double in
      let range = max(0, index - 1)...min(similarity.count - 1, index + 1)
      return similarity[range].reduce(0, +) / Double(range.count)
    }
    var leftPeak = smoothed
    for index in 1..<max(1, smoothed.count) where smoothed[index - 1] >= smoothed[index] {
      leftPeak[index] = leftPeak[index - 1]
    }
    var rightPeak = smoothed
    for index in stride(from: smoothed.count - 2, through: 0, by: -1) where smoothed[index + 1] >= smoothed[index] {
      rightPeak[index] = rightPeak[index + 1]
    }

    var candidates: [(unit: Int, depth: Double)] = []
    for index in smoothed.indices {
      let depth: Double = leftPeak[index] + rightPeak[index] - 2 * smoothed[index]
      if depth >= parameters.depthThreshold { candidates.append((gaps[index], depth)) }
    }
    candidates.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.unit < $1.unit }
    let suppression = max(1, window / 2)
    var accepted: [(unit: Int, depth: Double)] = []
    for candidate in candidates where !accepted.contains(where: { abs($0.unit - candidate.unit) <= suppression }) {
      accepted.append(candidate)
    }
    return accepted.sorted { $0.unit < $1.unit }
  }

  /// Turns boundaries into sample ranges, merging sessions shorter than the minimum across their
  /// weaker boundary until none is left (a block that is short as a whole stays one session).
  private static func mergeShortSessions(units: [Unit], blockUnits: Range<Int>, boundaries: [(unit: Int, depth: Double)],
                                         samples: [SessionSample], parameters: Parameters) -> [Range<Int>] {
    var starts = [blockUnits.lowerBound] + boundaries.map(\.unit)
    var depths = [Double.infinity] + boundaries.map(\.depth)

    func sampleRange(_ index: Int) -> Range<Int> {
      let endUnit = index + 1 < starts.count ? starts[index + 1] : blockUnits.upperBound
      return units[starts[index]].samples.lowerBound..<units[endUnit - 1].samples.upperBound
    }
    func duration(_ index: Int) -> Int64 {
      let range = sampleRange(index)
      return samples[range.upperBound - 1].timeMs - samples[range.lowerBound].timeMs
    }

    while starts.count > 1 {
      guard let shortest = starts.indices.filter({ duration($0) < parameters.minSessionMs }).min(by: { duration($0) < duration($1) }) else { break }
      // Remove the weaker of the boundaries around it: before it (its own) or after it (the next session's).
      let hasPrevious = shortest > 0
      let hasNext = shortest + 1 < starts.count
      let removeOwn = hasPrevious && (!hasNext || depths[shortest] <= depths[shortest + 1])
      let removed = removeOwn ? shortest : shortest + 1
      starts.remove(at: removed)
      depths.remove(at: removed)
    }
    return starts.indices.map(sampleRange)
  }
}

// MARK: - Vectors

/// Dense word ids and rarity weights for one segmentation run.
private struct Vocabulary {
  let denseSketches: [[Int32]]
  let size: Int

  init(sketches: [[UInt32]], work: inout Int) {
    var ids: [UInt32: Int32] = [:]
    ids.reserveCapacity(sketches.count * 4)
    var dense: [[Int32]] = []
    dense.reserveCapacity(sketches.count)
    for sketch in sketches {
      dense.append(sketch.map { hash in
        if let id = ids[hash] { return id }
        let id = Int32(ids.count)
        ids[hash] = id
        return id
      })
      work += sketch.count
    }
    denseSketches = dense
    size = ids.count
  }

  /// Squared inverse document frequency of each word, with units as documents. Words on screen in
  /// nearly every unit (menu bars, docks, clocks) weigh far less than words of one task.
  ///
  /// Half again as many units are assumed to exist that hold none of the words. Without that prior,
  /// a day spent on one task would give that task's own words zero weight, and small differences
  /// (which page of the document) would split it.
  func squaredIDFWeights(units: [SessionSegmenter.Unit], work: inout Int) -> [Double] {
    var documentFrequency = [Int32](repeating: 0, count: size)
    for unit in units {
      for word in unit.words { documentFrequency[Int(word)] += 1 }
      work += unit.words.count
    }
    let documents = Double(units.count) * 1.5 + 1
    return documentFrequency.map { frequency in
      let idf = log(documents / Double(frequency + 1))
      return max(0, idf) * max(0, idf)
    }
  }
}

/// Weighted counts in the windows before and after a gap, with their dot product and squared norms
/// kept up to date per change.
private struct SlidingPair {
  private var left: [Double]
  private var right: [Double]
  private var dot = 0.0
  private var leftNorm = 0.0
  private var rightNorm = 0.0

  init(size: Int) {
    left = [Double](repeating: 0, count: max(1, size))
    right = [Double](repeating: 0, count: max(1, size))
  }

  mutating func update(_ index: Int, weight: Double, left isLeft: Bool, delta: Double) {
    if isLeft {
      let old = left[index]
      let new = old + delta
      left[index] = new
      leftNorm += weight * (new * new - old * old)
      dot += weight * delta * right[index]
    } else {
      let old = right[index]
      let new = old + delta
      right[index] = new
      rightNorm += weight * (new * new - old * old)
      dot += weight * delta * left[index]
    }
  }

  /// Nil when either window has nothing weighted in it.
  var cosine: Double? {
    guard leftNorm > 1e-9, rightNorm > 1e-9 else { return nil }
    return min(1, max(0, dot / (leftNorm * rightNorm).squareRoot()))
  }
}
