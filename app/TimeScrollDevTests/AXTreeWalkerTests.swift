import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct AXTreeWalkerTests {
  private static let window = CGRect(x: 0, y: 0, width: 800, height: 600)

  private func limits(maxDepth: Int = 48, maxElements: Int = 20_000, maxChars: Int = 50_000,
                      softMs: Int = 200, hardMs: Int = 400) -> AXTextLimits {
    AXTextLimits(maxWindows: 16, maxCharsPerWindow: maxChars, maxTotalChars: 200_000, maxDepth: maxDepth,
                 maxElementsPerWindow: maxElements, softTimeBudgetMs: softMs, hardTimeBudgetMs: hardMs)
  }

  private func walker(_ tree: FakeAXTree, limits: AXTextLimits? = nil, visible: [CGRect] = [window],
                      documents: Set<Int> = []) -> AXTreeWalker<FakeAXTree> {
    AXTreeWalker(source: tree, limits: limits ?? self.limits(), deadline: AXDeadline(startNanos: 0, limits: limits ?? self.limits()),
                 visibleRects: visible, knownDocuments: documents, clock: { tree.clock })
  }

  private func lines(_ text: AXWindowText) -> [String] {
    text.text.split(separator: "\n").map(String.init)
  }

  // MARK: - Text rules

  @Test func readsValueThenTitleThenDescriptionAndDeduplicates() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1, 2, 3, 4, 5])
    tree[1] = .init(role: "AXStaticText", value: "Hello there", title: "ignored title")
    tree[2] = .init(role: "AXButton", title: "Send")
    tree[3] = .init(role: "AXButton", description: "Attach file")
    tree[4] = .init(role: "AXStaticText", value: "Hello there")
    tree[5] = .init(role: "AXButton", value: "x", title: "y", description: "ab")
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["Hello there", "Send", "Attach file"])
  }

  @Test func skipsSecureFieldsMasksAndSkippedRoleSubtrees() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1, 2, 3, 5])
    tree[1] = .init(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter22")
    tree[2] = .init(role: "AXTextField", value: "••••••")
    tree[3] = .init(role: "AXToolbar", children: [4])
    tree[4] = .init(role: "AXStaticText", value: "inside toolbar")
    tree[5] = .init(role: "AXStaticText", value: "visible")
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["visible"])
    #expect(!tree.nodeReads.contains(4))
  }

  @Test func boxesOnlyShortTextWithFrames() {
    let tree = FakeAXTree()
    let long = String(repeating: "a", count: AXTextRules.maxBoxedTextLength + 1)
    tree[0] = .init(role: "AXWindow", children: [1, 2, 3])
    tree[1] = .init(role: "AXStaticText", value: "boxed", frame: CGRect(x: 10, y: 10, width: 50, height: 20))
    tree[2] = .init(role: "AXStaticText", value: long, frame: CGRect(x: 10, y: 40, width: 500, height: 200))
    tree[3] = .init(role: "AXStaticText", value: "no frame")
    let w = walker(tree)
    w.walk(0)
    let text = w.finish()
    #expect(text.boxes == [AXTextBox(text: "boxed", frame: CGRect(x: 10, y: 10, width: 50, height: 20))])
    #expect(lines(text).count == 3)
  }

  // MARK: - Culling

  @Test func culledSubtreesAreNeverRead() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1, 3])
    tree[1] = .init(role: "AXGroup", children: [2], frame: CGRect(x: 0, y: 900, width: 800, height: 100))
    tree[2] = .init(role: "AXStaticText", value: "below the window")
    tree[3] = .init(role: "AXGroup", children: [4], frame: CGRect(x: 0, y: 100, width: 800, height: 100))
    tree[4] = .init(role: "AXStaticText", value: "on screen")
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["on screen"])
    #expect(!tree.nodeReads.contains(2))
    #expect(w.culledCount == 1)
  }

  @Test func elementsCoveredByAnotherWindowAreCulled() {
    // Visible: the left and right strips; the middle is covered.
    let visible = [CGRect(x: 0, y: 0, width: 200, height: 600), CGRect(x: 600, y: 0, width: 200, height: 600)]
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1, 2, 3])
    tree[1] = .init(role: "AXStaticText", value: "left", frame: CGRect(x: 10, y: 10, width: 100, height: 20))
    tree[2] = .init(role: "AXStaticText", value: "covered", frame: CGRect(x: 300, y: 10, width: 100, height: 20))
    tree[3] = .init(role: "AXStaticText", value: "straddles", frame: CGRect(x: 150, y: 50, width: 100, height: 20))
    let w = walker(tree, visible: visible)
    w.walk(0)
    #expect(lines(w.finish()) == ["left", "straddles"])
  }

  @Test func elementsWithoutFramesAreNotCulled() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXGroup", children: [2], frame: CGRect(x: 0, y: 0, width: 0, height: 0))
    tree[2] = .init(role: "AXStaticText", value: "kept")
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["kept"])
  }

  @Test func scrollAreaClipsItsDescendants() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXScrollArea", children: [2, 3], frame: CGRect(x: 0, y: 100, width: 800, height: 200))
    tree[2] = .init(role: "AXStaticText", value: "in view", frame: CGRect(x: 0, y: 150, width: 100, height: 20))
    tree[3] = .init(role: "AXStaticText", value: "scrolled out", frame: CGRect(x: 0, y: 400, width: 100, height: 20))
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["in view"])
  }

  @Test func emptyVisibleRegionReadsNothing() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXStaticText", value: "anything")
    let w = walker(tree, visible: [])
    w.walk(0)
    #expect(w.finish() == .empty)
    #expect(tree.nodeReads.isEmpty)
  }

  // MARK: - Long sibling lists

  /// A list of `count` rows, 20 pt tall each, inside a 200 pt viewport scrolled to `offset`.
  private func longList(count: Int, offset: CGFloat, ordered: Bool = true) -> FakeAXTree {
    let tree = FakeAXTree()
    let rows = (0..<count).map { 100 + $0 }
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXScrollArea", children: [2], frame: CGRect(x: 0, y: 100, width: 800, height: 200))
    tree[2] = .init(role: "AXGroup", children: rows)
    for (index, id) in rows.enumerated() {
      let slot = ordered ? index : (index * 7919) % count
      let y = 100 + CGFloat(slot) * 20 - offset
      tree[id] = .init(role: "AXStaticText", value: "row \(slot)", frame: CGRect(x: 0, y: y, width: 800, height: 20))
    }
    return tree
  }

  @Test func orderedLongListReadsOnlyTheVisibleRows() {
    let tree = longList(count: 5_000, offset: 40_000)
    let w = walker(tree)
    w.walk(0)
    let rows = lines(w.finish())
    // Rows 2000...2009 fill the viewport (y 100..<300).
    #expect(rows == (2000...2009).map { "row \($0)" })
    #expect(tree.nodeReads.count < 40)
    #expect(tree.frameReads < 30)
  }

  @Test func orderedLongListAtTopAndBottom() {
    let top = longList(count: 1_000, offset: 0)
    let wTop = walker(top)
    wTop.walk(0)
    #expect(lines(wTop.finish()) == (0...9).map { "row \($0)" })

    let bottom = longList(count: 1_000, offset: 19_800)
    let wBottom = walker(bottom)
    wBottom.walk(0)
    #expect(lines(wBottom.finish()) == (990...999).map { "row \($0)" })
  }

  @Test func unorderedLongListIsReadInFullAndCulled() {
    let tree = longList(count: 200, offset: 0, ordered: false)
    let w = walker(tree)
    w.walk(0)
    #expect(Set(lines(w.finish())) == Set((0...9).map { "row \($0)" }))
    #expect(tree.nodeReads.count >= 200)
  }

  @Test func listsReportingVisibleChildrenReadOnlyThose() {
    let tree = longList(count: 500, offset: 0)
    tree[2].visibleChildren = [100, 101]
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["row 0", "row 1"])
    #expect(!tree.nodeReads.contains(102))
  }

  @Test func shortListsAreNeverProbed() {
    let tree = longList(count: AXSiblingScan.largeChildCount, offset: 0)
    let w = walker(tree)
    w.walk(0)
    #expect(tree.frameReads == 0)
    #expect(lines(w.finish()).count == 10)
  }

  // MARK: - Budgets

  @Test func depthLimitStopsDescent() {
    let tree = FakeAXTree()
    for id in 0..<60 { tree[id] = .init(role: "AXGroup", title: "level \(id)", children: [id + 1]) }
    let w = walker(tree, limits: limits(maxDepth: 48))
    w.walk(0)
    let read = lines(w.finish())
    #expect(read.count == 49)
    #expect(read.last == "level 48")
  }

  @Test func softTimeBudgetStopsNewReads() {
    let tree = FakeAXTree()
    tree.costPerRead = 1_000_000 // 1 ms per read
    tree[0] = .init(role: "AXWindow", children: Array(1...50))
    for id in 1...50 { tree[id] = .init(role: "AXStaticText", value: "item \(id)") }
    let w = walker(tree, limits: limits(softMs: 10, hardMs: 20))
    w.walk(0)
    #expect(tree.nodeReads.count == 10)
  }

  @Test func elementBudgetStopsTraversal() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: Array(1...50))
    for id in 1...50 { tree[id] = .init(role: "AXStaticText", value: "item \(id)") }
    let w = walker(tree, limits: limits(maxElements: 5))
    w.walk(0)
    #expect(lines(w.finish()).count == 4)
  }

  @Test func perWindowCharacterLimitTruncatesTheMiddle() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: Array(1...40))
    for id in 1...40 { tree[id] = .init(role: "AXStaticText", value: String(format: "line %02d", id)) }
    let w = walker(tree, limits: limits(maxChars: 100))
    w.walk(0)
    let text = w.finish()
    #expect(text.text.hasPrefix("line 01"))
    #expect(text.text.contains("...[truncated]..."))
    #expect(text.count == text.text.count)
    // Reading stops at twice the limit.
    #expect(tree.nodeReads.count < 30)
  }

  // MARK: - Focused element and documents

  @Test func focusedSubtreeIsReadFirstAndOnlyOnce() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1, 2])
    tree[1] = .init(role: "AXStaticText", value: "sidebar")
    tree[2] = .init(role: "AXGroup", children: [3])
    tree[3] = .init(role: "AXStaticText", value: "editor")
    let w = walker(tree)
    w.walk(2)
    w.walk(0, excluding: 2)
    #expect(lines(w.finish()) == ["editor", "sidebar"])
    #expect(tree.nodeReads.filter { $0 == 2 || $0 == 3 }.count == 2)
  }

  @Test func longDocumentKeepsOnlyItsVisibleRangeAndIsRemembered() {
    let doc = (0..<1_000).map { "paragraph \($0)" }.joined(separator: "\n")
    let visible = (doc as NSString).range(of: "paragraph 500\nparagraph 501")
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXTextArea", value: doc, frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleRange: visible)
    let first = walker(tree)
    first.walk(0)
    #expect(lines(first.finish()) == ["paragraph 500", "paragraph 501"])
    #expect(first.finish().boxes.isEmpty)
    #expect(first.documents == [1])

    // Next time the document's value is not fetched; only its visible range is.
    let second = walker(tree, documents: first.documents)
    second.walk(0)
    #expect(lines(second.finish()) == ["paragraph 500", "paragraph 501"])
    #expect(tree.valueOmitted == [1])
    #expect(tree.stringReads == 1)
  }

  @Test func documentWithoutVisibleRangeKeepsWholeValue() {
    let doc = String(repeating: "word ", count: 2_000)
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXTextArea", value: doc)
    let w = walker(tree)
    w.walk(0)
    #expect(w.finish().text == doc + "\n")
    #expect(w.documents.isEmpty)
  }

  @Test func shortTextAreaFollowsUsualRules() {
    let tree = FakeAXTree()
    tree[0] = .init(role: "AXWindow", children: [1])
    tree[1] = .init(role: "AXTextArea", value: "short note", frame: CGRect(x: 0, y: 0, width: 100, height: 20), visibleRange: NSRange(location: 0, length: 3))
    let w = walker(tree)
    w.walk(0)
    #expect(lines(w.finish()) == ["short note"])
    #expect(w.finish().boxes.count == 1)
  }
}
