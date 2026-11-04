import Foundation
import Testing
@testable import TimeScroll

struct ExcerptLineSelectorTests {
  @Test func emptyInputGivesNothing() {
    #expect(ExcerptLineSelector.select(texts: [], keywords: ["a"], toBytes: 100) == "")
    #expect(ExcerptLineSelector.select(texts: [""], keywords: [], toBytes: 100) == "")
    #expect(ExcerptLineSelector.select(texts: ["hello"], keywords: [], toBytes: 0) == "")
  }

  @Test func keywordLinesBeatTheStartOfTheScreen() {
    let text = "File Edit View History Window Help\nThe vault migration failed on step three\nsomething else entirely here"
    #expect(ExcerptLineSelector.select(texts: [text], keywords: ["vault"], toBytes: 45) == "The vault migration failed on step three")
  }

  @Test func linesOnEveryScreenLoseToLinesOnOne() {
    let chrome = "File Edit View History Window Help Menu"
    let ranked = ExcerptLineSelector.ranked(texts: ["\(chrome)\nA first screen with its own content", "\(chrome)\nA second screen with other content"], keywords: [])
    #expect(ranked.last == chrome)
  }

  @Test func duplicatesAppearOnceAndResultIsInReadingOrder() {
    let selected = ExcerptLineSelector.select(texts: ["first line of the text\nsecond line of the text\nfirst line of the text"], keywords: ["second"], toBytes: 500)
    #expect(selected == "first line of the text\nsecond line of the text")
  }

  @Test func hugeAndMultibyteTextStaysInsideTheLimit() {
    let huge = String(repeating: "日本語🧑‍💻", count: 100_000)
    for limit in [1, 5, 50, 500, 5_000] {
      #expect(ExcerptLineSelector.select(texts: [huge, huge], keywords: ["語"], toBytes: limit).utf8.count <= limit)
    }
  }
}
