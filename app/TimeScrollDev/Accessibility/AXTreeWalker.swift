import CoreGraphics
import Foundation

/// Reads the visible text of one window, depth first, within its time, element and size budget.
/// Elements whose frame lies outside the window's visible parts (scrolled out, covered, on another
/// display) are skipped with their subtrees, so the cost follows what is on screen.
final class AXTreeWalker<Source: AXNodeSource> {
    typealias Element = Source.Element

    /// Documents at least this long are remembered, so later reads fetch only their visible range.
    static var documentHintLength: Int { 4_000 }

    private let source: Source
    private let limits: AXTextLimits
    private let deadline: AXDeadline
    private let visibleRects: [CGRect]
    private let visibleBounds: CGRect
    private let clock: () -> UInt64
    private let knownDocuments: Set<Element>

    /// Long editable text found in this walk; pass back as `knownDocuments` next time.
    private(set) var documents: Set<Element> = []
    private(set) var visitedCount = 0
    private(set) var culledCount = 0

    private var seen = Set<String>()
    private var buffer = ""
    private var count = 0
    private var boxes: [AXTextBox] = []
    private var excluded: Element?

    init(source: Source,
         limits: AXTextLimits,
         deadline: AXDeadline,
         visibleRects: [CGRect],
         knownDocuments: Set<Element> = [],
         clock: @escaping () -> UInt64 = AXDeadline.now) {
        self.source = source
        self.limits = limits
        self.deadline = deadline
        self.visibleRects = visibleRects
        self.visibleBounds = visibleRects.reduce(CGRect.null) { $0.union($1) }
        self.knownDocuments = knownDocuments
        self.clock = clock
    }

    private var isExhausted: Bool {
        count >= limits.maxCharsPerWindow * 2
            || visitedCount >= limits.maxElementsPerWindow
            || deadline.isSoftExpired(at: clock())
    }

    /// Walks `root`, skipping the subtree at `excluding` (one already walked, such as the focused element).
    func walk(_ root: Element, excluding: Element? = nil) {
        guard !visibleBounds.isNull else { return }
        excluded = excluding
        visit(root, depth: 0, clip: visibleBounds)
        excluded = nil
    }

    func finish() -> AXWindowText {
        let cut = AXTextRules.truncatedMiddle(buffer, count: count, limit: limits.maxCharsPerWindow)
        return AXWindowText(text: cut.text, count: cut.count, boxes: boxes)
    }

    // MARK: - Traversal

    /// Reads `element` and its visible subtree; returns the frame it reported, for sibling scans.
    @discardableResult
    private func visit(_ element: Element, depth: Int, clip: CGRect) -> CGRect? {
        guard depth <= limits.maxDepth, !isExhausted else { return nil }
        if let excluded, excluded == element { return nil }
        visitedCount += 1
        let isKnownDocument = knownDocuments.contains(element)
        guard let node = source.node(element, includeValue: !isKnownDocument, deadline: deadline) else { return nil }
        if AXTextRules.skippedRoles.contains(node.role) || node.subrole == AXTextRules.secureSubrole { return node.frame }

        var childClip = clip
        if let frame = node.frame, frame.width > 0, frame.height > 0 {
            let shown = frame.intersection(clip)
            guard !shown.isNull, shown.width > 0, shown.height > 0,
                  visibleRects.contains(where: { $0.intersects(shown) }) else {
                culledCount += 1
                return frame
            }
            if AXTextRules.viewportRoles.contains(node.role) { childClip = shown }
        }

        collectText(of: element, node, isKnownDocument: isKnownDocument)
        visitChildren(of: element, node, depth: depth, clip: childClip)
        return node.frame
    }

    private func visitChildren(of element: Element, _ node: AXNode<Element>, depth: Int, clip: CGRect) {
        let children = node.children
        guard !children.isEmpty else { return }
        if children.count > AXSiblingScan.largeChildCount {
            if let visible = source.visibleChildren(element, role: node.role, deadline: deadline), !visible.isEmpty {
                for child in visible {
                    if isExhausted { return }
                    visit(child, depth: depth + 1, clip: clip)
                }
                return
            }
            scanLargeChildren(children, depth: depth, clip: clip)
            return
        }
        for child in children {
            if isExhausted { return }
            visit(child, depth: depth + 1, clip: clip)
        }
    }

    /// Siblings laid out top to bottom are read from the first one reaching the viewport until a run
    /// of them lies below it. Any other layout is read in full, still culled one by one.
    private func scanLargeChildren(_ children: [Element], depth: Int, clip: CGRect) {
        var probed: [Int: CGRect?] = [:]
        let frameAt: (Int) -> CGRect? = { index in
            if let known = probed[index] { return known }
            let frame = self.source.frame(children[index], deadline: self.deadline)
            probed[index] = frame
            return frame
        }
        let ordered = AXSiblingScan.isTopToBottom(count: children.count, frameAt: frameAt)
        let start = ordered ? AXSiblingScan.firstReaching(top: clip.minY, count: children.count, frameAt: frameAt) : 0
        var belowRun = 0
        for index in start..<children.count {
            if isExhausted { return }
            let frame = visit(children[index], depth: depth + 1, clip: clip)
            guard ordered else { continue }
            if let frame, frame.height > 0, frame.minY > clip.maxY {
                belowRun += 1
                if belowRun >= AXSiblingScan.belowRunToStop { return }
            } else {
                belowRun = 0
            }
        }
    }

    // MARK: - Text

    /// The value, else the title, else the description, as before; long editable text keeps only
    /// the range scrolled into view.
    private func collectText(of element: Element, _ node: AXNode<Element>, isKnownDocument: Bool) {
        if AXTextRules.documentRoles.contains(node.role),
           let text = documentText(of: element, node, isKnownDocument: isKnownDocument) {
            if AXTextRules.acceptsValue(text) { add(text, frame: nil) }
            return
        }
        if let value = node.value, AXTextRules.acceptsValue(value) {
            add(value, frame: node.frame)
        } else if let title = node.title, AXTextRules.acceptsTitle(title) {
            add(title, frame: node.frame)
        } else if let description = node.description, AXTextRules.acceptsDescription(description) {
            add(description, frame: node.frame)
        }
    }

    /// Visible text of editable text that may hold a long document; nil when it is short, so the
    /// usual rules apply. Falls back to the whole value when the app reports no visible range.
    private func documentText(of element: Element, _ node: AXNode<Element>, isKnownDocument: Bool) -> String? {
        let length = node.value?.utf16.count ?? 0
        guard isKnownDocument || length > AXTextRules.maxBoxedTextLength else { return nil }
        if let range = source.visibleCharacterRange(element, deadline: deadline) {
            if let value = node.value {
                if length >= Self.documentHintLength { documents.insert(element) }
                return AXTextRules.visibleSlice(of: value, range: range) ?? value
            }
            if let visible = source.string(element, range: range, deadline: deadline), !visible.isEmpty {
                documents.insert(element)
                return visible
            }
        }
        return node.value ?? source.value(element, deadline: deadline)
    }

    private func add(_ text: String, frame: CGRect?) {
        guard seen.insert(text).inserted else { return }
        let length = text.count
        buffer.append(text)
        buffer.append("\n")
        count += length + 1
        if let frame, length <= AXTextRules.maxBoxedTextLength, frame.width > 0, frame.height > 0 {
            boxes.append(AXTextBox(text: text, frame: frame))
        }
    }
}
