import Accelerate
import Foundation

/// Picks the screens that best stand for a session from their stored embeddings: first the screen
/// closest to the session's average, then screens that stay close to it but differ from those
/// already chosen. Near-identical screens are skipped, so a session of one screen yields one.
enum EmbeddingRepresentativeSelector {
  struct Candidate: Equatable {
    let textId: Int64
    let vector: [Float]
  }

  /// How much closeness to the average counts against difference from what's already chosen.
  static let relevanceWeight: Float = 0.7
  static let nearDuplicateSimilarity: Float = 0.98
  /// With fewer of the session's screens embedded than this, the vectors don't speak for it.
  static let minimumCoverage = 0.5

  /// Nil when the session doesn't have enough embeddings, so the caller keeps its keyword choice.
  static func representatives(from found: SessionEmbeddingCandidates,
                              count: Int = SessionSummarizer.maxRepresentatives) -> [Int64]? {
    guard found.embeddedTextCount > 0,
          Double(found.embeddedTextCount) >= Double(found.screenTextCount) * minimumCoverage else { return nil }
    let chosen = select(found.candidates, count: count)
    return chosen.isEmpty ? nil : chosen
  }

  static func select(_ candidates: [Candidate], count: Int) -> [Int64] {
    guard count > 0 else { return [] }
    let usable = candidates.compactMap { candidate -> (textId: Int64, vector: [Float])? in
      normalized(candidate.vector).map { (candidate.textId, $0) }
    }.sorted { $0.textId < $1.textId }
    guard let dimension = usable.first?.vector.count else { return [] }
    let vectors = usable.filter { $0.vector.count == dimension }

    var sum = [Float](repeating: 0, count: dimension)
    for item in vectors { vDSP_vadd(sum, 1, item.vector, 1, &sum, 1, vDSP_Length(dimension)) }
    let centroid = normalized(sum)
    let relevance = vectors.map { item in centroid.map { dot($0, item.vector) } ?? 0 }

    // Closest so far to anything chosen, updated as each pick is made.
    var closestChosen = [Float](repeating: -1, count: vectors.count)
    var chosen: [Int] = []
    while chosen.count < count {
      var best: (index: Int, score: Float)?
      for index in vectors.indices where !chosen.contains(index) && closestChosen[index] < nearDuplicateSimilarity {
        let score = chosen.isEmpty ? relevance[index] : relevanceWeight * relevance[index] - (1 - relevanceWeight) * closestChosen[index]
        if score > (best?.score ?? -.infinity) { best = (index, score) }
      }
      guard let best else { break }
      chosen.append(best.index)
      for index in vectors.indices {
        closestChosen[index] = max(closestChosen[index], dot(vectors[index].vector, vectors[best.index].vector))
      }
    }
    return chosen.map { vectors[$0].textId }
  }

  private static func dot(_ left: [Float], _ right: [Float]) -> Float {
    var result: Float = 0
    vDSP_dotpr(left, 1, right, 1, &result, vDSP_Length(left.count))
    return result
  }

  private static func normalized(_ vector: [Float]) -> [Float]? {
    guard !vector.isEmpty else { return nil }
    let length = dot(vector, vector).squareRoot()
    guard length > 0, length.isFinite else { return nil }
    return vDSP.divide(vector, length)
  }
}
