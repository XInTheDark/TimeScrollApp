import Foundation
import Testing
@testable import TimeScroll

struct SummaryBucketsTests {
  private let utc = SummaryTestTime.calendar()

  @Test func aLongerRangeUsesCoarserUnits() {
    let day: Int64 = 86_400_000
    #expect(SummaryBuckets.unit(lengthMs: 7 * day) == .day)
    #expect(SummaryBuckets.unit(lengthMs: 30 * day) == .weekOfYear)
    #expect(SummaryBuckets.unit(lengthMs: 365 * day) == .month)
    #expect(SummaryBuckets.unit(lengthMs: 3_000 * day) == .year)
  }

  @Test func aYearIsTwelveContiguousMonths() {
    let from = SummaryTestTime.ms(2026, 1, 1)
    let to = SummaryTestTime.ms(2027, 1, 1)
    let buckets = SummaryBuckets.buckets(fromMs: from, toMs: to, calendar: utc)
    #expect(buckets.count == 12)
    #expect(buckets.first?.lowerBound == from)
    #expect(buckets.last?.upperBound == to)
    for (left, right) in zip(buckets, buckets.dropFirst()) { #expect(left.upperBound == right.lowerBound) }
  }

  @Test func partialEdgesAreClipped() {
    let from = SummaryTestTime.ms(2026, 1, 15)
    let to = SummaryTestTime.ms(2026, 2, 28)
    let buckets = SummaryBuckets.buckets(fromMs: from, toMs: to, calendar: utc)
    #expect(buckets.first?.lowerBound == from)
    #expect(buckets.last?.upperBound == to)
  }

  @Test func dstDaysStayContiguous() {
    let zone = "America/New_York"
    let calendar = SummaryTestTime.calendar(zone)
    let from = SummaryTestTime.ms(2026, 3, 5, zone: zone)
    let to = SummaryTestTime.ms(2026, 3, 12, zone: zone)
    let buckets = SummaryBuckets.buckets(fromMs: from, toMs: to, calendar: calendar)
    #expect(buckets.count == 7)
    #expect(buckets.contains { $0.upperBound - $0.lowerBound == 23 * 3_600_000 })
  }

  @Test func anEmptyRangeHasNoBuckets() {
    #expect(SummaryBuckets.buckets(fromMs: 5, toMs: 5, calendar: utc).isEmpty)
  }
}
