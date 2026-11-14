import Testing
@testable import TimeScroll

struct TimelineStripVisibilityTests {
  @Test func theLastVisibleStripCannotBeHidden() {
    #expect(!TimelineStripVisibility.allows(visible: false, otherVisible: false))
    #expect(TimelineStripVisibility.allows(visible: false, otherVisible: true))
    #expect(TimelineStripVisibility.allows(visible: true, otherVisible: false))
  }
}
