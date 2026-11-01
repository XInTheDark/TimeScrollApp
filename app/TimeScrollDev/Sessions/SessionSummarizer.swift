import Foundation

/// Turns segmented sample ranges into sessions: time span, app shares, and the word hashes that
/// set each session apart from the rest of the day (resolved to words later by `SessionLabeler`).
enum SessionSummarizer {
  static let maxApps = 4
  static let maxKeywordHashes = 12
  static let maxRepresentatives = 3

  struct App: Equatable {
    let bundleId: String?
    let name: String?
  }

  struct Draft {
    /// Session with no keywords yet.
    let session: ActivitySession
    /// Most distinctive first.
    let keywordHashes: [UInt32]
    /// Up to three sketch indices whose texts together contain most keyword hashes.
    let representativeSketches: [Int32]
  }

  static func summarize(ranges: [Range<Int>],
                        samples: [SessionSample],
                        snapshotIds: [Int64],
                        apps: [App],
                        sketches: [[UInt32]],
                        parameters: SessionSegmenter.Parameters) -> [Draft] {
    let words = DenseWords(sketches)
    let idf = sketchIDF(words)
    let chrome = appChrome(samples: samples, words: words)
    var counts = [Int32](repeating: 0, count: words.hashes.count)
    return ranges.map { range in
      let session = ActivitySession(id: snapshotIds[range.lowerBound],
                                    startMs: samples[range.lowerBound].timeMs,
                                    endMs: samples[range.upperBound - 1].timeMs,
                                    snapshotCount: range.count,
                                    apps: appShares(range: range, samples: samples, apps: apps, parameters: parameters),
                                    keywords: [])
      let sketchIds = Array(Set(samples[range].map(\.sketch).filter { $0 >= 0 })).sorted()
      let keywords = keywordHashes(sketchIds: sketchIds, words: words, idf: idf, excluding: chrome, counts: &counts)
      return Draft(session: session,
                   keywordHashes: keywords,
                   representativeSketches: representatives(sketchIds: sketchIds, keywords: keywords, sketches: sketches))
    }
  }

  private static func appShares(range: Range<Int>, samples: [SessionSample], apps: [App],
                                parameters: SessionSegmenter.Parameters) -> [ActivitySession.AppShare] {
    var totals: [Int32: Int64] = [:]
    for index in range {
      let next = index + 1 < samples.count ? samples[index + 1].timeMs - samples[index].timeMs : 0
      let dwell = next > parameters.hardBreakMs || next <= 0 ? min(5_000, parameters.dwellCapMs) : min(next, parameters.dwellCapMs)
      totals[samples[index].app, default: 0] += max(1, dwell)
    }
    return totals
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(maxApps)
      .map { entry in
        let app = entry.key >= 0 && Int(entry.key) < apps.count ? apps[Int(entry.key)] : App(bundleId: nil, name: nil)
        return ActivitySession.AppShare(bundleId: app.bundleId, name: app.name, ms: entry.value)
      }
  }

  /// Rarity of each word (by dense id) across all distinct texts of the input.
  private static func sketchIDF(_ words: DenseWords) -> [Double] {
    var frequency = [Int32](repeating: 0, count: words.hashes.count)
    for sketch in words.sketches { for id in sketch { frequency[Int(id)] += 1 } }
    let documents = Double(words.sketches.count + 1)
    return frequency.map { max(0, log(documents / Double($0 + 1))) }
  }

