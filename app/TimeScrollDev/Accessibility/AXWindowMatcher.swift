import CoreGraphics

/// Pairs an on-screen CG window with one of its app's Accessibility windows by frame.
enum AXWindowMatcher {
    /// Summed distance of centers and sizes (points) above which frames are different windows.
    static let maxDistance: CGFloat = 50

    /// Index of the frame closest to `target`, or nil when none is within `maxDistance`.
    static func bestMatch(for target: CGRect, among frames: [CGRect?]) -> Int? {
        var best: Int?
        var bestDistance = maxDistance
        for (index, frame) in frames.enumerated() {
            guard let frame else { continue }
            let distance = abs(frame.midX - target.midX) + abs(frame.midY - target.midY)
                + abs(frame.width - target.width) + abs(frame.height - target.height)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
