import Foundation
import Testing
@testable import TimeScroll

struct AXTextRulesTests {
  @Test func recognizesPasswordMasks() {
    #expect(AXTextRules.isLikelyMask("••••"))
    #expect(AXTextRules.isLikelyMask("****"))
    #expect(AXTextRules.isLikelyMask("●●●"))
    #expect(!AXTextRules.isLikelyMask(""))
    #expect(!AXTextRules.isLikelyMask("pass•"))
  }

  @Test func acceptanceThresholds() {
    #expect(!AXTextRules.acceptsValue("a"))
    #expect(AXTextRules.acceptsValue("ab"))
    #expect(!AXTextRules.acceptsValue("••"))
    #expect(AXTextRules.acceptsTitle("OK"))
    #expect(!AXTextRules.acceptsDescription("ab"))
    #expect(AXTextRules.acceptsDescription("abc"))
  }

  @Test func visibleSliceUsesUTF16AndWholeCharacters() {
    let text = "ab👍🏽cd"
    let ns = text as NSString
    // Starting inside the emoji widens to the whole emoji.
    let slice = AXTextRules.visibleSlice(of: text, range: NSRange(location: 3, length: 4))
    #expect(slice == "👍🏽c")
    #expect(AXTextRules.visibleSlice(of: text, range: NSRange(location: 0, length: ns.length)) == nil)
    #expect(AXTextRules.visibleSlice(of: text, range: NSRange(location: 2, length: 0)) == nil)
    #expect(AXTextRules.visibleSlice(of: text, range: NSRange(location: ns.length, length: 1)) == nil)
    #expect(AXTextRules.visibleSlice(of: text, range: NSRange(location: -1, length: 2)) == nil)
    #expect(AXTextRules.visibleSlice(of: text, range: NSRange(location: ns.length - 1, length: 5)) == "d")
  }

  @Test func truncatesTheMiddleOnlyPastTheLimit() {
    let short = AXTextRules.truncatedMiddle("abcdef", count: 6, limit: 6)
    #expect(short.text == "abcdef" && short.count == 6)
    let long = AXTextRules.truncatedMiddle("abcdefghij", count: 10, limit: 4)
    #expect(long.text == "ab\n...[truncated]...\nij")
    #expect(long.count == long.text.count)
  }
}
