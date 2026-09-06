import SwiftUI
import AppKit

struct TimelineBar: NSViewRepresentable {
    @ObservedObject var model: TimelineModel
    let isCompressed: Bool
    let visibleCaptureKinds: Set<CaptureKind>
    let onJump: (Int64, CaptureKind?) -> Void
    let onHover: (Int64) -> Void          // timeMs
    let onHoverExit: () -> Void

    func makeNSView(context: Context) -> TimelineBarNSView {
        let v = TimelineBarNSView()
        v.model = model
        v.isCompressed = isCompressed
        v.visibleCaptureKinds = visibleCaptureKinds
        v.refreshLayout()
        v.onJump = onJump
        v.onHover = onHover
        v.onHoverExit = onHoverExit
        return v
    }

    func updateNSView(_ nsView: TimelineBarNSView, context: Context) {
        nsView.model = model
        nsView.isCompressed = isCompressed
        nsView.visibleCaptureKinds = visibleCaptureKinds
        nsView.refreshLayout()
        nsView.needsDisplay = true
    }
}

struct TimelineBarContainer: NSViewRepresentable {
    @ObservedObject var model: TimelineModel
    let isCompressed: Bool
    let invertScrollDirection: Bool
    let visibleCaptureKinds: Set<CaptureKind>
    let onJump: (Int64, CaptureKind?) -> Void
    let onHover: (Int64) -> Void
    let onHoverExit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineBarScrollView()
        scroll.invertScrollDirection = invertScrollDirection
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        let doc = TimelineBarNSView()
        doc.model = model
        doc.isCompressed = isCompressed
        doc.visibleCaptureKinds = visibleCaptureKinds
        doc.refreshLayout()
        doc.onJump = onJump
        doc.onHover = onHover
        doc.onHoverExit = onHoverExit
        doc.setFrameSize(NSSize(width: max(600, doc.requiredContentWidth()), height: timelineContentHeight(for: scroll.bounds.height)))
        scroll.documentView = doc
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let doc = scroll.documentView as? TimelineBarNSView else { return }
        (scroll as? TimelineBarScrollView)?.invertScrollDirection = invertScrollDirection
        doc.model = model
        doc.isCompressed = isCompressed
        doc.visibleCaptureKinds = visibleCaptureKinds
        doc.refreshLayout()
        let contentWidth = max(scroll.bounds.width, doc.requiredContentWidth())
        doc.setFrameSize(NSSize(width: contentWidth, height: timelineContentHeight(for: scroll.bounds.height)))
        doc.needsDisplay = true
        let compressionChanged = context.coordinator.lastCompressedState != isCompressed
        context.coordinator.lastCompressedState = isCompressed

        if context.coordinator.shouldScrollToEndIfNeeded {
            Self.scrollToRightEnd(scroll)
            context.coordinator.shouldScrollToEndIfNeeded = false
        }

