import CoreGraphics
import Foundation

/// Text read per window on one display, reused while neither the window nor anything over it
/// changed on screen (no changed luma-grid cell in its visible parts), so only changed windows are
/// read again over Accessibility.
final class AXWindowTextCache {
    /// Reused text is read again at least this often, in case a change was too small for the grid.
    static let maxReuseAge: TimeInterval = 30

    struct Entry: Equatable {
        let pid: pid_t
        let bounds: CGRect
        let visibleRects: [CGRect]
        let text: AXWindowText
        let readAt: TimeInterval
    }

    /// One window's outcome in an extraction: freshly read, or reused from the cache.
    /// A window that could not be read at all (no Accessibility window found) is not cached.
    struct Result {
        let text: AXWindowText
        let documents: Set<AXElementRef>
        let isFresh: Bool
        var isCacheable = true
    }

    private let lock = NSLock()
    private var grid: LumaGridSignature?
    private var entries: [CGWindowID: Entry] = [:]
    private var documents: [CGWindowID: Set<AXElementRef>] = [:]

    /// Cached text for each planned window that can be reused, nil for those to read again.
    func reusableText(for plan: [AXPlannedWindow], grid newGrid: LumaGridSignature?,
                      displayBounds: CGRect, now: TimeInterval) -> [AXWindowText?] {
        lock.lock()
        defer { lock.unlock() }
        guard let newGrid, let grid, let mask = newGrid.changedCellMask(comparedTo: grid) else {
            return plan.map { _ in nil }
        }
        return plan.map { planned in
            guard let entry = entries[planned.window.id],
                  Self.canReuse(entry, for: planned, changedMask: mask, displayBounds: displayBounds, now: now) else { return nil }
            return entry.text
        }
    }

    /// Long documents found in the window last time it was read.
    func knownDocuments(for id: CGWindowID) -> Set<AXElementRef> {
        lock.lock()
        defer { lock.unlock() }
        return documents[id] ?? []
    }

    /// Replaces the cache with this extraction. Reused windows keep their original read time.
    func store(plan: [AXPlannedWindow], results: [Result], grid newGrid: LumaGridSignature?, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        var nextEntries: [CGWindowID: Entry] = [:]
        var nextDocuments: [CGWindowID: Set<AXElementRef>] = [:]
        for (planned, result) in zip(plan, results) where result.isCacheable {
            let id = planned.window.id
            let readAt = result.isFresh ? now : (entries[id]?.readAt ?? now)
            nextEntries[id] = Entry(pid: planned.window.pid, bounds: planned.window.bounds,
                                    visibleRects: planned.visibleRects, text: result.text, readAt: readAt)
            let docs = result.isFresh ? result.documents : (documents[id] ?? [])
            if !docs.isEmpty { nextDocuments[id] = docs }
        }
        entries = nextEntries
        documents = nextDocuments
        grid = newGrid
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        documents.removeAll()
        grid = nil
    }

    // MARK: - Rules

    static func canReuse(_ entry: Entry, for planned: AXPlannedWindow, changedMask: [Bool],
                         displayBounds: CGRect, now: TimeInterval) -> Bool {
        entry.pid == planned.window.pid
            && entry.bounds == planned.window.bounds
            && entry.visibleRects == planned.visibleRects
            && now - entry.readAt < maxReuseAge
            && now >= entry.readAt
            && !touchesChangedCell(planned.visibleRects, changedMask: changedMask, displayBounds: displayBounds)
    }

    /// Whether any changed grid cell overlaps the rects. The grid spans the display row by row.
    static func touchesChangedCell(_ rects: [CGRect], changedMask: [Bool], displayBounds: CGRect,
                                   columns: Int = LumaGridSignature.columns, rows: Int = LumaGridSignature.rows) -> Bool {
        guard changedMask.count == columns * rows, displayBounds.width > 0, displayBounds.height > 0 else { return true }
        let cellWidth = displayBounds.width / CGFloat(columns)
        let cellHeight = displayBounds.height / CGFloat(rows)
        for rect in rects {
            let local = rect.intersection(displayBounds)
            guard !local.isNull, local.width > 0, local.height > 0 else { continue }
            let firstColumn = max(0, Int(((local.minX - displayBounds.minX) / cellWidth).rounded(.down)))
            let lastColumn = min(columns - 1, Int(((local.maxX - displayBounds.minX) / cellWidth).rounded(.up)) - 1)
            let firstRow = max(0, Int(((local.minY - displayBounds.minY) / cellHeight).rounded(.down)))
            let lastRow = min(rows - 1, Int(((local.maxY - displayBounds.minY) / cellHeight).rounded(.up)) - 1)
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                let base = row * columns
                for column in firstColumn...lastColumn where changedMask[base + column] { return true }
            }
        }
        return false
    }
}
