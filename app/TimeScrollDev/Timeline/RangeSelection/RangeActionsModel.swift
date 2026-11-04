import Foundation

/// Counts what the selected range holds, and runs the delete. Counting is debounced and cancelled
/// by newer ranges, because a drag changes the range on every mouse move.
@MainActor
final class RangeActionsModel: ObservableObject {
  @Published private(set) var count: DB.SnapshotRangeCount?
  @Published private(set) var isDeleting = false
  @Published private(set) var deletedCount = 0
  @Published private(set) var deleteFailed = false

  private let countRows: @Sendable (SnapshotRangeFilter) -> DB.SnapshotRangeCount?
  private let deleteRows: @Sendable (SnapshotRangeFilter, @escaping @Sendable (Int) -> Void) -> Bool
  private let countDelay: Duration
  private var countTask: Task<Void, Never>?

  init(countDelay: Duration = .milliseconds(150),
       countRows: @escaping @Sendable (SnapshotRangeFilter) -> DB.SnapshotRangeCount? = { try? DB.shared.countSnapshots(matching: $0) },
       deleteRows: @escaping @Sendable (SnapshotRangeFilter, @escaping @Sendable (Int) -> Void) -> Bool = { filter, progress in
         (try? DB.shared.deleteSnapshots(matching: filter, progress: progress)) != nil
       }) {
    self.countDelay = countDelay
    self.countRows = countRows
    self.deleteRows = deleteRows
  }

  func refreshCount(for filter: SnapshotRangeFilter?) {
    countTask?.cancel()
    count = nil
    guard let filter else { return }
    let countRows = self.countRows
    countTask = Task { [weak self, countDelay] in
      try? await Task.sleep(for: countDelay)
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .userInitiated) { countRows(filter) }.value
      guard !Task.isCancelled else { return }
      self?.count = result
    }
  }

  /// Waits for the newest count; for tests.
  func settleCount() async {
    await countTask?.value
  }

  /// Runs off the main thread. Returns false if it stopped early, in which case some rows may remain.
  func delete(_ filter: SnapshotRangeFilter) async -> Bool {
    guard !isDeleting else { return false }
    isDeleting = true
    deleteFailed = false
    deletedCount = 0
    let deleteRows = self.deleteRows
    let succeeded = await Task.detached(priority: .userInitiated) { [weak self] in
      deleteRows(filter) { removed in
        Task { @MainActor in self?.deletedCount = removed }
      }
    }.value
    isDeleting = false
    deleteFailed = !succeeded
    return succeeded
  }
}