        // Keep the selected snapshot visible (centered) when selection changes
        if let sel = model.selected {
            if context.coordinator.lastSelectedId != sel.id {
                context.coordinator.lastSelectedId = sel.id
                let xSel = doc.timelineX(for: sel.startedAtMs)
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
        if context.coordinator.lastMsPerPoint != model.msPerPoint || compressionChanged {
            context.coordinator.lastMsPerPoint = model.msPerPoint
            if let sel = model.selected {
                let xSel = doc.timelineX(for: sel.startedAtMs)
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

    private func timelineContentHeight(for viewportHeight: CGFloat) -> CGFloat {
        let baseHeight: CGFloat = visibleCaptureKinds.contains(.screen) && visibleCaptureKinds.contains(.audio) ? 92 : 80
        return max(viewportHeight, baseHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var shouldScrollToEndIfNeeded = true
        var lastSelectedId: Int64? = nil
        var lastJumpToken: Int = 0
        var lastMsPerPoint: Double = .nan
        var lastCompressedState: Bool? = nil
    }
}

final class TimelineBarScrollView: NSScrollView {
    var invertScrollDirection: Bool = false

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let horizontalDelta = effectiveHorizontalDelta(for: event)
        guard abs(horizontalDelta) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = contentView
        let visibleWidth = clipView.bounds.width
        let maxX = max(0, documentView.bounds.width - visibleWidth)
        guard maxX > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let currentX = clipView.bounds.origin.x
        let targetX = min(max(0, currentX + horizontalDelta), maxX)
        guard abs(targetX - currentX) > 0.01 else { return }

        clipView.scroll(to: NSPoint(x: targetX, y: 0))
        reflectScrolledClipView(clipView)
    }

    private func effectiveHorizontalDelta(for event: NSEvent) -> CGFloat {
        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        let resolvedDelta: CGFloat

        if abs(horizontalDelta) > max(0.01, abs(verticalDelta)) {
            resolvedDelta = horizontalDelta
        } else {
            guard abs(verticalDelta) > 0.01 else { return horizontalDelta }

            let isDirectionInverted =
                event.isDirectionInvertedFromDevice ||
                Self.shouldFallbackToGlobalScrollDirection(for: event)
            let physicalVerticalDelta = isDirectionInverted ? -verticalDelta : verticalDelta
            resolvedDelta = -physicalVerticalDelta
        }

        return invertScrollDirection ? -resolvedDelta : resolvedDelta
    }

    private static func shouldFallbackToGlobalScrollDirection(for event: NSEvent) -> Bool {
        guard !event.hasPreciseScrollingDeltas, !event.isDirectionInvertedFromDevice else {
            return false
        }

        guard let domain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) else {
            return false
        }

        if let boolValue = domain["com.apple.swipescrolldirection"] as? Bool {
            return boolValue
        }
        if let numberValue = domain["com.apple.swipescrolldirection"] as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }
}

@MainActor
private struct TimelineAxisLayout {
    static let trailingPadding: CGFloat = 200
    static let compressedGapWidth: CGFloat = 18
    static let empty = TimelineAxisLayout(timesAsc: [], positionsAsc: [], contentWidth: trailingPadding, isCompressed: true, msPerPoint: 1)

    let timesAsc: [Int64]
    let positionsAsc: [CGFloat]
    let contentWidth: CGFloat
    let isCompressed: Bool
    let msPerPoint: Double

    init(model: TimelineModel?, isCompressed: Bool) {
        guard let model else {
            self = .empty
            return
        }

        let timesAsc = model.metas.map(\.startedAtMs).sorted()
        let msPerPoint = max(1.0, model.msPerPoint)
        let positions = Self.makePositions(timesAsc: timesAsc, isCompressed: isCompressed, msPerPoint: msPerPoint)
        self.init(timesAsc: timesAsc,
                  positionsAsc: positions,
                  contentWidth: (positions.last ?? 0) + Self.trailingPadding,
                  isCompressed: isCompressed,
                  msPerPoint: msPerPoint)
    }

    private init(timesAsc: [Int64], positionsAsc: [CGFloat], contentWidth: CGFloat, isCompressed: Bool, msPerPoint: Double) {
        self.timesAsc = timesAsc
        self.positionsAsc = positionsAsc
        self.contentWidth = contentWidth
        self.isCompressed = isCompressed
        self.msPerPoint = msPerPoint
    }

    func x(for timeMs: Int64) -> CGFloat {
        guard !timesAsc.isEmpty else { return 0 }
        guard timesAsc.count > 1 else { return 0 }
        guard isCompressed else {
            return CGFloat(Double(max(0, timeMs - timesAsc[0])) / msPerPoint)
        }

        if timeMs <= timesAsc[0] { return positionsAsc[0] }
        if let lastTime = timesAsc.last, timeMs >= lastTime {
            return positionsAsc.last ?? 0
        }

        let upperIndex = Self.firstIndex(in: timesAsc, atOrAfter: timeMs)
        if timesAsc[upperIndex] == timeMs { return positionsAsc[upperIndex] }
        let lowerIndex = max(0, upperIndex - 1)
        let startTime = timesAsc[lowerIndex]
        let endTime = timesAsc[upperIndex]
        let timeSpan = max(1, endTime - startTime)
        let fraction = CGFloat(Double(timeMs - startTime) / Double(timeSpan))
        return positionsAsc[lowerIndex] + (positionsAsc[upperIndex] - positionsAsc[lowerIndex]) * fraction
    }

    func time(atX x: CGFloat) -> Int64 {
        guard !timesAsc.isEmpty else { return 0 }
        guard positionsAsc.count > 1 else { return timesAsc[0] }
        let maxX = positionsAsc.last ?? 0
        let clampedX = min(max(0, x), maxX)

        guard isCompressed else {
            return timesAsc[0] + Int64((Double(clampedX) * msPerPoint).rounded())
        }

        if clampedX <= positionsAsc[0] { return timesAsc[0] }
        if clampedX >= maxX { return timesAsc.last ?? timesAsc[0] }

        let upperIndex = Self.firstIndex(in: positionsAsc, atOrAfter: clampedX)
        if positionsAsc[upperIndex] == clampedX { return timesAsc[upperIndex] }
        let lowerIndex = max(0, upperIndex - 1)
        let startX = positionsAsc[lowerIndex]
        let endX = positionsAsc[upperIndex]
        let spanX = max(1, endX - startX)
        let fraction = Double((clampedX - startX) / spanX)
        let deltaTime = Double(timesAsc[upperIndex] - timesAsc[lowerIndex]) * fraction
        return timesAsc[lowerIndex] + Int64(deltaTime.rounded())
    }

    private static func makePositions(timesAsc: [Int64], isCompressed: Bool, msPerPoint: Double) -> [CGFloat] {
        guard !timesAsc.isEmpty else { return [] }
        guard isCompressed else {
            let origin = timesAsc[0]
            return timesAsc.map { CGFloat(Double(max(0, $0 - origin)) / msPerPoint) }
        }

        var positions: [CGFloat] = [0]
        guard timesAsc.count > 1 else { return positions }

        for i in 1..<timesAsc.count {
            let gapMs = max(0, timesAsc[i] - timesAsc[i - 1])
            let linearWidth = CGFloat(Double(gapMs) / msPerPoint)
            positions.append((positions.last ?? 0) + min(linearWidth, compressedGapWidth))
        }
        return positions
    }

    private static func firstIndex(in values: [Int64], atOrAfter target: Int64) -> Int {
        var low = 0
        var high = values.count - 1
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func firstIndex(in values: [CGFloat], atOrAfter target: CGFloat) -> Int {
        var low = 0
        var high = values.count - 1
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private struct TimelineTrackLayout {
    let screenRect: NSRect?
    let audioRect: NSRect?

    init(in bounds: NSRect, visibleCaptureKinds: Set<CaptureKind>) {
        let topInset: CGFloat = 34
        let bottomInset: CGFloat = 12
        let hasScreen = visibleCaptureKinds.contains(.screen)
        let hasAudio = visibleCaptureKinds.contains(.audio)
        let usableHeight = max(24, bounds.height - topInset - bottomInset)
        let rowSpacing: CGFloat = hasScreen && hasAudio ? 8 : 0
        let screenHeight: CGFloat = {
            guard hasScreen else { return 0 }
            if hasAudio {
                return min(28, max(20, usableHeight * 0.38))
            }
            return min(30, max(22, usableHeight * 0.58))
        }()
        let audioHeight: CGFloat = {
            guard hasAudio else { return 0 }
            if hasScreen {
                return min(24, max(16, screenHeight * 0.8))
            }
            return min(24, max(16, usableHeight * 0.42))
        }()
        let totalHeight =
            (hasScreen ? screenHeight : 0)
            + (hasAudio ? audioHeight : 0)
            + rowSpacing
        let availableHeight = max(totalHeight, bounds.height - topInset - bottomInset)
        var currentY = topInset + max(0, (availableHeight - totalHeight) / 2)

        if hasScreen {
            screenRect = NSRect(x: bounds.minX, y: currentY, width: bounds.width, height: screenHeight)
            currentY += screenHeight + rowSpacing
        } else {
            screenRect = nil
        }

        if hasAudio {
            audioRect = NSRect(x: bounds.minX, y: currentY, width: bounds.width, height: audioHeight)
        } else {
            audioRect = nil
        }
    }

    func preferredCaptureKind(at point: NSPoint) -> CaptureKind? {
        if let screenRect, screenRect.insetBy(dx: 0, dy: -6).contains(point) {
            return .screen
        }
        if let audioRect, audioRect.insetBy(dx: 0, dy: -6).contains(point) {
            return .audio
        }

        let distances: [(CaptureKind, CGFloat)] = [
            screenRect.map { (.screen, abs($0.midY - point.y)) },
            audioRect.map { (.audio, abs($0.midY - point.y)) }
        ].compactMap { $0 }

        return distances.min(by: { $0.1 < $1.1 })?.0
    }
}

private struct MergedAudioDisplaySpan {
    let sourceKind: AudioSourceKind?
    let startMs: Int64
    var endMs: Int64
    var items: [SnapshotMeta]
}

private final class TimelineJumpTarget {
    let timeMs: Int64
    let preferredCaptureKind: CaptureKind?

    init(timeMs: Int64, preferredCaptureKind: CaptureKind?) {
        self.timeMs = timeMs
        self.preferredCaptureKind = preferredCaptureKind
    }
}

@MainActor
final class TimelineBarNSView: NSView {
    weak var model: TimelineModel?
    var isCompressed: Bool = true
    var visibleCaptureKinds: Set<CaptureKind> = Set(CaptureKind.allCases)
    var onJump: ((Int64, CaptureKind?) -> Void)?
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
    private var layout = TimelineAxisLayout.empty
    private weak var layoutModel: TimelineModel?
    private var layoutRevision: UInt64?
    private var audioSpans: [MergedAudioDisplaySpan] = []
    private var isDraggingTimeline = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func requiredContentWidth() -> CGFloat {
        layout.contentWidth
    }

    func refreshLayout() {
        if layoutModel === model,
           layoutRevision == model?.dataRevision,
           layout.isCompressed == isCompressed,
           layout.msPerPoint == max(1, model?.msPerPoint ?? 1) { return }
        if layoutModel !== model || layoutRevision != model?.dataRevision {
            audioSpans = model.map { model in
                mergeAudioDisplaySpans(from: model.metas.filter { $0.captureKind == .audio }
                    .sorted { $0.startedAtMs < $1.startedAtMs }, model: model)
            } ?? []
        }
        layout = TimelineAxisLayout(model: model, isCompressed: isCompressed)
        layoutModel = model
        layoutRevision = model?.dataRevision
    }

    func timelineX(for timeMs: Int64) -> CGFloat {
        layout.x(for: timeMs)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let m = model else { return }
        refreshLayout()
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        drawTicks(model: m, in: bounds)
        drawSegments(model: m, in: bounds)
        drawSelection(model: m, in: bounds)
        drawPlaybackCursor(model: m, in: bounds)
    }

    private func drawSegments(model m: TimelineModel, in rect: NSRect) {
        let trackLayout = TimelineTrackLayout(in: rect, visibleCaptureKinds: visibleCaptureKinds)
        if let audioRect = trackLayout.audioRect, visibleCaptureKinds.contains(.audio) {
            drawAudioSegments(model: m, in: audioRect)
        }

        for seg in m.segments where seg.captureKind == .screen && visibleCaptureKinds.contains(.screen) {
            guard let row = trackLayout.screenRect else { continue }
            let x0 = timelineX(for: seg.startMs)
            let x1 = timelineX(for: seg.endMs)
            let w = max(1, x1 - x0)
            let r = NSRect(x: x0, y: row.minY, width: w, height: row.height)
            guard needsToDraw(r.insetBy(dx: -1, dy: -1)) else { continue }
            let segmentPath = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            segmentColor(for: seg).setFill()
            segmentPath.fill()
            NSColor.separatorColor.withAlphaComponent(0.16).setStroke()
            segmentPath.lineWidth = 1
            segmentPath.stroke()

            guard w >= 18 else {
                continue
            }

            if let bundleId = seg.appBundleId,
               AppIconCache.shared.cachedIcon(for: bundleId) == nil {
                AppIconCache.shared.loadIconAsync(for: bundleId) { [weak self] _ in
                    self?.needsDisplay = true
                }
            }

            guard let icon = segmentIcon(for: seg) else {
                continue
            }

            let iconSize = min(row.height - 6, 14)
            guard iconSize > 0 else { continue }
            let iconX = min(r.maxX - iconSize - 3, r.minX + 4)
            guard iconX >= r.minX + 2 else { continue }

            let backgroundRect = NSRect(x: iconX - 1.5,
                                        y: r.midY - iconSize/2 - 1.5,
                                        width: iconSize + 3,
                                        height: iconSize + 3)
            let iconRect = NSRect(x: iconX,
                                  y: r.midY - iconSize / 2,
                                  width: iconSize,
                                  height: iconSize)
            NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: backgroundRect, xRadius: 4, yRadius: 4).fill()
            icon.draw(in: iconRect,
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 0.96,
                      respectFlipped: true,
                      hints: nil)
        }
    }

    private func drawSelection(model m: TimelineModel, in rect: NSRect) {
        guard let s = m.selected else { return }
        let xSel = timelineX(for: s.startedAtMs)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xSel, y: rect.minY))
        path.line(to: NSPoint(x: xSel, y: rect.maxY))
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawPlaybackCursor(model m: TimelineModel, in rect: NSRect) {
        guard let playbackTimeMs = m.playbackTimeMs else { return }
        let x = timelineX(for: playbackTimeMs)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: rect.minY))
        path.line(to: NSPoint(x: x, y: rect.maxY))
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func segmentColor(for segment: TimelineSegment) -> NSColor {
        switch segment.captureKind {
        case .screen:
            return AppColor.color(for: segment.appBundleId)
        case .audio:
            switch segment.audioSourceKind {
            case .microphone:
                return NSColor.systemPink
            case .system:
                return NSColor.systemOrange
            case nil:
                return NSColor.systemPurple
            }
        }
    }

    private func segmentIcon(for segment: TimelineSegment) -> NSImage? {
        if let bundleId = segment.appBundleId {
            return AppIconCache.shared.cachedIcon(for: bundleId)
        }
        if segment.captureKind == .audio {
            return NSImage(systemSymbolName: segment.audioSourceKind?.systemImage ?? segment.captureKind.systemImage,
                           accessibilityDescription: segment.audioSourceKind?.displayName ?? segment.captureKind.displayName)
        }
        return nil
    }

    private func drawAudioSegments(model m: TimelineModel, in rect: NSRect) {
        guard !audioSpans.isEmpty else { return }

        let laneRect = rect.insetBy(dx: 0, dy: -1)
        NSColor.separatorColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: laneRect, xRadius: laneRect.height / 2, yRadius: laneRect.height / 2).fill()

        for span in audioSpans {
            let spanRect = NSRect(x: timelineX(for: span.startMs),
                                  y: rect.minY,
                                  width: max(2, timelineX(for: span.endMs) - timelineX(for: span.startMs)),
                                  height: rect.height)
            guard needsToDraw(spanRect) else { continue }
            drawAudioWaveformPlaceholder(in: spanRect.insetBy(dx: 1, dy: 1),
                                         color: audioBaseColor(for: span.sourceKind))

            for meta in span.items {
                let x0 = timelineX(for: meta.startedAtMs)
                let x1 = timelineX(for: m.resolvedEndMs(for: meta))
                let width = max(2, x1 - x0)
                let segmentRect = NSRect(x: x0, y: rect.minY, width: width, height: rect.height)
                guard needsToDraw(segmentRect) else { continue }

                if let overview = AudioWaveformOverviewCache.shared.cachedOverview(for: meta.path) {
                    drawAudioWaveform(overview,
                                      in: segmentRect.insetBy(dx: 1, dy: 1),
                                      color: audioBaseColor(for: meta))
                } else {
                    AudioWaveformOverviewCache.shared.loadOverviewAsync(for: meta.path) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.needsDisplay = true
                        }
                    }
                }
            }
        }
    }

