import AppKit
import ApplicationServices
import Foundation

/// Reads the text of the windows visible on one display over Accessibility ("Direct" mode).
/// Windows are planned from the CG window list without IPC; windows that did not change on screen
/// reuse their cached text; the rest are read in parallel per app (an app answers Accessibility
/// requests one at a time), each window bounded by its own deadline.
final class AXTextExtractor {
    static let shared = AXTextExtractor()
    private init() {}

    /// Text plus normalized boxes (Vision convention: origin bottom-left, 0...1) for short text
    /// elements that lie on the captured display.
    struct Capture {
        let text: String
        let lines: [OCRLine]

        static let empty = Capture(text: "", lines: [])
    }

    private let directory = AXWindowDirectory()
    private let bundleIDs = AXBundleIDCache()
    private let leases = AXManualAccessibilityLeases.shared

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Text of the windows visible on the display at `displayBounds` (global coordinates, as from
    /// `CGDisplayBounds`). `grid` is the luma grid of the frame being indexed; with `cache` (one per
    /// display) it lets unchanged windows skip their Accessibility reads.
    func collect(displayBounds: CGRect,
                 blacklistBundleIds: Set<String>,
                 grid: LumaGridSignature?,
                 cache: AXWindowTextCache,
                 limits: AXTextLimits = .default) -> Capture {
        guard isTrusted() else { return .empty }
        let debug = UserDefaults.standard.bool(forKey: "settings.debugMode")
        let startNanos = AXDeadline.now()
        let now = ProcessInfo.processInfo.systemUptime

        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .empty
        }
        let windows = AXScreenWindow.parse(info)
        let contentPIDs = Set(windows.filter { $0.layer >= 0 && $0.layer < AXWindowPlanner.maxContentLayer }.map(\.pid))
        directory.retain(only: Set(windows.map(\.id)))
        bundleIDs.retain(only: Set(windows.map(\.pid)))
        leases.refresh(onScreen: contentPIDs, now: now)

        let plan = AXWindowPlanner.plan(windows: windows, displayBounds: displayBounds, maxWindows: limits.maxWindows) { pid in
            guard !blacklistBundleIds.isEmpty, let id = self.bundleIDs.bundleID(for: pid) else { return false }
            return blacklistBundleIds.contains(id)
        }
        let reused = cache.reusableText(for: plan, grid: grid, displayBounds: displayBounds, now: now)

        // Windows to read, grouped by app in front-to-back order of each app's frontmost window.
        var appOrder: [pid_t] = []
        var appWindows: [pid_t: [Int]] = [:]
        for (index, planned) in plan.enumerated() where reused[index] == nil {
            let pid = planned.window.pid
            if appWindows[pid] == nil { appOrder.append(pid) }
            appWindows[pid, default: []].append(index)
        }

        let fresh = UnsafeMutableBufferPointer<AXWindowTextCache.Result?>.allocate(capacity: plan.count)
        fresh.initialize(repeating: nil)
        defer {
            _ = fresh.deinitialize()
            fresh.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: appOrder.count) { appIndex in
            let pid = appOrder[appIndex]
            let indices = appWindows[pid] ?? []
            let results = self.readApp(pid: pid, windows: indices.map { plan[$0] }, cache: cache,
                                       limits: limits, now: now, debug: debug)
            for (index, result) in zip(indices, results) { fresh[index] = result }
        }

        let results = plan.indices.map { index in
            fresh[index] ?? AXWindowTextCache.Result(text: reused[index] ?? .empty, documents: [], isFresh: false)
        }
        cache.store(plan: plan, results: results, grid: grid, now: now)
        let capture = AXTextMerger.merge(results.map(\.text), displayBounds: displayBounds, maxTotalChars: limits.maxTotalChars)

        if debug {
            let ms = (AXDeadline.now() - startNanos) / 1_000_000
            let reusedCount = reused.compactMap { $0 }.count
            print("[AX] display=\(displayBounds) windows=\(plan.count) reused=\(reusedCount) apps=\(appOrder.count) chars=\(capture.text.count) boxes=\(capture.lines.count) in \(ms)ms")
        }
        return capture
    }

    /// Reads one app's windows in turn, the focused element first within its window.
    private func readApp(pid: pid_t, windows: [AXPlannedWindow], cache: AXWindowTextCache,
                         limits: AXTextLimits, now: TimeInterval, debug: Bool) -> [AXWindowTextCache.Result] {
        let app = AXUIElementCreateApplication(pid)
        leases.acquire(pid, app: app, now: now, debug: debug)
        let source = AXLiveNodeSource()
        let lookupDeadline = AXDeadline(limits: limits)
        let axWindows = directory.axWindows(for: windows.map(\.window), app: app, source: source,
                                            deadline: lookupDeadline, now: now)
        let focused = focusedElement(of: app, deadline: lookupDeadline)
        let focusedWindow = focused.flatMap { focusedWindowIndex(of: $0, in: windows, source: source, deadline: lookupDeadline) }

        return windows.enumerated().map { index, planned in
            guard let axWindow = axWindows[index] else {
                if debug { print("[AX] pid=\(pid) window=\(planned.window.id) has no Accessibility window") }
                return AXWindowTextCache.Result(text: .empty, documents: [], isFresh: true, isCacheable: false)
            }
            let start = AXDeadline.now()
            let walker = AXTreeWalker(source: source, limits: limits, deadline: AXDeadline(startNanos: start, limits: limits),
                                      visibleRects: planned.visibleRects,
                                      knownDocuments: cache.knownDocuments(for: planned.window.id))
            if index == focusedWindow, let focused {
                walker.walk(focused)
                walker.walk(axWindow, excluding: focused)
            } else {
                walker.walk(axWindow)
            }
            let text = walker.finish()
            if debug {
                let ms = (AXDeadline.now() - start) / 1_000_000
                print("[AX] pid=\(pid) window=\(planned.window.id) elements=\(walker.visitedCount) culled=\(walker.culledCount) chars=\(text.count) in \(ms)ms")
            }
            return AXWindowTextCache.Result(text: text, documents: walker.documents, isFresh: true)
        }
    }

    private func focusedElement(of app: AXUIElement, deadline: AXDeadline) -> AXElementRef? {
        guard let remaining = deadline.remainingSeconds() else { return nil }
        AXUIElementSetMessagingTimeout(app, max(remaining, 0.001))
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return AXElementRef(element: focused as! AXUIElement)
    }

    /// The window holding the focused element: the only one, or the one its frame is visible in.
    private func focusedWindowIndex(of focused: AXElementRef, in windows: [AXPlannedWindow],
                                    source: AXLiveNodeSource, deadline: AXDeadline) -> Int? {
        if windows.count == 1 { return 0 }
        guard let frame = source.frame(focused, deadline: deadline) else { return 0 }
        return windows.firstIndex { $0.visibleRects.contains { $0.intersects(frame) } }
    }
}
