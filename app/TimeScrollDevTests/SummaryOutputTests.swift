import Foundation
import Testing
@testable import TimeScroll

struct SummaryOutputTests {
  private func topic(_ title: String, _ summary: String) -> [String: Any] { ["title": title, "summary": summary] }

  @Test func anOverviewAndTopicsBecomeBlocks() {
    let text = SummaryOutput.text(fromAnswer: ["overview": "Mostly coding.", "topics": [topic("Timeline", "Fixed drawing.")]])
    #expect(text == "Mostly coding.\n\nTimeline\nFixed drawing.")
  }

  @Test func blocksReadBackAsSections() {
    #expect(SummaryOutput.sections(in: "Mostly coding.\n\nTimeline\nFixed drawing.") == [
      .init(title: nil, body: "Mostly coding."),
      .init(title: "Timeline", body: "Fixed drawing."),
    ])
  }

  @Test func oldSummariesReadAsPlainParagraphs() {
    #expect(SummaryOutput.sections(in: "One.\n\nTwo.") == [.init(title: nil, body: "One."), .init(title: nil, body: "Two.")])
  }

  @Test func lineBreaksInsideAnswersCannotCreateFalseTitles() {
    let text = SummaryOutput.text(fromAnswer: ["overview": "A\n\nB", "topics": [topic("T\nU", "C\n\nD  E")]])
    #expect(text == "A B\n\nT U\nC D E")
  }

  @Test func emptyAnswersGiveNothing() {
    #expect(SummaryOutput.text(fromAnswer: [:]) == nil)
    #expect(SummaryOutput.text(fromAnswer: ["overview": "  ", "topics": [topic("Title", " ")]]) == nil)
    #expect(SummaryOutput.sections(in: "").isEmpty)
    #expect(SummaryOutput.sections(in: "\n\n\n\n").isEmpty)
  }

  @Test func aTopicWithoutATitleKeepsItsText() {
    #expect(SummaryOutput.text(fromAnswer: ["overview": "", "topics": [topic("", "Only text.")]]) == "Only text.")
  }

  @Test func extraTopicsAreDropped() {
    let topics = (0..<20).map { topic("T\($0)", "S\($0)") }
    let sections = SummaryOutput.sections(in: SummaryOutput.text(fromAnswer: ["overview": "O", "topics": topics]) ?? "")
    #expect(sections.count == SummaryOutput.maxTopics + 1)
  }

  @Test func wrongTypesAreIgnored() {
    #expect(SummaryOutput.text(fromAnswer: ["overview": 3, "topics": "nope"]) == nil)
  }

  @Test func theSchemaIsValidJSON() {
    #expect(JSONSerialization.isValidJSONObject(SummaryOutput.jsonSchema))
  }
}