    private func mergeAudioDisplaySpans(from metas: [SnapshotMeta],
                                        model: TimelineModel) -> [MergedAudioDisplaySpan] {
        let allowedGapMs: Int64 = 1_500
        var spans: [MergedAudioDisplaySpan] = []

        for meta in metas {
            let endMs = model.resolvedEndMs(for: meta)
            if var last = spans.last,
               last.sourceKind == meta.audioSourceKind,
               meta.startedAtMs <= last.endMs + allowedGapMs {
                last.items.append(meta)
                last.endMs = max(last.endMs, endMs)
                spans[spans.count - 1] = last
            } else {
                spans.append(
                    MergedAudioDisplaySpan(
                        sourceKind: meta.audioSourceKind,
                        startMs: meta.startedAtMs,
                        endMs: endMs,
                        items: [meta]
                    )
                )
            }
        }

        return spans
    }

    private func drawAudioWaveform(_ overview: AudioWaveformOverview,
                                   in rect: NSRect,
                                   color: NSColor) {
        guard rect.width >= 3, rect.height >= 4, !overview.bins.isEmpty else { return }

        let midY = rect.midY
        let step = rect.width / CGFloat(max(overview.bins.count, 1))
        let barWidth = max(1, min(2, step - 1))
        color.withAlphaComponent(0.82).setFill()

        for (index, amplitude) in overview.bins.enumerated() {
            let x = rect.minX + CGFloat(index) * step
            let height = max(2, CGFloat(amplitude) * rect.height)
            let barRect = NSRect(x: x,
                                 y: midY - height / 2,
                                 width: barWidth,
                                 height: height)
            NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawAudioWaveformPlaceholder(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        color.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func audioBaseColor(for meta: SnapshotMeta) -> NSColor {
        audioBaseColor(for: meta.audioSourceKind)
    }

    private func audioBaseColor(for sourceKind: AudioSourceKind?) -> NSColor {
        switch sourceKind {
        case .microphone:
            return NSColor.secondaryLabelColor
        case .system:
            return NSColor.tertiaryLabelColor
        case nil:
            return NSColor.secondaryLabelColor
        }
    }

    private func drawTicks(model m: TimelineModel, in rect: NSRect) {
        if isCompressed {
            drawCompressedTicks(in: rect)
            return
        }

        let majorStep = pickMajorTickStep(msPerPoint: m.msPerPoint)
        let minorStep = majorStep / 5
        // Include the preceding major tick and label overhang at the viewport edges.
        let start = max(m.minTimeMs, layout.time(atX: visibleRect.minX - 100) - majorStep)
        let end = min(m.maxTimeMs, layout.time(atX: visibleRect.maxX + 100) + majorStep)
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
            let xPos = timelineX(for: t)
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
                let mx = timelineX(for: mt)
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

    private func drawCompressedTicks(in rect: NSRect) {
        guard !layout.timesAsc.isEmpty else { return }
        let firstTime = layout.timesAsc.first ?? 0
        let lastTime = layout.timesAsc.last ?? firstTime
        let labelStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let yTop = rect.minY + 8
        let majorTickHeight: CGFloat = 8
        let minorTickHeight: CGFloat = 4
        let df = TimelineBarNSView.timeFormatter
        var lastMajorX = -CGFloat.greatestFiniteMagnitude
        var lastMinorX = -CGFloat.greatestFiniteMagnitude

        for (timeMs, xPos) in zip(layout.timesAsc, layout.positionsAsc) {
            let isMajor = xPos - lastMajorX >= 90 || timeMs == firstTime || timeMs == lastTime
            let needsMinor = xPos - lastMinorX >= 22
            guard isMajor || needsMinor else { continue }
            lastMinorX = xPos
            if isMajor { lastMajorX = xPos }
            guard xPos >= visibleRect.minX - 100, xPos <= visibleRect.maxX + 100 else { continue }

            let tickHeight = isMajor ? majorTickHeight : minorTickHeight
            let color = isMajor ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.5)
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: xPos, y: yTop))
            path.line(to: NSPoint(x: xPos, y: yTop + tickHeight))
            path.lineWidth = 1
            path.stroke()

            if isMajor {
                let label = df.string(from: Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)) as NSString
                let size = label.size(withAttributes: labelStyle)
                label.draw(at: NSPoint(x: xPos - size.width / 2, y: yTop + majorTickHeight + 2), withAttributes: labelStyle)
            }
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        tracking = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isDraggingTimeline ? .closedHand : .openHand)
    }

