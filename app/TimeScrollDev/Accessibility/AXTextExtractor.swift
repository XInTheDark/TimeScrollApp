import Foundation
import ApplicationServices
import AppKit
import Cocoa

final class AXTextExtractor {
    static let shared = AXTextExtractor()
    private init() {}
    private let cacheLock = NSLock()
    private var appCache: [pid_t: AXUIElement] = [:]
    private var windowCache: [pid_t: WindowCacheEntry] = [:]

    private struct WindowCacheEntry {
        let windows: [AXUIElement]
        let fetchedAt: TimeInterval
    }

    /// Roles that typically don't contain user-visible text content
    private static let skipRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXRuler", "AXGrowArea", "AXMatte",
        "AXValueIndicator", "AXToolbar", "AXMenuBar", "AXMenu",
        "AXProgressIndicator", "AXBusyIndicator", "AXUnknown", "AXImage",
        "AXColorWell", "AXColumn", "AXHandle", "AXLayoutArea", "AXLayoutItem",
        "AXLevelIndicator", "AXOutline", "AXRelevanceIndicator",
    ]

    /// Max depth for debug logging (to avoid log spam)
    private static let debugLogDepth = 4

    struct Limits {
        let maxWindows: Int          // e.g. 24
        let maxCharsPerWindow: Int   // e.g. 40_000
        let maxTotalChars: Int       // e.g. 200_000
        let maxDepth: Int            // e.g. 12
        let softTimeBudgetMs: Int    // e.g. 120
        let hardTimeBudgetMs: Int    // e.g. 300
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Window info prepared for extraction
    private struct WindowTask {
        let pid: pid_t
        let appAX: AXUIElement
        let targetWin: AXUIElement
    }

    /// Text plus normalized boxes (Vision convention: origin bottom-left, 0...1) for short text
    /// elements that lie on the captured display.
    struct Capture {
        let text: String
        let lines: [OCRLine]
    }

    /// Elements with longer text (documents, text areas) are not boxed: their frame covers the
    /// whole area and would not localize a match.
    private static let maxBoxedTextLength = 500

    /// Returns concatenated text across visible, on-screen windows (filtered by bundle IDs).
    func collectText(blacklistBundleIds: Set<String>,
                     limits: Limits = .default) -> String {
        collect(blacklistBundleIds: blacklistBundleIds, displayBounds: nil, limits: limits).text
    }

    /// Like `collectText`, also returning element boxes relative to `displayBounds`
    /// (global display coordinates, as from `CGDisplayBounds`). Uses parallel extraction.
    func collect(blacklistBundleIds: Set<String>,
                 displayBounds: CGRect?,
                 limits: Limits = .default) -> Capture {
        guard isTrusted() else { return Capture(text: "", lines: []) }

        let debugMode = UserDefaults.standard.bool(forKey: "settings.debugMode")
        let tStart = DispatchTime.now().uptimeMilliseconds

        // 1) Get all on-screen windows in Z-order (front-to-back)
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return Capture(text: "", lines: [])
        }

        let mainScreenArea = NSScreen.main?.frame.area ?? 0
        let minVisibleArea = mainScreenArea * 0.10

        // ========== PHASE 1: Sequential - identify visible windows ==========
        var windowTasks: [WindowTask] = []
        var coveredRects: [CGRect] = []
        let visiblePIDs = Set(infoList.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        purgeCaches(activePIDs: visiblePIDs)

        for entry in infoList {
            if windowTasks.count >= limits.maxWindows { break }

            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.01 { continue }

            if let app = NSRunningApplication(processIdentifier: pid),
               let bid = app.bundleIdentifier, blacklistBundleIds.contains(bid) {
                continue
            }

            // Visibility Check (Monte Carlo)
            let samples = 40
            var visibleSamples = 0
            for _ in 0..<samples {
                let x = CGFloat.random(in: bounds.minX...bounds.maxX)
                let y = CGFloat.random(in: bounds.minY...bounds.maxY)
                let point = CGPoint(x: x, y: y)
                if !coveredRects.contains(where: { $0.contains(point) }) {
                    visibleSamples += 1
                }
            }

            let visibleFraction = Double(visibleSamples) / Double(samples)
            let estimatedVisibleArea = bounds.area * visibleFraction

            if debugMode {
                print("[AX] Win pid=\(pid) bounds=\(bounds) visible=\(String(format: "%.2f", visibleFraction)) area=\(estimatedVisibleArea) min=\(minVisibleArea)")
            }

            coveredRects.append(bounds)

            if estimatedVisibleArea < minVisibleArea {
                if debugMode { print("[AX] Skipping window due to low visibility") }
                continue
            }

            // Set up AX elements
            let appAX = appElement(for: pid, debugMode: debugMode)
            let candidates = windows(for: pid, appAX: appAX)
            guard !candidates.isEmpty else { continue }

            // Find best match by frame
            var bestWin: AXUIElement?
            var bestDist: CGFloat = 50.0

            for w in candidates {
                var posVal: CFTypeRef?
                var sizeVal: CFTypeRef?
                var p = CGPoint.zero
                var s = CGSize.zero

                if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posVal) == .success,
                   AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeVal) == .success {
                    AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
                    AXValueGetValue(sizeVal as! AXValue, .cgSize, &s)

                    let axFrame = CGRect(origin: p, size: s)
                    let dist = abs(axFrame.midX - bounds.midX) + abs(axFrame.midY - bounds.midY) +
                               abs(axFrame.width - bounds.width) + abs(axFrame.height - bounds.height)

                    if dist < bestDist {
                        bestDist = dist
                        bestWin = w
                    }
                }
            }

            if let targetWin = bestWin {
                windowTasks.append(WindowTask(pid: pid, appAX: appAX, targetWin: targetWin))
            }
        }

        if windowTasks.isEmpty { return Capture(text: "", lines: []) }

        // ========== PHASE 2: Parallel - extract text from each window ==========
        let results = UnsafeMutablePointer<String>.allocate(capacity: windowTasks.count)
        results.initialize(repeating: "", count: windowTasks.count)
        let boxResults = UnsafeMutablePointer<[(text: String, frame: CGRect)]>.allocate(capacity: windowTasks.count)
        boxResults.initialize(repeating: [], count: windowTasks.count)
        defer {
            results.deinitialize(count: windowTasks.count)
            results.deallocate()
            boxResults.deinitialize(count: windowTasks.count)
            boxResults.deallocate()
        }
        let collectBoxes = displayBounds != nil

        DispatchQueue.concurrentPerform(iterations: windowTasks.count) { idx in
            let task = windowTasks[idx]
            let windowStart = DispatchTime.now().uptimeMilliseconds
            let hardDeadline = windowStart + limits.hardTimeBudgetMs

            var seenText = Set<String>()
            var textBuf = String()
            var boxes: [(text: String, frame: CGRect)] = []
            let collectLimit = limits.maxCharsPerWindow * 2

            let addText: (String, AXUIElement) -> Void = { s, element in
                if !s.isEmpty && textBuf.count < collectLimit && !seenText.contains(s) {
                    seenText.insert(s)
                    textBuf.append(s)
                    textBuf.append("\n")
                    if collectBoxes, s.count <= Self.maxBoxedTextLength,
                       let frame = self.frame(of: element, startTime: windowStart, limits: limits) {
                        boxes.append((s, frame))
                    }
                }
            }

            // Traverse the window
            self.traverse(task.targetWin,
                          depth: 0,
                          limits: limits,
                          startTime: windowStart,  // Per-window time budget
                          onText: addText)

            // Also traverse focused element
            var focusedRef: CFTypeRef?
            if DispatchTime.now().uptimeMilliseconds < hardDeadline,
               self.setMessagingTimeout(for: task.appAX, startTime: windowStart, limits: limits),
               AXUIElementCopyAttributeValue(task.appAX, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                let focusedElement = focused as! AXUIElement

                var focusedRoleRef: CFTypeRef?
                if self.setMessagingTimeout(for: focusedElement, startTime: windowStart, limits: limits) {
                    _ = AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &focusedRoleRef)
                }
                let focusedRole = focusedRoleRef as? String ?? ""

                if debugMode {
                    print("[AX] [\(idx)] Also traversing focused element (role=\(focusedRole))")
                }

                if DispatchTime.now().uptimeMilliseconds < hardDeadline,
                   focusedRole == kAXTextAreaRole as String || focusedRole == kAXTextFieldRole as String {
                    if let docValue: String = self.getAXAttr(focusedElement,
                                                             kAXValueAttribute as CFString,
                                                             startTime: windowStart,
                                                             limits: limits) {
                        if !docValue.isEmpty && docValue.count > 10 {
                            if debugMode {
                                print("[AX] [\(idx)]   -> document value: \(docValue.count) chars")
                            }
                            addText(docValue, focusedElement)
                        }
                    }
                }

                if DispatchTime.now().uptimeMilliseconds < hardDeadline {
                    self.traverse(focusedElement,
                                  depth: 0,
                                  limits: limits,
                                  startTime: windowStart,
                                  onText: addText)
                }
            }

            // Truncate middle if exceeds limit
            if textBuf.count > limits.maxCharsPerWindow {
                let half = limits.maxCharsPerWindow / 2
                let start = textBuf.prefix(half)
                let end = textBuf.suffix(half)
                textBuf = String(start) + "\n...[truncated]...\n" + String(end)
            }

            let windowMs = DispatchTime.now().uptimeMilliseconds - windowStart
            if debugMode {
                print("[AX] [\(idx)] Window pid=\(task.pid) extracted \(textBuf.count) chars in \(windowMs)ms")
            }

            results[idx] = textBuf
            boxResults[idx] = boxes
        }

        // ========== PHASE 3: Merge results (in Z-order) ==========
        var out = String()
        var totalChars = 0
        for idx in 0..<windowTasks.count {
            let text = results[idx]
            if !text.isEmpty {
                let allow = min(text.count, limits.maxTotalChars - totalChars)
                out.append(contentsOf: text.prefix(allow))
                totalChars += allow
                if totalChars >= limits.maxTotalChars { break }
            }
        }

        var lines: [OCRLine] = []
        if let displayBounds, displayBounds.width > 0, displayBounds.height > 0 {
            for idx in 0..<windowTasks.count {
                for box in boxResults[idx] {
                    let visible = box.frame.intersection(displayBounds)
                    guard !visible.isNull, visible.width > 1, visible.height > 1 else { continue }
                    let normalized = CGRect(x: (visible.minX - displayBounds.minX) / displayBounds.width,
                                            y: 1 - (visible.maxY - displayBounds.minY) / displayBounds.height,
                                            width: visible.width / displayBounds.width,
                                            height: visible.height / displayBounds.height)
                    lines.append(OCRLine(text: box.text, box: normalized))
                }
            }
        }

        let totalMs = DispatchTime.now().uptimeMilliseconds - tStart
        if debugMode {
            print("[AX] Total: \(windowTasks.count) windows, \(totalChars) chars, \(lines.count) boxes in \(totalMs)ms")
        }

        return Capture(text: out, lines: lines)
    }

    /// Global screen frame (top-left origin) of an element, within the time budget.
    private func frame(of element: AXUIElement, startTime: Int, limits: Limits) -> CGRect? {
        guard let positionRef: AnyObject = getAXAttr(element, kAXPositionAttribute as CFString, startTime: startTime, limits: limits),
              let sizeRef: AnyObject = getAXAttr(element, kAXSizeAttribute as CFString, startTime: startTime, limits: limits),
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let position = positionRef as! AXValue
        let size = sizeRef as! AXValue
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func traverse(_ element: AXUIElement,
                          depth: Int,
                          limits: Limits,
                          startTime: Int,
                          onText: (String, AXUIElement) -> Void) {
        if depth > limits.maxDepth { return }

        // Early exit if approaching time budget
        let elapsed = DispatchTime.now().uptimeMilliseconds - startTime
        if elapsed > limits.hardTimeBudgetMs { return }
        if elapsed > limits.softTimeBudgetMs { return }

        // Get role
        var roleRef: CFTypeRef?
        guard setMessagingTimeout(for: element, startTime: startTime, limits: limits) else { return }
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Skip roles known to have no useful text
        if Self.skipRoles.contains(role) { return }

        // Skip secure text fields by subrole
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            var subroleRef: CFTypeRef?
            if setMessagingTimeout(for: element, startTime: startTime, limits: limits) {
                _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            }
            if let sr = subroleRef as? String, sr == "AXSecureTextField" {
                return
            }
        }

        // --- Inclusive text extraction ---
        // Try to extract text from multiple attributes in priority order
        var foundText = false

        let debugMode = UserDefaults.standard.bool(forKey: "settings.debugMode")
        let shouldLog = debugMode && depth <= Self.debugLogDepth
        if shouldLog {
            print("[AX] depth=\(depth) role=\(role)")
        }

        // 1. AXValue - primary text content (text fields, static text, web content, etc.)
        if let v: String = getAXAttr(element,
                                     kAXValueAttribute as CFString,
                                     startTime: startTime,
                                     limits: limits) {
            if !v.isEmpty && !isLikelyMask(v) && v.count > 1 {
                if shouldLog {
                    print("[AX]   -> value: \(v.prefix(100))")
                }
                onText(v, element)
                foundText = true
            }
        }

        // 2. AXTitle - titles and labels (buttons, windows, links, headings)
        if !foundText {
            if let t: String = getAXAttr(element,
                                         kAXTitleAttribute as CFString,
                                         startTime: startTime,
                                         limits: limits) {
                if !t.isEmpty && t.count > 1 {
                    if shouldLog {
                        print("[AX]   -> title: \(t.prefix(100))")
                    }
                    onText(t, element)
                    foundText = true
                }
            }
        }

        // 3. AXDescription - accessible descriptions (for icons, images with alt text)
        if !foundText {
            if let d: String = getAXAttr(element,
                                         kAXDescriptionAttribute as CFString,
                                         startTime: startTime,
                                         limits: limits) {
                if !d.isEmpty && !isLikelyMask(d) && d.count > 2 {
                    if shouldLog {
                        print("[AX]   -> desc: \(d.prefix(100))")
                    }
                    onText(d, element)
                }
            }
        }

        // Recurse children with limit to prevent runaway in deeply nested web content
        var childrenRef: CFTypeRef?
        if setMessagingTimeout(for: element, startTime: startTime, limits: limits),
           AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            if shouldLog {
                print("[AX] depth=\(depth) role=\(role) has \(children.count) children")
            }
            let maxChildren = 64
            for (idx, child) in children.enumerated() {
                if idx >= maxChildren { break }
                traverse(child, depth: depth + 1, limits: limits, startTime: startTime, onText: onText)
            }
        } else if shouldLog {
            print("[AX] depth=\(depth) role=\(role) has NO children or failed to get")
        }
    }

    private func getAXAttr<T>(_ element: AXUIElement,
                              _ attr: CFString,
                              startTime: Int,
                              limits: Limits) -> T? {
        guard setMessagingTimeout(for: element, startTime: startTime, limits: limits) else { return nil }
        var v: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr, &v) == .success {
            return v as? T
        }
        return nil
    }

    private func setMessagingTimeout(for element: AXUIElement,
                                     startTime: Int,
                                     limits: Limits) -> Bool {
        let elapsed = DispatchTime.now().uptimeMilliseconds - startTime
        let remaining = limits.hardTimeBudgetMs - elapsed
        guard remaining > 0 else { return false }
        _ = AXUIElementSetMessagingTimeout(element, Float(remaining) / 1_000)
        return true
    }

    private func isLikelyMask(_ s: String) -> Bool {
        // Very basic detector for •••• or all bullets/asterisks
        if s.isEmpty { return false }
        let set = CharacterSet(charactersIn: "•*•●◦◉▪︎")
        return s.unicodeScalars.allSatisfy { set.contains($0) }
    }
}

