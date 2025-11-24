import XCTest
@testable import TimeScroll

final class StorageMigrationTests: XCTestCase {
    func test_updateSnapshotPathsAfterRootMove_rewrites_paths_and_thumbs() async throws {
        // Setup two temporary directories: oldRoot and newRoot
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let oldRoot = tmp.appendingPathComponent("ts_test_old_\(UUID().uuidString)", isDirectory: true)
        let newRoot = tmp.appendingPathComponent("ts_test_new_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        // Ensure DB is closed and point storage to newRoot (so DB file will be created here)
        DB.shared.close()
        await MainActor.run { StoragePaths.setStorageFolder(newRoot) }
        try DB.shared.openIfNeeded()

        // Insert a row with path and thumb_path referencing oldRoot
        let started: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        let oldPath = oldRoot.appendingPathComponent("Snapshots/day/img.png").path
        let oldThumb = oldRoot.appendingPathComponent("Snapshots/day/thumb.png").path
        let id = try DB.shared.insertSnapshot(startedAtMs: started, path: oldPath, text: "text", appBundleId: nil, appName: nil, boxes: [], bytes: nil, width: nil, height: nil, format: nil, hash64: nil, thumbPath: oldThumb)

        // Verify it was inserted and contains the old prefix
        var rows = try DB.shared.listPlaintextSnapshots(limit: 10)
        XCTAssertTrue(rows.contains { $0.path == oldPath })

        // Call the migration helper to rewrite paths
        DB.shared.updateSnapshotPathsAfterRootMove(oldRoot: oldRoot.path, newRoot: newRoot.path)

        // Confirm the DB rows now reflect newRoot prefix
        rows = try DB.shared.listPlaintextSnapshots(limit: 10)
        XCTAssertTrue(rows.contains { $0.path.hasPrefix(newRoot.path) })

        // Clean up
        try? DB.shared.purgeRowsOlderThan(cutoffMs: Int64(Date().timeIntervalSince1970 * 1000) + 1000, deleteFiles: false)
        try? fm.removeItem(at: oldRoot)
        try? fm.removeItem(at: newRoot)
    }

    func test_updateSnapshotPathsToCurrentRoot_rewrites_paths_and_thumbs() async throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let oldRoot = tmp.appendingPathComponent("ts_test_old_\(UUID().uuidString)", isDirectory: true)
        let newRoot = tmp.appendingPathComponent("ts_test_new_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        DB.shared.close()
        await MainActor.run { StoragePaths.setStorageFolder(newRoot) }
        try DB.shared.openIfNeeded()

        let started: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        let oldPath = oldRoot.appendingPathComponent("Snapshots/day/img2.png").path
        let oldThumb = oldRoot.appendingPathComponent("Snapshots/day/thumb2.png").path
        let id = try DB.shared.insertSnapshot(startedAtMs: started, path: oldPath, text: "text", appBundleId: nil, appName: nil, boxes: [], bytes: nil, width: nil, height: nil, format: nil, hash64: nil, thumbPath: oldThumb)

        var rows = try DB.shared.listPlaintextSnapshots(limit: 10)
        XCTAssertTrue(rows.contains { $0.path == oldPath })

        let changed = DB.shared.updateSnapshotPathsToCurrentRoot()
        XCTAssertTrue(changed >= 1)

        rows = try DB.shared.listPlaintextSnapshots(limit: 10)
        XCTAssertTrue(rows.contains { $0.path.hasPrefix(newRoot.path) })

        try? DB.shared.purgeRowsOlderThan(cutoffMs: Int64(Date().timeIntervalSince1970 * 1000) + 1000, deleteFiles: false)
        try? fm.removeItem(at: oldRoot)
        try? fm.removeItem(at: newRoot)
    }
}

// Helper to call MainActor-only APIs
private func awaitMainThread(_ body: @escaping () -> Void) {
    let exp = XCTestExpectation(description: "main")
    DispatchQueue.main.async {
        body()
        exp.fulfill()
    }
    _ = XCTWaiter.wait(for: [exp], timeout: 2.0)
}