    override func mouseMoved(with event: NSEvent) {
        guard model != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = timeAt(x: p.x)
        let preferredCaptureKind = TimelineTrackLayout(in: bounds, visibleCaptureKinds: visibleCaptureKinds).preferredCaptureKind(at: p)
        onHover?(t)

        // Throttle popover repositioning
        let now = Date()
        let shouldReposition = now.timeIntervalSince(hoverThrottle) >= 0.05

        if let idx = nearestMetaIndex(to: t, preferredCaptureKind: preferredCaptureKind),
           let m = model,
           m.metas.indices.contains(idx) {
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
        guard model != nil else { return }
        window?.makeFirstResponder(self)

        let startPoint = convert(event.locationInWindow, from: nil)
        let preferredCaptureKind = TimelineTrackLayout(in: bounds, visibleCaptureKinds: visibleCaptureKinds).preferredCaptureKind(at: startPoint)
        guard let scrollView = enclosingScrollView else {
            onJump?(timeAt(x: startPoint.x), preferredCaptureKind)
            return
        }

        let startOriginX = scrollView.contentView.bounds.origin.x
        let maxX = max(0, bounds.width - scrollView.contentView.bounds.width)
        let dragThreshold: CGFloat = 3
        var didDrag = false

        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let currentPoint = convert(nextEvent.locationInWindow, from: nil)

            switch nextEvent.type {
            case .leftMouseDragged:
                guard maxX > 0 else { continue }
                let dragDeltaX = currentPoint.x - startPoint.x
                if !didDrag, abs(dragDeltaX) >= dragThreshold {
                    didDrag = true
                    beginTimelineDrag()
                    cancelTimelineHoverPreview()
                }
                guard didDrag else { continue }

                let targetX = min(max(0, startOriginX - dragDeltaX), maxX)
                scrollView.contentView.scroll(to: NSPoint(x: targetX, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)

            case .leftMouseUp:
                if didDrag {
                    endTimelineDrag()
                } else {
                    onJump?(timeAt(x: startPoint.x), preferredCaptureKind)
                }
                return

            default:
                break
            }
        }

        if didDrag {
            endTimelineDrag()
        } else {
            onJump?(timeAt(x: startPoint.x), preferredCaptureKind)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard model != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = timeAt(x: p.x)
        let preferredCaptureKind = TimelineTrackLayout(in: bounds, visibleCaptureKinds: visibleCaptureKinds).preferredCaptureKind(at: p)
        let menu = NSMenu()
        let jump = NSMenuItem(title: "Jump to here", action: #selector(ctxJump(_:)), keyEquivalent: "")
        jump.representedObject = TimelineJumpTarget(timeMs: t, preferredCaptureKind: preferredCaptureKind)
        jump.target = self
        menu.addItem(jump)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func ctxJump(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? TimelineJumpTarget {
            onJump?(target.timeMs, target.preferredCaptureKind)
        }
    }

    private func timeAt(x: CGFloat) -> Int64 {
        layout.time(atX: x)
    }

    private func nearestMetaIndex(to timeMs: Int64, preferredCaptureKind: CaptureKind?) -> Int? {
        guard let model else { return nil }
        return model.indexNearest(to: timeMs,
                                  preferredCaptureKind: preferredCaptureKind,
                                  visibleCaptureKinds: visibleCaptureKinds)
    }

    private func beginTimelineDrag() {
        guard !isDraggingTimeline else { return }
        isDraggingTimeline = true
        NSCursor.closedHand.push()
        window?.invalidateCursorRects(for: self)
    }

    private func endTimelineDrag() {
        guard isDraggingTimeline else { return }
        isDraggingTimeline = false
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
    }

    private func cancelTimelineHoverPreview() {
        onHoverExit?()
        popover.performClose(nil)
        lastPreviewIndex = nil
        pendingPreviewIndex = nil
        loadingTimer?.cancel()
        loadingTimer = nil
        previewDebounce?.cancel()
        previewDebounce = nil
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

        let date = Date(timeIntervalSince1970: TimeInterval(meta.startedAtMs)/1000)
        let initialIcon: NSImage? = {
            if let bundleId = meta.appBundleId {
                return AppIconCache.shared.cachedIcon(for: bundleId)
            }
            if meta.captureKind == .audio {
                return NSImage(systemSymbolName: meta.audioSourceKind?.systemImage ?? meta.captureKind.systemImage,
                               accessibilityDescription: meta.audioSourceKind?.displayName ?? meta.captureKind.displayName)
            }
            return nil
        }()

        previewViewModel.update(
            thumbnail: nil,
            appIcon: initialIcon,
            appName: meta.appName ?? meta.audioSourceKind?.displayName ?? meta.appBundleId ?? "Unknown",
            date: date,
            isLoading: meta.captureKind != .audio
        )

        if let bundleId = meta.appBundleId,
           AppIconCache.shared.cachedIcon(for: bundleId) == nil {
            AppIconCache.shared.loadIconAsync(for: bundleId) { [weak self] icon in
                guard let self = self, self.lastPreviewIndex == index else { return }
                guard let icon else { return }
                self.previewViewModel.appIcon = icon
            }
        }

        if meta.captureKind == .audio {
            previewViewModel.setLoading(false)
            return
        }

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