  /// Words (by dense id) on nearly every screen of some app: its own interface (toolbars, sidebars,
  /// buttons). The title already names the app, so these never become keywords.
  private static func appChrome(samples: [SessionSample], words: DenseWords) -> [Bool] {
    var sketchesByApp: [Int32: Set<Int32>] = [:]
    for sample in samples where sample.sketch >= 0 { sketchesByApp[sample.app, default: []].insert(sample.sketch) }
    var chrome = [Bool](repeating: false, count: words.hashes.count)
    var counts = [Int32](repeating: 0, count: words.hashes.count)
    var touched: [Int32] = []
    for ids in sketchesByApp.values where ids.count >= 4 {
      touched.removeAll(keepingCapacity: true)
      for id in ids {
        for word in words.sketches[Int(id)] {
          if counts[Int(word)] == 0 { touched.append(word) }
          counts[Int(word)] += 1
        }
      }
      // A full sketch keeps only its smallest hashes, so a word is counted against the screens whose
      // sketch could have held it: those not full, or full with a largest hash at or above the word's.
      var openCount = 0
      var fullLimits: [UInt32] = []
      for id in ids {
        let sketch = words.sketches[Int(id)]
        if sketch.count < SessionTextSketch.capacity { openCount += 1 } else if let last = sketch.last { fullLimits.append(words.hashes[Int(last)]) }
      }
      fullLimits.sort()
      for word in touched {
        let count = Int(counts[Int(word)])
        counts[Int(word)] = 0
        let eligible = openCount + fullLimits.count - firstIndex(atOrAbove: words.hashes[Int(word)], in: fullLimits)
        if eligible >= 4, count * 5 >= eligible * 4 { chrome[Int(word)] = true }
      }
    }
    return chrome
  }

  private static func firstIndex(atOrAbove value: UInt32, in sorted: [UInt32]) -> Int {
    var low = 0
    var high = sorted.count
    while low < high {
      let mid = (low + high) / 2
      if sorted[mid] < value { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// `counts` is all zeros on entry and left that way; it is passed in so sessions share one buffer.
  private static func keywordHashes(sketchIds: [Int32], words: DenseWords, idf: [Double], excluding chrome: [Bool],
                                    counts: inout [Int32]) -> [UInt32] {
    guard !sketchIds.isEmpty else { return [] }
    var touched: [Int32] = []
    for id in sketchIds {
      for word in words.sketches[Int(id)] {
        if counts[Int(word)] == 0 { touched.append(word) }
        counts[Int(word)] += 1
      }
    }
    // In longer sessions a word must recur, so one stray screen does not name the session.
    let minimumCount = sketchIds.count >= 3 ? 2 : 1
    var scored: [(hash: UInt32, score: Double)] = []
    for word in touched {
      let index = Int(word)
      let count = Int(counts[index])
      counts[index] = 0
      guard count >= minimumCount, !chrome[index], idf[index] > 0 else { continue }
      scored.append((words.hashes[index], Double(count) * idf[index]))
    }
    return scored
      .sorted { $0.score != $1.score ? $0.score > $1.score : $0.hash < $1.hash }
      .prefix(maxKeywordHashes)
      .map(\.hash)
  }

  /// Greedy cover: the texts that contain the most keyword hashes not yet covered.
  private static func representatives(sketchIds: [Int32], keywords: [UInt32], sketches: [[UInt32]]) -> [Int32] {
    var remaining = Set(keywords)
    var chosen: [Int32] = []
    while !remaining.isEmpty, chosen.count < maxRepresentatives {
      var best: (id: Int32, hits: Int)?
      for id in sketchIds where !chosen.contains(id) {
        let hits = sketches[Int(id)].reduce(0) { $0 + (remaining.contains($1) ? 1 : 0) }
        if hits > (best?.hits ?? 0) { best = (id, hits) }
      }
      guard let best else { break }
      chosen.append(best.id)
      remaining.subtract(sketches[Int(best.id)])
    }
    return chosen
  }
}

/// Sketch hashes renumbered densely, so per-word counts are array slots rather than dictionary entries.
private struct DenseWords {
  /// Each sketch as dense word ids, in the sketch's (ascending hash) order.
  let sketches: [[Int32]]
  /// The hash of each dense id.
  let hashes: [UInt32]

  init(_ sketches: [[UInt32]]) {
    var ids: [UInt32: Int32] = [:]
    ids.reserveCapacity(sketches.count * 4)
    var hashes: [UInt32] = []
    self.sketches = sketches.map { sketch in
      sketch.map { hash in
        if let id = ids[hash] { return id }
        let id = Int32(hashes.count)
        ids[hash] = id
        hashes.append(hash)
        return id
      }
    }
    self.hashes = hashes
  }
}
