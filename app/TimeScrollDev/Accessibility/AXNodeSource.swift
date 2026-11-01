import CoreGraphics
import Foundation

/// The attributes the tree walker needs from one element, read in a single round trip.
struct AXNode<Element> {
    let role: String
    let subrole: String?
    /// Nil when not a string, or when it was not requested.
    let value: String?
    let title: String?
    let description: String?
    let children: [Element]
    /// Global frame (top-left origin); nil when the element reports none.
    let frame: CGRect?
}

/// Where the walker reads elements from: live Accessibility in the app, a fixed tree in tests.
/// Every read is bounded by the deadline and returns nil once it has passed.
protocol AXNodeSource {
    associatedtype Element: Hashable

    /// Role, subrole, title, description, children, frame and (if `includeValue`) value.
    func node(_ element: Element, includeValue: Bool, deadline: AXDeadline) -> AXNode<Element>?
    /// The rows (tables, outlines) or children (lists, scroll areas) the element says are on screen.
    func visibleChildren(_ element: Element, role: String, deadline: AXDeadline) -> [Element]?
    func frame(_ element: Element, deadline: AXDeadline) -> CGRect?
    func value(_ element: Element, deadline: AXDeadline) -> String?
    /// UTF-16 range of an editable text element that is scrolled into view.
    func visibleCharacterRange(_ element: Element, deadline: AXDeadline) -> NSRange?
    func string(_ element: Element, range: NSRange, deadline: AXDeadline) -> String?
}
