import CoreGraphics
import Foundation
@testable import TimeScroll

/// An in-memory Accessibility tree. Every read advances a fake clock by `costPerRead` nanoseconds.
final class FakeAXTree: AXNodeSource {
  struct Node {
    var role = "AXGroup"
    var subrole: String?
    var value: String?
    var title: String?
    var description: String?
    var children: [Int] = []
    var frame: CGRect?
    var visibleChildren: [Int]?
    var visibleRange: NSRange?
  }

  var nodes: [Int: Node] = [:]
  var costPerRead: UInt64 = 0
  private(set) var clock: UInt64 = 0
  private(set) var nodeReads: [Int] = []
  private(set) var valueOmitted: [Int] = []
  private(set) var frameReads = 0
  private(set) var stringReads = 0

  subscript(id: Int) -> Node {
    get { nodes[id] ?? Node() }
    set { nodes[id] = newValue }
  }

  private func tick() { clock += costPerRead }

  func node(_ element: Int, includeValue: Bool, deadline: AXDeadline) -> AXNode<Int>? {
    tick()
    nodeReads.append(element)
    if !includeValue { valueOmitted.append(element) }
    guard let n = nodes[element] else { return nil }
    return AXNode(role: n.role, subrole: n.subrole, value: includeValue ? n.value : nil, title: n.title,
                  description: n.description, children: n.children, frame: n.frame)
  }

  func visibleChildren(_ element: Int, role: String, deadline: AXDeadline) -> [Int]? {
    tick()
    return nodes[element]?.visibleChildren
  }

  func frame(_ element: Int, deadline: AXDeadline) -> CGRect? {
    tick()
    frameReads += 1
    return nodes[element]?.frame
  }

  func value(_ element: Int, deadline: AXDeadline) -> String? {
    tick()
    return nodes[element]?.value
  }

  func visibleCharacterRange(_ element: Int, deadline: AXDeadline) -> NSRange? {
    tick()
    return nodes[element]?.visibleRange
  }

  func string(_ element: Int, range: NSRange, deadline: AXDeadline) -> String? {
    tick()
    stringReads += 1
    guard let value = nodes[element]?.value else { return nil }
    return (value as NSString).substring(with: range)
  }
}
