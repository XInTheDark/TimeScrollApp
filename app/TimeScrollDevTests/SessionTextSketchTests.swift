import Foundation
import Testing
@testable import TimeScroll

struct SessionTextSketchTests {
  private func tokens(_ text: String) -> [String] {
    var words: [String] = []
    SessionTextSketch.forEachToken(in: text) { _, range in words.append(String(text[range])) }
    return words
  }

  @Test func emptyAndWordlessTextGiveEmptySketch() {
    #expect(SessionTextSketch.make(from: "").isEmpty)
    #expect(SessionTextSketch.make(from: "  \n\t ... -- 12 34 ").isEmpty)
  }

  @Test func wordsAreSplitOnPunctuationAndShortOrNumericWordsDropped() {
    #expect(tokens("Hello, world! a an the_end 10:45 2026 v2 abc123 build42x") == ["Hello", "world", "the", "end", "build42x"])
  }

  @Test func caseDoesNotChangeTheHash() {
    #expect(SessionTextSketch.make(from: "TimelineBarView") == SessionTextSketch.make(from: "timelinebarview"))
    #expect(SessionTextSketch.make(from: "ÉCOLE") == SessionTextSketch.make(from: "école"))
  }

  @Test func sketchIsSortedDistinctAndCapped() {
    let text = (0..<500).map { "word\(String(repeating: "x", count: $0 % 30))\($0 % 7 == 0 ? "a" : "b")y\($0)" }.joined(separator: " ")
    let sketch = SessionTextSketch.make(from: text)
    #expect(sketch.count == SessionTextSketch.capacity)
    #expect(sketch == sketch.sorted())
    #expect(Set(sketch).count == sketch.count)
  }

  @Test func repeatedWordsCountOnce() {
    #expect(SessionTextSketch.make(from: "alpha alpha ALPHA beta").count == 2)
  }

  @Test func sharedWordsAreSampledConsistently() {
    // The bottom-k sample of a superset contains every sampled word of the subset that is small enough.
    let base = (0..<200).map { "base\($0)word" }
    let small = SessionTextSketch.make(from: base.prefix(100).joined(separator: " "))
    let large = SessionTextSketch.make(from: base.joined(separator: " "))
    let threshold = large.last!
    #expect(small.filter { $0 <= threshold }.allSatisfy { large.contains($0) })
  }

  @Test func encodeDecodeRoundTrips() {
    let sketch = SessionTextSketch.make(from: "renders timeline sessions quickly across many displays")
    #expect(SessionTextSketch.decode(SessionTextSketch.encode(sketch)) == sketch)
    #expect(SessionTextSketch.decode(Data()) == [])
  }

  @Test func cjkTextYieldsBigrams() {
    #expect(tokens("日本語の文章") == ["日本", "本語", "語の", "の文", "文章"])
    #expect(tokens("Swift日本") == ["Swift", "日本"])
  }

  @Test func overlongRunsAreDropped() {
    #expect(tokens(String(repeating: "a", count: 41) + " fine").count == 1)
  }

  @Test func hugeTextIsSketchedQuickly() {
    let text = (0..<40_000).map { "token\($0 % 5000)abc" }.joined(separator: " ")
    let start = DispatchTime.now().uptimeNanoseconds
    let sketch = SessionTextSketch.make(from: text)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    #expect(sketch.count == SessionTextSketch.capacity)
    // ~400 KB of text; generous bound for a debug build on a shared runner.
    #expect(elapsedMs < 2_000)
  }
}
