import Foundation

/// Runs the legacy text-index migration in small transactions on a background queue,
/// pausing between batches so capture writes and UI reads keep flowing.
final class TextIndexBackfill {
    static let shared = TextIndexBackfill()
    private init() {}

    private static let batchSize = 500
    private static let pauseBetweenBatches: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "TimeScroll.TextIndexBackfill", qos: .background)
    private let lock = NSLock()
    private var running = false

    func resumeIfNeeded() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        queue.async { [self] in
            defer {
                lock.lock(); running = false; lock.unlock()
            }
            var migrated = 0
            while true {
                // Stops on errors (e.g. vault locked); the next maintenance run resumes.
                guard let step = try? DB.shared.backfillTextIndexBatch(limit: Self.batchSize) else { return }
                switch step {
                case .progressed(let count):
                    migrated += count
                    Thread.sleep(forTimeInterval: Self.pauseBetweenBatches)
                case .done:
                    if migrated > 0 { fputs("[TextIndex] backfill complete (\(migrated) rows)\n", stderr) }
                    return
                }
            }
        }
    }
}
