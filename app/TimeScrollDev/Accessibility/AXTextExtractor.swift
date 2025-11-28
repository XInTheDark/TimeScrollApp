import Foundation
import ApplicationServices
import AppKit
import Cocoa

final class AXTextExtractor {
    static let shared = AXTextExtractor()
    private init() {}

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

    /// Returns concatenated text across visible, on-screen windows (filtered by bundle IDs).
    /// Uses parallel extraction for better performance.
    func collectText(blacklistBundleIds: Set<String>,
                     limits: Limits = .default) -> String {
        guard isTrusted() else { return "" }

        let debugMode = UserDefaults.standard.bool(forKey: "settings.debugMode")
        let tStart = DispatchTime.now().uptimeMilliseconds

        // 1) Get all on-screen windows in Z-order (front-to-back)
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ""
        }

        let mainScreenArea = NSScreen.main?.frame.area ?? 0
        let minVisibleArea = mainScreenArea * 0.10

        // ========== PHASE 1: Sequential - identify visible windows ==========
        var windowTasks: [WindowTask] = []
        var appCache: [pid_t: AXUIElement] = [:]
        var windowCache: [pid_t: [AXUIElement]] = [:]
        var coveredRects: [CGRect] = []

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
            if appCache[pid] == nil {
                let appAX = AXUIElementCreateApplication(pid)
                appCache[pid] = appAX
                let enhancedResult = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                let manualResult = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if debugMode {
                    print("[AX] pid=\(pid) AXEnhancedUserInterface=\(enhancedResult == .success) AXManualAccessibility=\(manualResult == .success)")
                }
            }

            guard let appAX = appCache[pid] else { continue }

            if windowCache[pid] == nil {
                var axWindows: CFTypeRef?
                if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &axWindows) == .success,
                   let arr = axWindows as? [AXUIElement] {
                    windowCache[pid] = arr
                } else {
                    windowCache[pid] = []
                }
            }

            guard let candidates = windowCache[pid] else { continue }

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

        if windowTasks.isEmpty { return "" }

        // ========== PHASE 2: Parallel - extract text from each window ==========
        let results = UnsafeMutablePointer<String>.allocate(capacity: windowTasks.count)
        results.initialize(repeating: "", count: windowTasks.count)
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: windowTasks.count) { idx in
            let task = windowTasks[idx]
            let windowStart = DispatchTime.now().uptimeMilliseconds

            var seenText = Set<String>()
            var textBuf = String()
            let collectLimit = limits.maxCharsPerWindow * 2

            let addText: (String) -> Void = { s in
                if !s.isEmpty && textBuf.count < collectLimit && !seenText.contains(s) {
                    seenText.insert(s)
                    textBuf.append(s)
                    textBuf.append("\n")
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
            if AXUIElementCopyAttributeValue(task.appAX, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                let focusedElement = focused as! AXUIElement

                var focusedRoleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &focusedRoleRef)
                let focusedRole = focusedRoleRef as? String ?? ""

                if debugMode {
                    print("[AX] [\(idx)] Also traversing focused element (role=\(focusedRole))")
                }

                if focusedRole == kAXTextAreaRole as String || focusedRole == kAXTextFieldRole as String {
                    if let docValue: String = self.getAXAttr(focusedElement, kAXValueAttribute as CFString) {
                        if !docValue.isEmpty && docValue.count > 10 {
                            if debugMode {
                                print("[AX] [\(idx)]   -> document value: \(docValue.count) chars")
                            }
                            addText(docValue)
                        }
                    }
                }

                self.traverse(focusedElement,
                              depth: 0,
                              limits: limits,
                              startTime: windowStart,
                              onText: addText)
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

        let totalMs = DispatchTime.now().uptimeMilliseconds - tStart
        if debugMode {
            print("[AX] Total: \(windowTasks.count) windows, \(totalChars) chars in \(totalMs)ms")
        }

        return out
    }

    private func traverse(_ element: AXUIElement,
                          depth: Int,
                          limits: Limits,
                          startTime: Int,
                          onText: (String) -> Void) {
        if depth > limits.maxDepth { return }

        // Early exit if approaching time budget
        let elapsed = DispatchTime.now().uptimeMilliseconds - startTime
        if elapsed > limits.softTimeBudgetMs { return }

        // Get role
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Skip roles known to have no useful text
        if Self.skipRoles.contains(role) { return }

        // Skip secure text fields by subrole
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            var subroleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
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
        if let v: String = getAXAttr(element, kAXValueAttribute as CFString) {
            if !v.isEmpty && !isLikelyMask(v) && v.count > 1 {
                if shouldLog {
                    print("[AX]   -> value: \(v.prefix(100))")
                }
                onText(v)
                foundText = true
            }
        }

        // 2. AXTitle - titles and labels (buttons, windows, links, headings)
        if !foundText {
            if let t: String = getAXAttr(element, kAXTitleAttribute as CFString) {
                if !t.isEmpty && t.count > 1 {
                    if shouldLog {
                        print("[AX]   -> title: \(t.prefix(100))")
                    }
                    onText(t)
                    foundText = true
                }
            }
        }

        // 3. AXDescription - accessible descriptions (for icons, images with alt text)
        if !foundText {
            if let d: String = getAXAttr(element, kAXDescriptionAttribute as CFString) {
                if !d.isEmpty && !isLikelyMask(d) && d.count > 2 {
                    if shouldLog {
                        print("[AX]   -> desc: \(d.prefix(100))")
                    }
                    onText(d)
                }
            }
        }

        // Recurse children with limit to prevent runaway in deeply nested web content
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
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

    private func getAXAttr<T>(_ element: AXUIElement, _ attr: CFString) -> T? {
        var v: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr, &v) == .success {
            return v as? T
        }
        return nil
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
