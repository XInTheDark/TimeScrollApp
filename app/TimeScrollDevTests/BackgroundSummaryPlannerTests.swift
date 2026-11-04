import Foundation
import Testing
@testable import TimeScroll

struct BackgroundSummaryPlannerTests {
  private let utc = SummaryTestTime.calendar()
  private let now = SummaryTestTime.ms(2026, 3, 18) + 3_600_000  // A Wednesday, 01:00.
  private let day: Int64 = 86_400_000

  private func conditions(ac: Bool = true, battery: Int? = nil, lowPower: Bool = false, thermal: Bool = true, idle: TimeInterval = 600) -> BackgroundSummaryConditions {
    BackgroundSummaryConditions(onACPower: ac, batteryPercent: battery, lowPowerMode: lowPower, thermalNominal: thermal, idleSeconds: idle)
  }

  @Test func conditionsDecideHowMuchMayRun() {
    #expect(conditions().allowance == .all)
    #expect(conditions(ac: false, battery: 80).allowance == .recentOnly)
    #expect(conditions(ac: false, battery: 50).allowance == .none)
    #expect(conditions(ac: false, battery: nil).allowance == .none)
    #expect(conditions(lowPower: true).allowance == .none)
    #expect(conditions(thermal: false).allowance == .none)
    #expect(conditions(idle: 10).allowance == .none)
  }

  @Test func catchUpGoesThroughDaysFirstNewestFirst() {
    let pending = BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [], skipped: [], allowance: .all)
    let yesterday = SummaryTestTime.ms(2026, 3, 17)
    #expect(pending.first == yesterday..<(yesterday + day))
    #expect(pending[1].lowerBound == yesterday - day)
    #expect(pending.prefix(BackgroundSummaryPlanner.catchUpDays).allSatisfy { $0.upperBound - $0.lowerBound == day })
    #expect(pending.count > BackgroundSummaryPlanner.catchUpDays)
    #expect(pending.count == Set(pending).count)
  }

  @Test func batteryOnlyDoesTheLatestOfEach() {
    let pending = BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [], skipped: [], allowance: .recentOnly)
    #expect(pending.count == 3)
  }

  @Test func storedAndSkippedPeriodsAreLeftOut() {
    let yesterday = SummaryTestTime.ms(2026, 3, 17)
    let dayBefore = yesterday - day
    let pending = BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [yesterday..<(yesterday + day)],
                                                   skipped: [dayBefore..<yesterday], allowance: .all)
    #expect(pending.first?.lowerBound == dayBefore - day)
  }

  @Test func aDayStillSettlingWaits() {
    let justAfterMidnight = SummaryTestTime.ms(2026, 3, 18) + 60_000
    let pending = BackgroundSummaryPlanner.pending(nowMs: justAfterMidnight, calendar: utc, stored: [], skipped: [], allowance: .recentOnly)
    #expect(pending.first?.lowerBound == SummaryTestTime.ms(2026, 3, 16))
  }

  @Test func noAllowanceMeansNothing() {
    #expect(BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [], skipped: [], allowance: .none).isEmpty)
  }

  @Test func generatedRangesUseStoredStateInsteadOfTheTransientSkipSet() {
    let period = SummaryTestTime.ms(2026, 3, 17)..<SummaryTestTime.ms(2026, 3, 18)
    #expect(!BackgroundSummaryRunner.shouldSkipAfter(.generated(text: "Summary", stored: true)))
    #expect(BackgroundSummaryRunner.shouldSkipAfter(.noActivity))
    #expect(BackgroundSummaryRunner.shouldSkipAfter(.failed))
    #expect(BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [], skipped: [], allowance: .all).contains(period))
    #expect(!BackgroundSummaryPlanner.pending(nowMs: now, calendar: utc, stored: [period], skipped: [], allowance: .all).contains(period))
  }
}
