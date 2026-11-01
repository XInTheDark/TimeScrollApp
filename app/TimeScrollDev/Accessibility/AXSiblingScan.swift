import CoreGraphics

/// Finds where the visible part of a long run of siblings starts (chat histories, lists, web pages),
/// so the walker reads what is on screen instead of every off-screen sibling.
enum AXSiblingScan {
    /// Child counts above this are scanned from the first visible sibling instead of from the start.
    static let largeChildCount = 64
    /// After this many consecutive siblings below the viewport, the rest are below it too.
    static let belowRunToStop = 8

    /// True when the first, middle and last siblings with frames are laid out top to bottom.
    static func isTopToBottom(count: Int, frameAt: (Int) -> CGRect?) -> Bool {
        guard count >= 3, let first = frameAt(0), let middle = frameAt(count / 2), let last = frameAt(count - 1) else { return false }
        return first.minY <= middle.minY && middle.minY <= last.minY && first.minY < last.minY
    }

    /// Index of the first sibling that reaches down to `top`, by binary search over siblings laid
    /// out top to bottom. A sibling without a frame ends the search at 0 so nothing is skipped.
    static func firstReaching(top: CGFloat, count: Int, frameAt: (Int) -> CGRect?) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            guard let frame = frameAt(mid) else { return 0 }
            if frame.maxY < top { low = mid + 1 } else { high = mid }
        }
        // Start one early: a sibling straddling the edge may sort just before it.
        return max(0, low - 1)
    }
}
