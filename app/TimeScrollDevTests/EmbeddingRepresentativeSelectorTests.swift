import Foundation
import Testing
@testable import TimeScroll

struct EmbeddingRepresentativeSelectorTests {
  private typealias Selector = EmbeddingRepresentativeSelector

  private func candidate(_ id: Int64, _ vector: [Float]) -> Selector.Candidate { .init(textId: id, vector: vector) }

  @Test func noCandidatesGiveNothing() {
    #expect(Selector.select([], count: 3).isEmpty)
    #expect(Selector.select([candidate(1, [1, 0])], count: 0).isEmpty)
  }

  @Test func oneCandidateIsChosen() {
    #expect(Selector.select([candidate(7, [1, 0])], count: 3) == [7])
  }

  @Test func theFirstPickIsClosestToTheAverage() {
    let chosen = Selector.select([candidate(1, [1, 0]), candidate(2, [1, 1]), candidate(3, [0, 1])], count: 1)
    #expect(chosen == [2])
  }

  @Test func laterPicksCoverDifferentActivity() {
    // Mostly one activity, with a second distinct one.
    let chosen = Selector.select([candidate(1, [1, 0, 0]), candidate(2, [0.99, 0.14, 0]), candidate(3, [0.97, 0.24, 0]),
                                  candidate(4, [0.1, 0, 1])], count: 2)
    #expect(chosen.count == 2)
    #expect(chosen.contains(4))
  }

  @Test func nearIdenticalScreensAreNotRepeated() {
    let chosen = Selector.select([candidate(1, [1, 0]), candidate(2, [1, 0.001]), candidate(3, [1, 0.002])], count: 3)
    #expect(chosen.count == 1)
  }

  @Test func vectorLengthDoesNotMatter() {
    let chosen = Selector.select([candidate(1, [100, 0]), candidate(2, [1, 1]), candidate(3, [0, 0.01])], count: 1)
    #expect(chosen == [2])
  }

  @Test func unusableVectorsAreIgnored() {
    let nanVector: [Float] = [Float.nan, 1]
    let items = [candidate(1, []), candidate(2, [0, 0]), candidate(3, nanVector), candidate(4, [1, 0])]
    let chosen = Selector.select(items, count: 3)
    #expect(chosen == [4])
  }

  @Test func orderOfInputDoesNotChangeTheChoice() {
    let items: [Selector.Candidate] = (1...20).map { (index: Int) -> Selector.Candidate in
      let vector: [Float] = [Float(index), Float(21 - index), Float(index % 3)]
      return candidate(Int64(index), vector)
    }
    let forward = Selector.select(items, count: 3)
    let backward = Selector.select(Array(items.reversed()), count: 3)
    #expect(forward == backward)
  }

  @Test func tooFewEmbeddedScreensFallBack() {
    let few = SessionEmbeddingCandidates(candidates: [candidate(1, [1, 0])], embeddedTextCount: 1, screenTextCount: 3)
    #expect(Selector.representatives(from: few) == nil)
    let half = SessionEmbeddingCandidates(candidates: [candidate(1, [1, 0])], embeddedTextCount: 2, screenTextCount: 4)
    #expect(Selector.representatives(from: half) == [1])
    let none = SessionEmbeddingCandidates(candidates: [], embeddedTextCount: 0, screenTextCount: 0)
    #expect(Selector.representatives(from: none) == nil)
  }

  // MARK: - Storage

  @Test func repeatedScreensCountOnce() throws {
    let database = try SummaryTestDatabase()
    database.addScreen(at: 10, textId: 1, vector: [1, 0])
    database.addScreen(at: 20, textId: 1, vector: [1, 0])
    database.addScreen(at: 30, textId: 2, vector: [0, 1])
    let found = DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 100, db: database.db)
    #expect(found.embeddedTextCount == 2)
    #expect(found.screenTextCount == 2)
    #expect(found.candidates.map(\.textId) == [1, 2])
  }

  @Test func onlyScreensInTheSessionCount() throws {
    let database = try SummaryTestDatabase()
    database.addScreen(at: 9, textId: 1, vector: [1, 0])
    database.addScreen(at: 10, textId: 2, vector: [1, 0])
    database.addScreen(at: 20, textId: 3, vector: [1, 0])
    database.addScreen(at: 21, textId: 4, vector: [1, 0])
    #expect(DB.sessionEmbeddingCandidates(fromMs: 10, throughMs: 20, db: database.db).candidates.map(\.textId) == [2, 3])
  }

  @Test func modelsAreNotMixedAndTheBestCoveredWins() throws {
    let database = try SummaryTestDatabase()
    database.addScreen(at: 10, textId: 1, vector: [1, 0, 0], provider: "old", model: "a")
    database.addScreen(at: 20, textId: 2, vector: [1, 0], provider: "new", model: "b")
    database.addScreen(at: 30, textId: 3, vector: [0, 1], provider: "new", model: "b")
    let found = DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 100, db: database.db)
    #expect(found.candidates.map(\.textId) == [2, 3])
    #expect(found.screenTextCount == 3)
  }

  @Test func vectorsFromAnUnfinishedRebuildAreIgnored() throws {
    let database = try SummaryTestDatabase()
    database.addScreen(at: 10, textId: 1, vector: [1, 0], model: "m\(SnapshotEmbeddingWriter.stagingModelSuffix)")
    let found = DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 100, db: database.db)
    #expect(found.embeddedTextCount == 0)
    #expect(found.screenTextCount == 1)
  }

  @Test func aTruncatedVectorIsSkipped() throws {
    let database = try SummaryTestDatabase()
    database.addScreen(at: 10, textId: 1, vector: [1, 0])
    database.exec("UPDATE ts_embedding SET dim = 8;")
    #expect(DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 100, db: database.db).candidates.isEmpty)
  }

  @Test func aLongSessionStaysBoundedAndSpreadOut() throws {
    let database = try SummaryTestDatabase()
    database.exec("BEGIN;")
    for index in 0..<1_000 { database.addScreen(at: Int64(index), textId: Int64(index), vector: [1, 0]) }
    database.exec("COMMIT;")
    let found = DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 10_000, limit: 100, db: database.db)
    #expect(found.embeddedTextCount == 1_000)
    #expect(found.candidates.count <= 100)
    #expect(found.candidates.count >= 50)
    #expect(found.candidates.first?.textId == 0)
    #expect((found.candidates.last?.textId ?? 0) >= 900)
  }

  @Test func aLockedDatabaseOrMissingTableGivesNothing() throws {
    let database = try SummaryTestDatabase()
    database.exec("DROP TABLE ts_embedding;")
    #expect(DB.sessionEmbeddingCandidates(fromMs: 0, throughMs: 100, db: database.db).screenTextCount == 0)
  }
}
