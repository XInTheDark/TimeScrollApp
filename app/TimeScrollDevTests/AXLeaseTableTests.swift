import Foundation
import Testing
@testable import TimeScroll

struct AXLeaseTableTests {
  @Test func newAppsAreUndecidedUntilLeasedOrLeftAlone() {
    var table = AXLeaseTable()
    #expect(table.isUndecided(1))
    table.lease(1, now: 0)
    table.leaveAlone(2)
    #expect(!table.isUndecided(1))
    #expect(!table.isUndecided(2))
  }

  @Test func leasesExpireAfterIdleUnlessTouched() {
    var table = AXLeaseTable()
    table.lease(1, now: 0)
    table.lease(2, now: 0)
    table.touch([2, 3], now: 500)
    #expect(table.expire(now: 599, idle: 600).isEmpty)
    #expect(table.expire(now: 600, idle: 600) == [1])
    #expect(table.isUndecided(1))
    #expect(table.expire(now: 1_100, idle: 600) == [2])
    // Touching an app without a lease does not create one.
    #expect(table.lastUsed[3] == nil)
  }

  @Test func endAllReturnsEveryLeaseAndResetsDecisions() {
    var table = AXLeaseTable()
    table.lease(3, now: 0)
    table.lease(1, now: 0)
    table.leaveAlone(2)
    #expect(table.endAll() == [1, 3])
    #expect(table.isUndecided(1) && table.isUndecided(2) && table.isUndecided(3))
    #expect(table.endAll().isEmpty)
  }

  @Test func leftAloneAppsAreRecheckedOnceOffScreen() {
    var table = AXLeaseTable()
    table.leaveAlone(1)
    table.leaveAlone(2)
    table.forgetLeftAlone(except: [2])
    #expect(table.isUndecided(1))
    #expect(!table.isUndecided(2))
  }
}
