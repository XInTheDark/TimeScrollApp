import CoreGraphics
import Testing
@testable import TimeScroll

struct AXTextMergerTests {
  private func window(_ text: String, boxes: [AXTextBox] = []) -> AXWindowText {
    AXWindowText(text: text, count: text.count, boxes: boxes)
  }

  @Test func joinsWindowsFrontToBackWithinTheTotalLimit() {
    let display = CGRect(x: 0, y: 0, width: 100, height: 100)
    let merged = AXTextMerger.merge([window("front\n"), .empty, window("back\n"), window("more\n")],
                                    displayBounds: display, maxTotalChars: 9)
    #expect(merged.text == "front\nbac")
    #expect(AXTextMerger.merge([], displayBounds: display, maxTotalChars: 10).text.isEmpty)
  }

  @Test func boxesAreClippedAndNormalizedToTheDisplay() throws {
    let display = CGRect(x: -1000, y: 0, width: 1000, height: 500)
    let boxes = [
      AXTextBox(text: "inside", frame: CGRect(x: -900, y: 100, width: 100, height: 50)),
      AXTextBox(text: "straddles", frame: CGRect(x: -50, y: 0, width: 100, height: 50)),
      AXTextBox(text: "elsewhere", frame: CGRect(x: 100, y: 100, width: 100, height: 50)),
      AXTextBox(text: "sliver", frame: CGRect(x: -1, y: 0, width: 10, height: 50)),
    ]
    let lines = AXTextMerger.merge([window("x\n", boxes: boxes)], displayBounds: display, maxTotalChars: 100).lines
    #expect(lines.map(\.text) == ["inside", "straddles"])
    let inside = try #require(lines.first).box
    #expect(abs(inside.minX - 0.1) < 1e-9 && abs(inside.width - 0.1) < 1e-9)
    // Vision origin is bottom-left: a box 100...150 from the top of a 500 pt display.
    #expect(abs(inside.minY - 0.7) < 1e-9 && abs(inside.height - 0.1) < 1e-9)
    #expect(abs(lines[1].box.width - 0.05) < 1e-9)
  }

  @Test func zeroSizedDisplayGetsNoBoxes() {
    let box = AXTextBox(text: "a", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    #expect(AXTextMerger.merge([window("a\n", boxes: [box])], displayBounds: .zero, maxTotalChars: 10).lines.isEmpty)
  }
}
