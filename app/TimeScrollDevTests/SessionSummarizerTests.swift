import Foundation
import Testing
@testable import TimeScroll

struct SessionSummarizerTests {
  private let apps = [SessionSummarizer.App(bundleId: "com.apple.dt.Xcode", name: "Xcode"),
                      SessionSummarizer.App(bundleId: "com.apple.Safari", name: "Safari"),
                      SessionSummarizer.App(bundleId: "com.apple.mail", name: "Mail")]

  private func summarize(_ fixture: SessionFixture) -> (drafts: [SessionSummarizer.Draft], sketches: [[UInt32]]) {
    let (samples, sketches) = fixture.samples()
    let parameters = SessionSegmenter.Parameters(sensitivity: .balanced)
    let ranges = SessionSegmenter.segment(samples: samples, sketches: sketches, parameters: parameters).ranges
    let ids = samples.indices.map { Int64($0 + 100) }
    return (SessionSummarizer.summarize(ranges: ranges, samples: samples, snapshotIds: ids, apps: apps,
                                        sketches: sketches, parameters: parameters), sketches)
  }

  @Test func sessionSpansAndIdsComeFromItsCaptures() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [0, 1], minutes: 20)
    fixture.work(topic: SessionFixture.topic("inbox"), apps: [2], minutes: 20)
    let drafts = summarize(fixture).drafts
    #expect(drafts.count == 2)
    #expect(drafts[0].session.id == 100)
    #expect(drafts[0].session.startMs == fixture.captures[0].timeMs)
    #expect(drafts[1].session.endMs == fixture.captures.last!.timeMs)
    #expect(drafts.map(\.session.snapshotCount).reduce(0, +) == fixture.captures.count)
  }

  @Test func appSharesAreOrderedByTimeAndNamed() {
    var fixture = SessionFixture()
    // Xcode 2/3 of the time, Safari 1/3.
    fixture.work(topic: SessionFixture.topic("render"), apps: [0, 0, 1], minutes: 30)
    let session = summarize(fixture).drafts[0].session
    #expect(session.apps.map(\.name) == ["Xcode", "Safari"])
    #expect(session.apps[0].ms > session.apps[1].ms)
    #expect(session.title == "Xcode, Safari")
  }

  @Test func minorAppsAreLeftOutOfTheTitle() {
    let session = ActivitySession(id: 1, startMs: 0, endMs: 1, snapshotCount: 3,
                                  apps: [.init(bundleId: "a", name: "A", ms: 900), .init(bundleId: "b", name: "B", ms: 100)],
                                  keywords: ["Alpha"])
    #expect(session.title == "A")
    #expect(session.label == "A — Alpha")
  }

  @Test func keywordsComeFromTheSessionsOwnTopic() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [0], minutes: 20)
    fixture.work(topic: SessionFixture.topic("inbox"), apps: [2], minutes: 20)
    let drafts = summarize(fixture).drafts
    let texts = fixture.captures.map(\.text)
    let first = SessionLabeler.keywords(for: drafts[0].keywordHashes, texts: texts)
    let second = SessionLabeler.keywords(for: drafts[1].keywordHashes, texts: texts)
    #expect(!first.isEmpty)
    #expect(first.allSatisfy { $0.hasPrefix("render") })
    #expect(second.allSatisfy { $0.hasPrefix("inbox") })
  }

  @Test func representativesCoverTheKeywords() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [0], minutes: 20)
    let (drafts, sketches) = summarize(fixture)
    let draft = drafts[0]
    #expect(!draft.representativeSketches.isEmpty)
    #expect(draft.representativeSketches.count <= SessionSummarizer.maxRepresentatives)
    let covered = Set(draft.representativeSketches.flatMap { sketches[Int($0)] })
    #expect(draft.keywordHashes.contains { covered.contains($0) })
  }

  @Test func sessionWithoutTextHasNoKeywords() {
    var fixture = SessionFixture()
    fixture.work(topic: [], apps: [0], minutes: 10)
    let draft = summarize(fixture).drafts[0]
    #expect(draft.keywordHashes.isEmpty)
    #expect(draft.representativeSketches.isEmpty)
  }
}

struct SessionLabelerTests {
  private func hashes(_ words: [String]) -> [UInt32] {
    words.compactMap { word in
      var hash: UInt32?
      SessionTextSketch.forEachToken(in: word) { value, _ in hash = value }
      return hash
    }
  }

  @Test func keepsOnScreenSpellingAndOrder() {
    let words = SessionLabeler.keywords(for: hashes(["screencapturekit", "timelinebarview"]),
                                        texts: ["Open TimelineBarView.swift and ScreenCaptureKit docs"])
    #expect(words == ["ScreenCaptureKit", "TimelineBarView"])
  }

  @Test func skipsStopwordsHexAndDuplicates() {
    let words = SessionLabeler.keywords(for: hashes(["the", "deadbeef0042", "Budget", "budget", "forecast", "quarter", "extra"]),
                                        texts: ["The budget deadbeef0042 forecast for the quarter, extra"])
    #expect(words == ["budget", "forecast", "quarter", "extra"])
  }

  @Test func keywordsAreCapped() {
    let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
    let words = SessionLabeler.keywords(for: hashes(names), texts: [names.joined(separator: " ")])
    #expect(words == Array(names.prefix(SessionLabeler.maxKeywords)))
    #expect(SessionLabeler.maxKeywords == 5)
  }

  @Test func missingWordsAndEmptyInputGiveNothing() {
    #expect(SessionLabeler.keywords(for: hashes(["absent"]), texts: ["nothing here"]).isEmpty)
    #expect(SessionLabeler.keywords(for: [], texts: ["text"]).isEmpty)
    #expect(SessionLabeler.keywords(for: hashes(["text"]), texts: []).isEmpty)
  }
}
