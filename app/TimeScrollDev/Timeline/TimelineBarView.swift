import SwiftUI
import AppKit

struct TimelineBar: NSViewRepresentable {
    @ObservedObject var model: TimelineModel
    let onJump: (Int64) -> Void           // timeMs
    let onHover: (Int64) -> Void          // timeMs
    let onHoverExit: () -> Void

    func makeNSView(context: Context) -> TimelineBarNSView {
        let v = TimelineBarNSView()
        v.model = model
        v.onJump = onJump
        v.onHover = onHover
        v.onHoverExit = onHoverExit
        return v
    }

    func updateNSView(_ nsView: TimelineBarNSView, context: Context) {
        nsView.model = model
        nsView.needsDisplay = true
    }
}

struct TimelineBarContainer: NSViewRepresentable {
    @ObservedObject var model: TimelineModel
    let onJump: (Int64) -> Void
    let onHover: (Int64) -> Void
    let onHoverExit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        let doc = TimelineBarNSView()
        doc.model = model
        doc.onJump = onJump
        doc.onHover = onHover
        doc.onHoverExit = onHoverExit
        scroll.documentView = doc
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let doc = scroll.documentView as? TimelineBarNSView else { return }
        doc.model = model
        let contentWidth = max(scroll.bounds.width, doc.requiredContentWidth())
        doc.setFrameSize(NSSize(width: contentWidth, height: 80))
        doc.needsDisplay = true

        if context.coordinator.shouldScrollToEndIfNeeded {
            Self.scrollToRightEnd(scroll)
            context.coordinator.shouldScrollToEndIfNeeded = false
        }

