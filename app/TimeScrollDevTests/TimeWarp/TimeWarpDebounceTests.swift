import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpDebounceTests {
  @Test func quietPeriodEndsTheBurst() {
    var debounce = TimeWarpDebounce()
    let first = debounce.note(at: 10)
    let second = debounce.note(at: 10.2)
    #expect(first == 10.5)
    #expect(second == 10.7)
    let early = debounce.fire(at: 10.5)
    let due = debounce.fire(at: 10.7)
    #expect(!early)
    #expect(due)
    #expect(debounce.dueTime == nil)
  }

  @Test func neverEndingBurstStillFiresAtMaxDelay() {
    var debounce = TimeWarpDebounce()
    var time = 0.0
    var due = 0.0
    while time < 5 {
      due = debounce.note(at: time)
      time += 0.1
    }
    #expect(due == 2)
    let fired = debounce.fire(at: 2)
    #expect(fired)
  }

  @Test func fireWithoutEventsDoesNothing() {
    var debounce = TimeWarpDebounce()
    let fired = debounce.fire(at: 100)
    #expect(!fired)
  }
}
