import CoreGraphics

/// Exact visible parts of a rectangle once the rectangles above it are removed.
enum RectSubtraction {
    /// Disjoint pieces of `rect` that no occluder covers. Past `maxPieces` the remaining occluders
    /// are ignored, so a pathological window stack overestimates visibility instead of costing more.
    /// Returns no pieces as soon as less than `minArea` remains, since the caller would discard them.
    static func uncovered(_ rect: CGRect, by occluders: [CGRect], maxPieces: Int = 64, minArea: CGFloat = 0) -> [CGRect] {
        guard !rect.isNull, rect.width > 0, rect.height > 0, rect.width * rect.height >= minArea else { return [] }
        var pieces = [rect]
        for occluder in occluders where occluder.intersects(rect) {
            var next: [CGRect] = []
            next.reserveCapacity(pieces.count + 3)
            var changed = false
            for piece in pieces {
                if piece.intersects(occluder) {
                    next.append(contentsOf: subtract(occluder, from: piece))
                    changed = true
                } else {
                    next.append(piece)
                }
            }
            guard changed else { continue }
            pieces = next
            if minArea > 0, area(pieces) < minArea { return [] }
            if pieces.isEmpty || pieces.count > maxPieces { break }
        }
        return pieces
    }

    /// Up to four pieces of `rect` outside `hole`: full-width bands above and below, then the sides.
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        var pieces: [CGRect] = []
        if cut.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY))
        }
        if cut.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY))
        }
        if cut.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height))
        }
        if cut.maxX < rect.maxX {
            pieces.append(CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height))
        }
        return pieces
    }

    /// Total area of disjoint pieces.
    static func area(_ pieces: [CGRect]) -> CGFloat {
        pieces.reduce(0) { $0 + $1.width * $1.height }
    }
}
