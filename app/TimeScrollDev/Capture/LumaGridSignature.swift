import CoreVideo

/// Coarse picture of the screen: mean luma over a fixed grid of cells.
/// Unlike a 64-bit dHash built from 72 single pixels, every pixel contributes to some cell,
/// so typing, new messages and scrolling show up as changed cells.
struct LumaGridSignature: Equatable {
    static let columns = 64
    static let rows = 36
    /// Minimum change in a cell's mean luma (0–255) for the cell to count as changed.
    static let cellDeltaThreshold = 3

    let cells: [UInt8]

    /// Builds a signature from the luma plane of an NV12 buffer; nil for other formats.
    init?(pixelBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width >= Self.columns, height >= Self.rows,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let columns = Self.columns
        let rows = Self.rows
        var sums = [UInt32](repeating: 0, count: columns * rows)
        var counts = [UInt32](repeating: 0, count: columns * rows)
        // Sample every other pixel in both directions: 4x cheaper, still covers glyph strokes.
        var y = 0
        while y < height {
            let cellRow = (y * rows / height) * columns
            let row = pixels + y * stride
            var x = 0
            while x < width {
                let cell = cellRow + x * columns / width
                sums[cell] &+= UInt32(row[x])
                counts[cell] &+= 1
                x += 2
            }
            y += 2
        }
        cells = zip(sums, counts).map { sum, count in count > 0 ? UInt8(sum / count) : 0 }
    }

    /// Number of grid cells whose mean luma moved by at least `cellDeltaThreshold`.
    func changedCells(comparedTo other: LumaGridSignature) -> Int {
        guard cells.count == other.cells.count else { return cells.count }
        var changed = 0
        for index in cells.indices where abs(Int(cells[index]) - Int(other.cells[index])) >= Self.cellDeltaThreshold {
            changed += 1
        }
        return changed
    }

    /// Maps the 0–16 "Dedup sensitivity" setting to how many changed cells still count as a duplicate.
    /// The default (6) tolerates one cell, which absorbs a blinking text caret.
    static func toleratedChangedCells(forSensitivity sensitivity: Int) -> Int {
        max(0, sensitivity) / 4
    }
}
