import CoreImage
import CoreVideo
import Foundation

/// Decouples embedding from capture: callers hand over a snapshot and return immediately,
/// releasing the capture-pool buffer. A background queue embeds pending snapshots in batches.
final class SnapshotEmbeddingQueue {
    static let shared = SnapshotEmbeddingQueue()
    private init() {}

    /// Pending work is bounded; when full, the oldest job is dropped (a rebuild can backfill it).
    private static let maxPending = 32
    private static let batchSize = 16
    /// Long edge of the private frame copy; MobileCLIP center-crops and resizes to ~256 px anyway.
    private static let imageMaxEdge: CGFloat = 512

    private let queue = DispatchQueue(label: "TimeScroll.EmbeddingQueue", qos: .utility)
    private let lock = NSLock()
    private var pending: [SnapshotEmbeddingWriter.Job] = []
    private var draining = false
    private let ciContext = CIContext(options: [.priorityRequestLow: true, .cacheIntermediates: false])

    func enqueue(snapshotId: Int64, pixelBuffer: CVPixelBuffer, extractedText: String?) {
        guard UserDefaults.standard.bool(forKey: "settings.aiEmbeddingsEnabled") else { return }
        let image = EmbeddingService.shared.supportsImageDocuments ? downscaledCopy(of: pixelBuffer) : nil
        let job = SnapshotEmbeddingWriter.Job(snapshotId: snapshotId, image: image, extractedText: extractedText)

        lock.lock()
        if pending.count >= Self.maxPending { pending.removeFirst() }
        pending.append(job)
        let startDrain = !draining
        draining = true
        lock.unlock()

        if startDrain { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = Array(pending.prefix(Self.batchSize))
            pending.removeFirst(batch.count)
            if batch.isEmpty { draining = false }
            lock.unlock()
            guard !batch.isEmpty else { return }
            SnapshotEmbeddingWriter.shared.storeEmbeddings(for: batch)
        }
    }

    private func downscaledCopy(of pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, Self.imageMaxEdge / max(source.extent.width, source.extent.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(scaled.extent.width.rounded(.down)), height = Int(scaled.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        ciContext.render(scaled, to: output)
        return output
    }
}
