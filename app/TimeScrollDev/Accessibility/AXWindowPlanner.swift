import CoreGraphics

/// One entry of `CGWindowListCopyWindowInfo`, in global display coordinates (top-left origin).
struct AXScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    /// Parses a window list, keeping its front-to-back order and dropping malformed entries.
    static func parse(_ info: [[String: Any]]) -> [AXScreenWindow] {
        info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            return AXScreenWindow(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }
}

/// A window worth reading, with the parts of it that are visible on the captured display.
struct AXPlannedWindow: Equatable {
    let window: AXScreenWindow
    /// Disjoint uncovered pieces of the window on the display (global, top-left origin).
    let visibleRects: [CGRect]
}

/// Picks the windows whose text is visible on one display, front to back.
enum AXWindowPlanner {
    /// Windows from the Dock level (20) up are system chrome, menus and overlays: never read, never occluding.
    static let maxContentLayer = 20
    /// A window is read only if this much of the display shows it.
    static let minVisibleDisplayFraction: CGFloat = 0.10
    /// Below this alpha a window is invisible; below `opaqueAlpha` it does not hide what is under it.
    static let invisibleAlpha = 0.01
    static let opaqueAlpha = 0.95

    static func plan(windows: [AXScreenWindow],
                     displayBounds: CGRect,
                     maxWindows: Int,
                     isExcluded: (pid_t) -> Bool) -> [AXPlannedWindow] {
        guard displayBounds.width > 0, displayBounds.height > 0, maxWindows > 0 else { return [] }
        let minVisibleArea = displayBounds.width * displayBounds.height * minVisibleDisplayFraction
        var planned: [AXPlannedWindow] = []
        var occluders: [CGRect] = []

        for window in windows {
            if planned.count >= maxWindows { break }
            guard window.layer >= 0, window.layer < maxContentLayer, window.alpha >= invisibleAlpha else { continue }
            let onDisplay = window.bounds.intersection(displayBounds)
            guard !onDisplay.isNull, onDisplay.width > 0, onDisplay.height > 0 else { continue }

            if !isExcluded(window.pid) {
                let visible = RectSubtraction.uncovered(onDisplay, by: occluders, minArea: minVisibleArea)
                if RectSubtraction.area(visible) >= minVisibleArea {
                    planned.append(AXPlannedWindow(window: window, visibleRects: visible))
                }
            }
            // Excluded windows still hide what is under them.
            if window.alpha >= opaqueAlpha { occluders.append(onDisplay) }
        }
        return planned
    }
}
