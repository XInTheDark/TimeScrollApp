import SwiftUI
import AppKit

// A zoomable, scrollable image view that also draws OCR highlight rects.
// Uses NSScrollView magnification (pinch-to-zoom on trackpad) and allows panning.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let rects: [CGRect]

    // Update content highlights without recreating the scroll view.
    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8.0

        let doc = ImageDocumentView(image: image, rects: rects)
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.setFrameSize(image.size)
        scroll.documentView = doc
        // Perform two fit attempts to handle initial layout animations/sizing
        scroll.requestFitOnNextLayout(times: 2)
        return scroll
    }

    func updateNSView(_ nsView: ZoomScrollView, context: Context) {
        if let doc = nsView.documentView as? ImageDocumentView {
            if doc.image !== image {
                doc.image = image
                doc.rects = rects
                doc.setFrameSize(image.size)
                doc.needsDisplay = true
                nsView.requestFitOnNextLayout(times: 2)
            } else if doc.rects != rects {
                doc.rects = rects
                doc.needsDisplay = true
            }
        }
    }
}

final class ZoomScrollView: NSScrollView {
    private var fitPendingCount: Int = 0
    override var acceptsFirstResponder: Bool { true }
    // Fit content initially or when content changes significantly.
    func fitToContent() {
        guard let doc = self.documentView else { return }
        let contentSize = doc.bounds.size
        guard contentSize.width > 0 && contentSize.height > 0 else { return }
        let viewSize = self.contentView.bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }
        // Ask NSScrollView to compute the best magnification to fit the document
        self.magnify(toFit: doc.bounds)
        centerContent()
    }

    func requestFitOnNextLayout(times: Int = 1) {
        fitPendingCount = max(fitPendingCount, times)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard fitPendingCount > 0 else { return }
        let viewSize = self.contentView.bounds.size
        if viewSize.width > 0 && viewSize.height > 0, let doc = documentView, doc.bounds.width > 0, doc.bounds.height > 0 {
            fitToContent()
            fitPendingCount -= 1
        }
    }

    private func centerContent() {
        guard let doc = self.documentView else { return }
        let vis = self.documentVisibleRect
        let docRect = doc.bounds
        let x = max(0, (docRect.width - vis.width) / 2)
        let y = max(0, (docRect.height - vis.height) / 2)
        self.contentView.scroll(to: NSPoint(x: x, y: y))
    }

    // Optional: support Option/Command + scroll wheel to zoom in/out.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY
            let factor = 1 + (delta / 100.0)
            let newMag = max(minMagnification, min(maxMagnification, magnification * factor))
            self.magnification = newMag
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Ensure keyboard focus moves away from any text input to the stage
        self.window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

final class ImageDocumentView: NSView {
    var image: NSImage
    var rects: [CGRect]

    init(image: NSImage, rects: [CGRect]) {
        self.image = image
        self.rects = rects
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false } // default AppKit coordinates (origin at bottom-left)

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Move focus to the image so global key monitor handles shortcuts
        self.window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        // Draw the image at 1:1 inside the document bounds
        image.draw(in: NSRect(origin: .zero, size: image.size))

        // Highlight boxes (normalized coordinates in Vision space: origin bottom-left)
        guard !rects.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let w = image.size.width
        let h = image.size.height
        for r in rects {
            let rx = r.origin.x * w
            let ry = r.origin.y * h
            let rw = r.size.width * w
            let rh = r.size.height * h
            let rect = NSRect(x: rx, y: ry, width: rw, height: rh)

            NSColor.yellow.withAlphaComponent(0.15).setFill()
            rect.fill(using: .sourceOver)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            NSColor.yellow.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
