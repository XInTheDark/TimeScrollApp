import Foundation
import Testing
@testable import TimeScroll

struct SessionSegmenterTests {
  private let xcode: Int32 = 0
  private let safari: Int32 = 1
  private let terminal: Int32 = 2
  private let mail: Int32 = 3
  private let slack: Int32 = 4

  private func assertCoversAll(_ result: SessionSegmenter.Result, count: Int) {
    #expect(result.ranges.first?.lowerBound == 0)
    #expect(result.ranges.last?.upperBound == count)
    for (a, b) in zip(result.ranges, result.ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    #expect(result.ranges.allSatisfy { !$0.isEmpty })
  }

  @Test func emptyInputHasNoSessions() {
    let result = SessionSegmenter.segment(samples: [], sketches: [], parameters: .init())
    #expect(result.ranges.isEmpty)
  }

  @Test func singleCaptureIsOneSession() {
    let samples = [SessionSample(timeMs: 1_000, app: 0, sketch: -1)]
    let result = SessionSegmenter.segment(samples: samples, sketches: [], parameters: .init())
    #expect(result.ranges == [0..<1])
  }

  @Test func switchingAppsOnOneTaskStaysOneSession() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [xcode, safari, terminal], minutes: 45)
    let result = fixture.segment()
    #expect(result.ranges.count == 1)
    assertCoversAll(result, count: fixture.captures.count)
  }

  @Test func newTopicInSameAppStartsSession() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("budget"), apps: [safari], minutes: 20)
    let switchIndex = fixture.captures.count
    fixture.work(topic: SessionFixture.topic("holiday"), apps: [safari], minutes: 20)
    let result = fixture.segment()
    #expect(result.ranges.count == 2)
    // The boundary lands within a minute of the switch.
    let boundary = result.ranges.first.map(\.upperBound) ?? 0
    #expect(abs(boundary - switchIndex) <= 12)
    assertCoversAll(result, count: fixture.captures.count)
  }

  @Test func differentWorkInOtherAppsStartsSession() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [xcode, safari, terminal], minutes: 25)
    fixture.work(topic: SessionFixture.topic("inbox"), apps: [mail, slack], minutes: 25)
    #expect(fixture.segment().ranges.count == 2)
  }

  @Test func threeTasksGiveThreeSessions() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [xcode, terminal], minutes: 15)
    fixture.work(topic: SessionFixture.topic("inbox"), apps: [mail, slack], minutes: 15)
    fixture.work(topic: SessionFixture.topic("budget"), apps: [safari], minutes: 15)
    #expect(fixture.segment().ranges.count == 3)
  }

  @Test func idleGapAlwaysSplits() {
    var fixture = SessionFixture()
    let topic = SessionFixture.topic("render")
    fixture.work(topic: topic, apps: [xcode], minutes: 10)
    let resume = fixture.captures.last!.timeMs + 20 * 60_000
    fixture.work(topic: topic, apps: [xcode], minutes: 10, startMs: resume)
    #expect(fixture.segment(.lenient).ranges.count == 2)
  }

  @Test func shortGapDoesNotSplit() {
    var fixture = SessionFixture()
    let topic = SessionFixture.topic("render")
    fixture.work(topic: topic, apps: [xcode], minutes: 10)
    fixture.work(topic: topic, apps: [xcode], minutes: 10, startMs: fixture.captures.last!.timeMs + 8 * 60_000)
    #expect(fixture.segment().ranges.count == 1)
  }

  @Test func returningToOtherPartOfTaskStaysOneSessionWhenLenient() {
    var fixture = SessionFixture()
    let topic = SessionFixture.topic("render")
    fixture.work(topic: topic, apps: [xcode], minutes: 10)
    fixture.work(topic: topic, apps: [xcode], minutes: 10, startMs: fixture.captures.last!.timeMs + 8 * 60_000, resume: false)
    #expect(fixture.segment(.lenient).ranges.count == 1)
  }

  @Test func briefDetourIsAbsorbed() {
    var fixture = SessionFixture()
    let topic = SessionFixture.topic("render")
    fixture.work(topic: topic, apps: [xcode, terminal], minutes: 15)
    fixture.work(topic: SessionFixture.topic("chat"), apps: [slack], minutes: 1)
    fixture.work(topic: topic, apps: [xcode, terminal], minutes: 15)
    #expect(fixture.segment().ranges.count == 1)
  }

  @Test func shortIsolatedBurstStaysItsOwnSession() {
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("chat"), apps: [slack], minutes: 1)
    fixture.work(topic: SessionFixture.topic("render"), apps: [xcode], minutes: 20,
                 startMs: fixture.captures.last!.timeMs + 30 * 60_000)
    let result = fixture.segment()
    #expect(result.ranges.count == 2)
    assertCoversAll(result, count: fixture.captures.count)
  }

  @Test func withoutTextAppMixDecides() {
    var alternating = SessionFixture()
    alternating.work(topic: [], apps: [xcode, safari], minutes: 30)
    #expect(alternating.segment().ranges.count == 1)

    var switching = SessionFixture()
    switching.work(topic: [], apps: [xcode], minutes: 15)
    switching.work(topic: [], apps: [mail], minutes: 15)
    #expect(switching.segment().ranges.count == 2)
  }

  @Test func stricterSettingsNeverFindFewerSessions() {
    var fixture = SessionFixture()
    let topics = ["render", "inbox", "budget", "notes", "review"].map { SessionFixture.topic($0) }
    for (index, minutes) in [12.0, 3, 8, 2.5, 20, 6, 4, 15].enumerated() {
      fixture.work(topic: topics[index % topics.count], apps: [Int32(index % 3), Int32(index % 5)], minutes: minutes)
    }
    let lenient = fixture.segment(.lenient).ranges.count
    let balanced = fixture.segment(.balanced).ranges.count
    let strict = fixture.segment(.strict).ranges.count
    #expect(lenient <= balanced)
    #expect(balanced <= strict)
    #expect(strict > 1)
  }

  @Test func sparseIdleCapturesStayOneSession() {
    // An idle screen is captured rarely (minutes apart) but never past the idle break.
    var fixture = SessionFixture()
    fixture.work(topic: SessionFixture.topic("render"), apps: [xcode], minutes: 60, intervalMs: 4 * 60_000)
    #expect(fixture.segment().ranges.count == 1)
  }

  @Test func capturesSharingATimestampAreHandled() {
    let samples = (0..<200).map { SessionSample(timeMs: 1_000 + Int64($0 / 2) * 5_000, app: Int32($0 % 2), sketch: -1) }
    let result = SessionSegmenter.segment(samples: samples, sketches: [], parameters: .init())
    assertCoversAll(result, count: samples.count)
  }

  @Test func costGrowsLinearly() {
    func work(hours: Double) -> Int {
      var fixture = SessionFixture()
      let topics = ["render", "inbox", "budget", "notes"].map { SessionFixture.topic($0) }
      var index = 0
      var remaining = hours * 60
      while remaining > 0 {
        fixture.work(topic: topics[index % topics.count], apps: [Int32(index % 3), Int32(index % 4 + 1)], minutes: 20)
        remaining -= 20
        index += 1
      }
      return fixture.segment().work
    }
    let small = work(hours: 4)
    let large = work(hours: 16)
    #expect(large <= small * 4 + small / 5)
    #expect(large >= small * 3)
  }
}
