import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct TimelineRangeTests {
  private func calendar(_ zone: String = "UTC") -> Calendar { SummaryTestTime.calendar(zone) }

  private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

  // MARK: - Range

  @Test func invalidRangesAreRejected() {
    #expect(TimelineRange(fromMs: 5, toMs: 5) == nil)
    #expect(TimelineRange(fromMs: 6, toMs: 5) == nil)
  }

  @Test func coveringUsesWholeSecondsAndEitherOrder() {
    let range = TimelineRange.covering(10_500, 7_250)
    #expect(range.fromMs == 7_000)
    #expect(range.toMs == 11_000)
    #expect(TimelineRange.covering(7_250, 10_500) == range)
  }

  @Test func coveringIncludesACaptureExactlyOnTheSecond() {
    let range = TimelineRange.covering(5_000, 8_000)
    #expect(range.fromMs == 5_000)
    #expect(range.toMs == 9_000)
  }

  @Test func coveringOneInstantIsOneSecond() {
    #expect(TimelineRange.covering(5_000, 5_000).durationMs == 1_000)
  }

  @Test func editingAnEdgePastTheOtherKeepsTheRangeValid() {
    let range = TimelineRange(fromMs: 100_000, toMs: 200_000)!
    #expect(range.withFrom(150_000).toMs == 200_000)
    #expect(range.withFrom(300_000) == TimelineRange(fromMs: 300_000, toMs: 360_000))
    #expect(range.withFrom(200_000).durationMs == 60_000)
    #expect(range.withTo(150_000).fromMs == 100_000)
    #expect(range.withTo(50_000) == TimelineRange(fromMs: -10_000, toMs: 50_000))
  }

  // MARK: - Presets

  @Test func todayRunsFromMidnightToNow() {
    let now = SummaryTestTime.ms(2026, 3, 11, 15, 30)
    let range = TimelineRangePreset.today.range(now: date(now), calendar: calendar())
    #expect(range?.fromMs == SummaryTestTime.ms(2026, 3, 11))
    #expect(range?.toMs == now + 1_000)
  }

  @Test func yesterdayIsAWholeDayAcrossDaylightSaving() {
    let now = SummaryTestTime.ms(2026, 3, 30, 12, zone: "Europe/Berlin")
    let range = TimelineRangePreset.yesterday.range(now: date(now), calendar: calendar("Europe/Berlin"))
    #expect(range?.durationMs == Int64(23 * 3_600_000))
    #expect(range?.fromMs == SummaryTestTime.ms(2026, 3, 29, zone: "Europe/Berlin"))
  }

  @Test func weeksFollowTheCalendarsFirstWeekday() {
    let now = SummaryTestTime.ms(2026, 3, 11, 15) // A Wednesday.
    let thisWeek = TimelineRangePreset.thisWeek.range(now: date(now), calendar: calendar())
    #expect(thisWeek?.fromMs == SummaryTestTime.ms(2026, 3, 9))
    #expect(thisWeek?.toMs == now + 1_000)
    let lastWeek = TimelineRangePreset.lastWeek.range(now: date(now), calendar: calendar())
    #expect(lastWeek?.fromMs == SummaryTestTime.ms(2026, 3, 2))
    #expect(lastWeek?.toMs == SummaryTestTime.ms(2026, 3, 9))
  }

  // MARK: - Dragging

  @Test func aSmallMovementStaysAClick() {
    var drag = TimelineRangeDrag(x: 100, timeMs: 50_000, current: nil, lowerX: nil, upperX: nil)
    #expect(drag.update(x: 102, timeMs: 51_000) == nil)
    #expect(!drag.moved)
  }

  @Test func draggingOnEmptyTimelineStartsARange() {
    var drag = TimelineRangeDrag(x: 100, timeMs: 50_000, current: nil, lowerX: nil, upperX: nil)
    #expect(drag.update(x: 150, timeMs: 90_000) == TimelineRange(fromMs: 50_000, toMs: 91_000))
    #expect(drag.moved)
  }

  @Test func draggingBackwardFromTheStartWorks() {
    var drag = TimelineRangeDrag(x: 100, timeMs: 50_000, current: nil, lowerX: nil, upperX: nil)
    #expect(drag.update(x: 50, timeMs: 20_000) == TimelineRange(fromMs: 20_000, toMs: 51_000))
  }

  @Test func onceMovedReturningToTheStartStillUpdates() {
    var drag = TimelineRangeDrag(x: 100, timeMs: 50_000, current: nil, lowerX: nil, upperX: nil)
    _ = drag.update(x: 150, timeMs: 90_000)
    #expect(drag.update(x: 100, timeMs: 50_000) == TimelineRange(fromMs: 50_000, toMs: 51_000))
  }

  @Test func theUpperEdgeMovesAndTheLowerStaysExact() {
    let current = TimelineRange(fromMs: 50_000, toMs: 90_000)!
    var drag = TimelineRangeDrag(x: 204, timeMs: 89_000, current: current, lowerX: 100, upperX: 200)
    #expect(drag.update(x: 300, timeMs: 150_000) == TimelineRange(fromMs: 50_000, toMs: 151_000))
  }

  @Test func theLowerEdgeMovesAndTheUpperStaysExact() {
    let current = TimelineRange(fromMs: 50_000, toMs: 90_000)!
    var drag = TimelineRangeDrag(x: 96, timeMs: 49_000, current: current, lowerX: 100, upperX: 200)
    #expect(drag.update(x: 50, timeMs: 20_000) == TimelineRange(fromMs: 20_000, toMs: 90_000))
  }

  @Test func anEdgeCanBeDraggedPastTheOther() {
    let current = TimelineRange(fromMs: 50_000, toMs: 90_000)!
    var drag = TimelineRangeDrag(x: 200, timeMs: 89_000, current: current, lowerX: 100, upperX: 200)
    #expect(drag.update(x: 50, timeMs: 20_000) == TimelineRange(fromMs: 20_000, toMs: 51_000))
  }

  @Test func pressingInsideARangeStartsANewOne() {
    let current = TimelineRange(fromMs: 50_000, toMs: 90_000)!
    var drag = TimelineRangeDrag(x: 150, timeMs: 70_000, current: current, lowerX: 100, upperX: 200)
    #expect(drag.update(x: 170, timeMs: 75_000) == TimelineRange(fromMs: 70_000, toMs: 76_000))
  }

  @Test func aTinyRangeGrabsItsUpperEdgeSoItCanGrow() {
    let current = TimelineRange(fromMs: 50_000, toMs: 51_000)!
    var drag = TimelineRangeDrag(x: 100, timeMs: 50_000, current: current, lowerX: 100, upperX: 101)
    #expect(drag.update(x: 200, timeMs: 80_000) == TimelineRange(fromMs: 50_000, toMs: 81_000))
  }

  @Test func edgeHitTesting() {
    #expect(TimelineRangeDrag.isOnEdge(x: 106, lowerX: 100, upperX: 200))
    #expect(!TimelineRangeDrag.isOnEdge(x: 107, lowerX: 100, upperX: 200))
    #expect(!TimelineRangeDrag.isOnEdge(x: 100, lowerX: nil, upperX: nil))
  }

  // MARK: - Text

  @Test func durations() {
    #expect(TimelineRangeFormat.duration(30_000) == "30s")
    #expect(TimelineRangeFormat.duration(45 * 60_000) == "45m")
    #expect(TimelineRangeFormat.duration(125 * 60_000) == "2h 05m")
    #expect(TimelineRangeFormat.duration(24 * 3_600_000) == "1d")
    #expect(TimelineRangeFormat.duration(27 * 3_600_000) == "1d 3h")
    #expect(TimelineRangeFormat.duration(-5) == "0s")
  }

  @Test func countsNameWhatTheyHold() {
    #expect(TimelineRangeFormat.counts(.init(screen: 1, audio: 0)) == "1 snapshot")
    #expect(TimelineRangeFormat.counts(.init(screen: 0, audio: 2)) == "2 audio clips")
    #expect(TimelineRangeFormat.counts(.init(screen: 0, audio: 0)) == "0 snapshots")
    #expect(TimelineRangeFormat.counts(.init(screen: 3, audio: 1)) == "3 snapshots and 1 audio clip")
  }

  @Test func aWholeDayHidesItsMidnights() {
    let locale = Locale(identifier: "en_GB")
    let day = TimelineRange(fromMs: SummaryTestTime.ms(2026, 3, 11), toMs: SummaryTestTime.ms(2026, 3, 12))!
    let text = TimelineRangeFormat.period(day, calendar: calendar(), locale: locale)
    #expect(text.contains("11"))
    #expect(!text.contains("12"))
    #expect(!text.contains(":"))
    let hours = TimelineRange(fromMs: SummaryTestTime.ms(2026, 3, 11, 9), toMs: SummaryTestTime.ms(2026, 3, 11, 14))!
    #expect(TimelineRangeFormat.period(hours, calendar: calendar(), locale: locale).contains(":"))
  }

  // MARK: - Selection state

  @MainActor @Test func selectingNeedsSelectMode() {
    let selection = TimelineRangeSelection()
    let range = TimelineRange(fromMs: 0, toMs: 1_000)!
    selection.select(range)
    #expect(selection.range == nil)
    selection.begin()
    selection.select(range)
    #expect(selection.range == range)
  }

  @MainActor @Test func endingClearsEverything() {
    let selection = TimelineRangeSelection()
    selection.begin()
    selection.select(TimelineRange(fromMs: 0, toMs: 1_000)!)
    selection.requestSummary()
    #expect(selection.isSummaryOpen)
    selection.end()
    #expect(!selection.isActive)
    #expect(selection.range == nil)
    #expect(!selection.isSummaryOpen)
  }

  @MainActor @Test func actionsNeedARange() {
    let selection = TimelineRangeSelection()
    selection.begin()
    selection.requestSummary()
    selection.requestDelete()
    #expect(!selection.isSummaryOpen)
    #expect(selection.summaryRequest == 0)
    #expect(selection.deleteRequest == 0)
    selection.select(TimelineRange(fromMs: 0, toMs: 1_000)!)
    selection.requestSummary()
    selection.requestDelete()
    #expect(selection.summaryRequest == 1)
    #expect(selection.deleteRequest == 1)
  }
}