        // Keep the selected snapshot visible (centered) when selection changes
        if let sel = model.selected {
            if context.coordinator.lastSelectedId != sel.id {
                context.coordinator.lastSelectedId = sel.id
                let xSel = CGFloat(Double(sel.startedAtMs - (model.minTimeMs)) / max(1.0, model.msPerPoint))
                let vis = scroll.contentView.bounds
                let targetX = max(0, min(doc.bounds.width - vis.width, xSel - vis.width/2))
                if abs(targetX - vis.origin.x) > 8 {
                    scroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        } else {
            context.coordinator.lastSelectedId = nil
        }

        // If zoom level changed, re-center around the current snapshot
        if context.coordinator.lastMsPerPoint != model.msPerPoint {
            context.coordinator.lastMsPerPoint = model.msPerPoint
            if let sel = model.selected {
                let xSel = CGFloat(Double(sel.startedAtMs - (model.minTimeMs)) / max(1.0, model.msPerPoint))
                let vis = scroll.contentView.bounds
                let targetX = max(0, min(doc.bounds.width - vis.width, xSel - vis.width/2))
                scroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        // Handle explicit jump-to-end requests
        if context.coordinator.lastJumpToken != model.jumpToEndToken {
            context.coordinator.lastJumpToken = model.jumpToEndToken
            Self.scrollToRightEnd(scroll)
        }
    }

    static func scrollToRightEnd(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView else { return }
        let x = max(0, doc.bounds.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var shouldScrollToEndIfNeeded = true
        var lastSelectedId: Int64? = nil
        var lastJumpToken: Int = 0
        var lastMsPerPoint: Double = .nan
    }
}

final class TimelineBarNSView: NSView {
    weak var model: TimelineModel?
    var onJump: ((Int64) -> Void)?
    var onHover: ((Int64) -> Void)?
    var onHoverExit: (() -> Void)?

    private var tracking: NSTrackingArea?
    private let popover = NSPopover()
    private var lastPreviewIndex: Int? = nil
    private var hoverThrottle: Date = .distantPast
    private var loadingTimer: DispatchWorkItem?
    private var isLoadingPreview: Bool = true
    private var previewDebounce: DispatchWorkItem?
    private var pendingPreviewIndex: Int? = nil
    private var previewViewModel = HoverPreviewViewModel()

    override var isFlipped: Bool { true }

    func requiredContentWidth() -> CGFloat {
        guard let m = model else { return bounds.width }
        let span = max(1, Double(max(0, m.maxTimeMs - m.minTimeMs)))
        return CGFloat(span / max(1.0, m.msPerPoint)) + 200 // padding
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let m = model else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        drawTicks(model: m, in: bounds)
        drawSegments(model: m, in: bounds)
        drawSelection(model: m, in: bounds)
    }

    private func drawSegments(model m: TimelineModel, in rect: NSRect) {
        let h: CGFloat = 20
        let y: CGFloat = rect.midY - h/2 + 8
        for seg in m.segments {
            let x0 = x(for: seg.startMs, m: m)
            let x1 = x(for: seg.endMs, m: m)
            let w = max(1, x1 - x0)
            let r = NSRect(x: x0, y: y, width: w, height: h)
            AppColor.color(for: seg.appBundleId).setFill()
            r.fill()
        }
    }

    private func drawSelection(model m: TimelineModel, in rect: NSRect) {
        guard let s = m.selected else { return }
        let xSel = x(for: s.startedAtMs, m: m)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xSel, y: rect.minY))
        path.line(to: NSPoint(x: xSel, y: rect.maxY))
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawTicks(model m: TimelineModel, in rect: NSRect) {
        let majorStep = pickMajorTickStep(msPerPoint: m.msPerPoint)
        let minorStep = majorStep / 5
        let start = m.minTimeMs
        let end = m.maxTimeMs
        let labelStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let yTop = rect.minY + 8
        let tickHeightMajor: CGFloat = 8
        let tickHeightMinor: CGFloat = 4
        // First major aligned to step
        if end <= start { return }
        let firstMajor = ((start / majorStep) + 1) * majorStep
        var t = firstMajor
        let df = TimelineBarNSView.timeFormatter
        while t < end {
            let xPos = x(for: t, m: m)
            // Major tick
            NSColor.separatorColor.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: xPos, y: yTop))
            p.line(to: NSPoint(x: xPos, y: yTop + tickHeightMajor))
            p.lineWidth = 1
            p.stroke()
            // Label
            let date = Date(timeIntervalSince1970: TimeInterval(t)/1000)
            let str = df.string(from: date) as NSString
            let size = str.size(withAttributes: labelStyle)
            str.draw(at: NSPoint(x: xPos - size.width/2, y: yTop + tickHeightMajor + 2), withAttributes: labelStyle)
            // Minor ticks between this and next major
            var mt = t + minorStep
            let nextMajor = t + majorStep
            while mt < min(nextMajor, end) {
                let mx = x(for: mt, m: m)
                NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
                let mp = NSBezierPath()
                mp.move(to: NSPoint(x: mx, y: yTop))
                mp.line(to: NSPoint(x: mx, y: yTop + tickHeightMinor))
                mp.lineWidth = 1
                mp.stroke()
                mt += minorStep
            }
            t += majorStep
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func pickMajorTickStep(msPerPoint: Double) -> Int64 {
        // Ensure ~>=80 px between major ticks
        let pxTarget: Double = 80
        let targetMs = max(1, msPerPoint * pxTarget)
        let candidates: [Int64] = [60_000, 5*60_000, 10*60_000, 30*60_000, 3_600_000, 2*3_600_000, 6*3_600_000, 12*3_600_000, 86_400_000]
        for c in candidates {
            if Double(c) >= targetMs { return c }
        }
        return candidates.last ?? 3_600_000
    }

    private func x(for timeMs: Int64, m: TimelineModel) -> CGFloat {
        let dt = Double(timeMs - m.minTimeMs)
        return CGFloat(dt / max(1.0, m.msPerPoint))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        tracking = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let m = model else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = timeAt(x: p.x, m: m)
        onHover?(t)

        // Throttle popover repositioning
        let now = Date()
        let shouldReposition = now.timeIntervalSince(hoverThrottle) >= 0.05

        if let idx = m.indexNearest(to: t), m.metas.indices.contains(idx) {
            // Show or reposition popover at mouse location
            if !popover.isShown {
                showPopover(at: p)
                hoverThrottle = now
            } else if shouldReposition {
                popover.performClose(nil)
                showPopover(at: p)
                hoverThrottle = now
            }

            // Debounce switching to new preview index
            if pendingPreviewIndex != idx {
                pendingPreviewIndex = idx
                previewDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    guard self.pendingPreviewIndex == idx else { return }
                    self.lastPreviewIndex = idx
                    self.loadPreview(for: idx)
                }
                previewDebounce = work
                // If this is the first preview, show immediately; otherwise debounce
                let delay: Double = lastPreviewIndex == nil ? 0 : 0.12
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        } else {
            previewDebounce?.cancel()
            popover.performClose(nil)
            lastPreviewIndex = nil
            pendingPreviewIndex = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHoverExit?()
        popover.performClose(nil)
        lastPreviewIndex = nil
        pendingPreviewIndex = nil
        loadingTimer?.cancel()
        loadingTimer = nil
        previewDebounce?.cancel()
        previewDebounce = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let m = model else { return }
        let p = convert(event.locationInWindow, from: nil)
        onJump?(timeAt(x: p.x, m: m))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = model else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = timeAt(x: p.x, m: m)
        let menu = NSMenu()
        let jump = NSMenuItem(title: "Jump to here", action: #selector(ctxJump(_:)), keyEquivalent: "")
        jump.representedObject = t
        jump.target = self
        menu.addItem(jump)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func ctxJump(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? Int64 { onJump?(t) }
    }

    private func timeAt(x: CGFloat, m: TimelineModel) -> Int64 {
        let offsetMs = Int64(Double(x) * max(1.0, m.msPerPoint))
        return m.minTimeMs + offsetMs
    }

    private func showPopover(at point: NSPoint) {
        let content = HoverPreviewView(viewModel: previewViewModel)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 220)
        if popover.contentViewController == nil { popover.contentViewController = NSViewController() }
        popover.contentViewController?.view = host
        popover.behavior = .transient
        popover.animates = false
        let clampedX = max(0, min(bounds.width - 1, point.x))
        let anchor = NSRect(x: clampedX, y: 0, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    private func loadPreview(for index: Int) {
        guard let m = model else { return }
        let meta = m.metas[index]
        let url = URL(fileURLWithPath: meta.path)
        let ext = url.pathExtension.lowercased()

        // Cancel any pending loading timer
        loadingTimer?.cancel()
        loadingTimer = nil

        // Update metadata immediately with fade
        let appIcon: NSImage? = meta.appBundleId.flatMap { AppIconCache.shared.icon(for: $0) }
        let date = Date(timeIntervalSince1970: TimeInterval(meta.startedAtMs)/1000)
        previewViewModel.update(
            thumbnail: nil,
            appIcon: appIcon,
            appName: meta.appName ?? (meta.appBundleId ?? "Unknown"),
            date: date,
            isLoading: true
        )

        // After 500ms, if still no image, show "No preview"
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.lastPreviewIndex == index else { return }
            self.previewViewModel.setLoading(false)
        }
        loadingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timer)

        func loadMainImage() {
            ThumbnailCache.shared.thumbnailAsync(for: url, maxPixel: 220) { [weak self] img in
                guard let self = self, self.lastPreviewIndex == index else { return }
                self.loadingTimer?.cancel()
                self.previewViewModel.setThumbnail(img)
            }
        }

        func loadVideoFrame() {
            ThumbnailCache.shared.hevcThumbnail(for: url, startedAtMs: meta.startedAtMs, maxPixel: 220) { [weak self] img in
                guard let self = self, self.lastPreviewIndex == index else { return }
                if let img = img {
                    self.loadingTimer?.cancel()
                    self.previewViewModel.setThumbnail(img)
                } else {
                    loadMainImage()
                }
            }
        }

        // Prefer poster thumbnail
        if let t = meta.thumbPath {
            ThumbnailCache.shared.thumbnailAsync(for: URL(fileURLWithPath: t), maxPixel: 220) { [weak self] img in
                guard let self = self, self.lastPreviewIndex == index else { return }
                if let img = img {
                    self.loadingTimer?.cancel()
                    self.previewViewModel.setThumbnail(img)
                } else if ["mov","mp4","tse"].contains(ext) {
                    loadVideoFrame()
                } else {
                    loadMainImage()
                }
            }
            return
        }

        // Video: use HEVC extractor
        if ["mov","mp4","tse"].contains(ext) {
            loadVideoFrame()
            return
        }

        // Image: use async thumbnail
        loadMainImage()
    }
}

private class HoverPreviewViewModel: ObservableObject {
    @Published var thumbnail: NSImage? = nil
    @Published var appIcon: NSImage? = nil
    @Published var appName: String = ""
    @Published var date: Date = Date()
    @Published var isLoading: Bool = true

    func update(thumbnail: NSImage?, appIcon: NSImage?, appName: String, date: Date, isLoading: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            self.thumbnail = thumbnail
            self.appIcon = appIcon
            self.appName = appName
            self.date = date
            self.isLoading = isLoading
        }
    }

    func setThumbnail(_ img: NSImage?) {
        withAnimation(.easeInOut(duration: 0.15)) {
            self.thumbnail = img
            self.isLoading = false
        }
    }

    func setLoading(_ loading: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            self.isLoading = loading
        }
    }
}

private struct HoverPreviewView: View {
    @ObservedObject var viewModel: HoverPreviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(width: 240, height: 160)
                    .cornerRadius(6)

                if let img = viewModel.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 160)
                        .cornerRadius(6)
                } else if !viewModel.isLoading {
                    Text("No preview").foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                if let icon = viewModel.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16).cornerRadius(3)
                }
                Text(viewModel.appName).font(.caption)
                Spacer()
                Text(Self.df.string(from: viewModel.date)).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
