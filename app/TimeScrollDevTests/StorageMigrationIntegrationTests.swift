import XCTest
@testable import TimeScroll

final class StorageMigrationIntegrationTests: XCTestCase {
    func test_transfer_copies_snapshots_and_videos() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let oldRoot = tmp.appendingPathComponent("sm_old_\(UUID().uuidString)", isDirectory: true)
        let newRoot = tmp.appendingPathComponent("sm_new_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        // Create Snapshots and Videos entries
        let snapDir = oldRoot.appendingPathComponent("Snapshots/day", isDirectory: true)
        try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let img = snapDir.appendingPathComponent("img.png")
        try "image".data(using: .utf8)!.write(to: img)

        let videosDir = oldRoot.appendingPathComponent("Videos", isDirectory: true)
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        let vid = videosDir.appendingPathComponent("seg-1.mov")
        try "video".data(using: .utf8)!.write(to: vid)

        // Run transfer
        try StorageMigrationManager.transfer(from: oldRoot, to: newRoot)

        // Both files should exist under newRoot
        XCTAssertTrue(fm.fileExists(atPath: newRoot.appendingPathComponent("Snapshots/day/img.png").path))
        XCTAssertTrue(fm.fileExists(atPath: newRoot.appendingPathComponent("Videos/seg-1.mov").path))

        // Clean up
        try? fm.removeItem(at: oldRoot)
        try? fm.removeItem(at: newRoot)
    }

    func test_deleteSnapshot_removes_db_rows_and_files() async throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = tmp.appendingPathComponent("ds_root_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Use this root as the current storage for DB
        DB.shared.close()
        await MainActor.run { StoragePaths.setStorageFolder(root) }
        try DB.shared.openIfNeeded()

        // Create snapshot file and insert record
        let snaps = root.appendingPathComponent("Snapshots/day", isDirectory: true)
        try fm.createDirectory(at: snaps, withIntermediateDirectories: true)
        let img = snaps.appendingPathComponent("to-delete.png")
        try "x".data(using: .utf8)!.write(to: img)

        let started: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        let id = try DB.shared.insertSnapshot(startedAtMs: started, path: img.path, text: "deleteme", appBundleId: nil, appName: nil, boxes: [], bytes: nil, width: nil, height: nil, format: nil, hash64: nil, thumbPath: nil)

        // Confirm present
        let rowsBefore = try DB.shared.listPlaintextSnapshots(limit: 20)
        XCTAssertTrue(rowsBefore.contains { $0.id == id })

        try DB.shared.deleteSnapshot(id: id)

        let rowsAfter = try DB.shared.listPlaintextSnapshots(limit: 20)
        XCTAssertFalse(rowsAfter.contains { $0.id == id })

        // File should be removed
        XCTAssertFalse(fm.fileExists(atPath: img.path))

        try? DB.shared.purgeRowsOlderThan(cutoffMs: Int64(Date().timeIntervalSince1970 * 1000) + 1000, deleteFiles: false)
        try? fm.removeItem(at: root)
    }
}
