import Foundation

/// Collects one model's distinct screens in time order, in bounded memory. When it fills up it drops
/// every other screen and keeps half as many from then on, so what remains stays spread evenly.
struct SessionEmbeddingGroup {
  private(set) var candidates: [EmbeddingRepresentativeSelector.Candidate] = []
  private let limit: Int
  private var seen = Set<Int64>()
  private var stride = 1

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  var seenCount: Int { seen.count }

  mutating func add(textId: Int64, vector: () -> [Float]?) {
    guard seen.insert(textId).inserted, (seen.count - 1) % stride == 0, let vector = vector() else { return }
    candidates.append(.init(textId: textId, vector: vector))
    guard candidates.count > limit else { return }
    candidates = candidates.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    stride *= 2
  }
}