private extension DispatchTime {
    var uptimeMilliseconds: Int {
        let nanos = DispatchTime.now().uptimeNanoseconds
        return Int(nanos / 1_000_000)
    }
}

extension AXTextExtractor.Limits {
    static let `default` = AXTextExtractor.Limits(
        maxWindows: 16,
        maxCharsPerWindow: 50_000,
        maxTotalChars: 200_000,
        maxDepth: 48,  // Increased for deeply nested web/Electron content
        softTimeBudgetMs: 200,
        hardTimeBudgetMs: 400
    )
}

extension CGRect {
    var area: CGFloat { width * height }
}

private extension AXTextExtractor {
    func appElement(for pid: pid_t, debugMode: Bool) -> AXUIElement {
        cacheLock.lock()
        if let cached = appCache[pid] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let appAX = AXUIElementCreateApplication(pid)
        // Avoid toggling AXEnhancedUserInterface: it can change other apps' rendering/behavior
        // (for example reduced transparency or altered window-management behavior).
        // AXManualAccessibility is the safer third-party opt-in for Chromium/Electron accessibility trees.
        let manualResult = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if debugMode {
            print("[AX] pid=\(pid) AXManualAccessibility=\(manualResult == .success)")
        }

        cacheLock.lock()
        appCache[pid] = appAX
        cacheLock.unlock()
        return appAX
    }

    func windows(for pid: pid_t, appAX: AXUIElement) -> [AXUIElement] {
        let now = Date().timeIntervalSince1970

        cacheLock.lock()
        if let cached = windowCache[pid], now - cached.fetchedAt <= 10 {
            cacheLock.unlock()
            return cached.windows
        }
        cacheLock.unlock()

        var axWindows: CFTypeRef?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &axWindows) == .success,
           let arr = axWindows as? [AXUIElement] {
            windows = arr
        } else {
            windows = []
        }

        cacheLock.lock()
        windowCache[pid] = WindowCacheEntry(windows: windows, fetchedAt: now)
        cacheLock.unlock()
        return windows
    }

    func purgeCaches(activePIDs: Set<pid_t>) {
        cacheLock.lock()
        appCache = appCache.filter { activePIDs.contains($0.key) }
        windowCache = windowCache.filter { activePIDs.contains($0.key) }
        cacheLock.unlock()
    }
}
