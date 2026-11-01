import Foundation

/// Which Accessibility strings count as visible text, and how they are cut to size.
enum AXTextRules {
    /// Roles that hold no user-visible text of their own; their subtrees are skipped too.
    static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXRuler", "AXGrowArea", "AXMatte",
        "AXValueIndicator", "AXToolbar", "AXMenuBar", "AXMenu",
        "AXProgressIndicator", "AXBusyIndicator", "AXUnknown", "AXImage",
        "AXColorWell", "AXColumn", "AXHandle", "AXLayoutArea", "AXLayoutItem",
        "AXLevelIndicator", "AXOutline", "AXRelevanceIndicator",
    ]
    /// Editable text whose value may be a whole document, of which only a part is on screen.
    static let documentRoles: Set<String> = ["AXTextArea", "AXTextField"]
    /// Roles whose frame is a viewport: descendants outside it are scrolled out of view.
    static let viewportRoles: Set<String> = ["AXScrollArea"]
    static let secureSubrole = "AXSecureTextField"

    /// Longer strings are documents or text areas: their frame would not localize a match, so they get no box.
    static let maxBoxedTextLength = 500

    static func acceptsValue(_ s: String) -> Bool { s.count > 1 && !isLikelyMask(s) }
    static func acceptsTitle(_ s: String) -> Bool { s.count > 1 }
    static func acceptsDescription(_ s: String) -> Bool { s.count > 2 && !isLikelyMask(s) }

    /// Bullets or asterisks only, as password fields display.
    static func isLikelyMask(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { maskScalars.contains($0) }
    }
    private static let maskScalars = CharacterSet(charactersIn: "•*●◦◉▪︎")

    /// The part of `text` in `range` (UTF-16), widened to whole characters. Nil when the range is
    /// empty, out of bounds or already the whole text, so callers keep the full value.
    static func visibleSlice(of text: String, range: NSRange) -> String? {
        let ns = text as NSString
        guard range.location >= 0, range.length > 0, range.location < ns.length,
              range.length < ns.length else { return nil }
        let clamped = NSRange(location: range.location, length: min(range.length, ns.length - range.location))
        return ns.substring(with: ns.rangeOfComposedCharacterSequences(for: clamped))
    }

    /// Keeps the first and last `limit / 2` characters when `text` has more than `limit`.
    static func truncatedMiddle(_ text: String, count: Int, limit: Int) -> (text: String, count: Int) {
        guard count > limit else { return (text, count) }
        let half = limit / 2
        let marker = "\n...[truncated]...\n"
        return (String(text.prefix(half)) + marker + String(text.suffix(half)), half * 2 + marker.count)
    }
}
