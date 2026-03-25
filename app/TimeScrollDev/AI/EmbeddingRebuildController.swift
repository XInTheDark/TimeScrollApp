import Foundation

@MainActor
final class EmbeddingRebuildController: ObservableObject {
    static let shared = EmbeddingRebuildController()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var processed: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var stored: Int = 0
    @Published private(set) var lastMessage: String?

    private init() {}

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        processed = 0
        total = 0
        stored = 0
        lastMessage = nil

        Task.detached(priority: .utility) {
            do {
                try SnapshotEmbeddingWriter.shared.rebuildCurrentEmbeddings { status in
                    Task { @MainActor in
                        let controller = EmbeddingRebuildController.shared
                        controller.processed = status.processed
                        controller.total = status.total
                        controller.stored = status.stored
                    }
                }
                await MainActor.run {
                    let controller = EmbeddingRebuildController.shared
                    controller.isRunning = false
                    controller.lastMessage = controller.total == 0
                        ? "No snapshots were available to rebuild."
                        : "Rebuilt \(controller.stored) embeddings."
                }
            } catch {
                await MainActor.run {
                    let controller = EmbeddingRebuildController.shared
                    controller.isRunning = false
                    controller.lastMessage = error.localizedDescription
                }
            }
        }
    }

    func clearMessage() {
        lastMessage = nil
    }
}
