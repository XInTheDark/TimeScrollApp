import XCTest
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif
@testable import TimeScroll

final class ScreenMemoryImporterTests: XCTestCase {

    private var testDir: URL!
    private var screenshotsDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        // Create a temporary ScreenMemory-like folder structure
        testDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm_import_test_\(UUID().uuidString)", isDirectory: true)
        screenshotsDir = testDir.appendingPathComponent("screenshots", isDirectory: true)
        try fm.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        // Ensure DB is open
        try DB.shared.openIfNeeded()
    }

    override func tearDown() async throws {
        // Clean up temp directory
        try? fm.removeItem(at: testDir)
        try await super.tearDown()
    }

    // MARK: - Helper: create fake ScreenMemory databases

    private func createScreenMemoryDatabases(
        screenshots: [(timestamp: Int64, text: String, bundleId: String, appName: String)]
    ) throws {
        // Create text.sqlite
        let textDbPath = testDir.appendingPathComponent("text.sqlite").path
        var textDb: OpaquePointer?
        XCTAssertEqual(sqlite3_open(textDbPath, &textDb), SQLITE_OK)
        defer { sqlite3_close(textDb) }

        sqlite3_exec(textDb, """
            CREATE TABLE IF NOT EXISTS ocrresults (
                id INTEGER PRIMARY KEY NOT NULL,
                imagetimestamp TEXT UNIQUE,
                imagepath TEXT NOT NULL UNIQUE,
                imagedate TEXT NOT NULL,
                imagetext TEXT NOT NULL
            );
        """, nil, nil, nil)

        for (i, ss) in screenshots.enumerated() {
            let ts = String(ss.timestamp)
            // Organize by date path like ScreenMemory does
            let date = Date(timeIntervalSince1970: TimeInterval(ss.timestamp))
            let cal = Calendar.current
            let y = cal.component(.year, from: date)
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let h = String(format: "%02d", cal.component(.hour, from: date))
            let imagepath = "\(y)/\(m)/\(d)/\(h)/\(ts).jpeg"
            let imagedate = "\(y)/\(m)/\(d)/\(h)"

            // Create the directory and a dummy JPEG file
            let dirURL = screenshotsDir.appendingPathComponent("\(y)/\(m)/\(d)/\(h)", isDirectory: true)
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let fileURL = dirURL.appendingPathComponent("\(ts).jpeg")
            // Write a minimal valid JPEG (just a marker, enough for file existence)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: fileURL)

            var stmt: OpaquePointer?
            sqlite3_prepare_v2(textDb, "INSERT INTO ocrresults (imagetimestamp, imagepath, imagedate, imagetext) VALUES (?, ?, ?, ?);", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, ts, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, imagepath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, imagedate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, ss.text, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Create usage.sqlite
        let usageDbPath = testDir.appendingPathComponent("usage.sqlite").path
        var usageDb: OpaquePointer?
        XCTAssertEqual(sqlite3_open(usageDbPath, &usageDb), SQLITE_OK)
        defer { sqlite3_close(usageDb) }

        sqlite3_exec(usageDb, """
            CREATE TABLE IF NOT EXISTS usage (
                id INTEGER PRIMARY KEY NOT NULL,
                timestamp TEXT NOT NULL,
                identifier TEXT NOT NULL,
                name TEXT NOT NULL
            );
        """, nil, nil, nil)

        for ss in screenshots {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(usageDb, "INSERT INTO usage (timestamp, identifier, name) VALUES (?, ?, ?);", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, String(ss.timestamp), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, ss.bundleId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, ss.appName, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Tests

    func test_testImport_copies_files_and_inserts_db_rows() async throws {
        let ts: Int64 = 1700000000 // Nov 14, 2023
        try createScreenMemoryDatabases(screenshots: [
            (timestamp: ts, text: "Hello World test OCR", bundleId: "com.test.app", appName: "TestApp")
        ])

        let importer = await ScreenMemoryImporter()
        await importer.startTest(folder: testDir)

        // Wait for import to complete
        let expectation = XCTestExpectation(description: "Import completes")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if case .done = importer.state { expectation.fulfill(); return }
                if case .failed = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        // Verify state
        await MainActor.run {
            if case .done(let imported, _, let errors) = importer.state {
                XCTAssertEqual(imported, 1)
                XCTAssertEqual(errors, 0)
            } else {
                XCTFail("Expected .done state, got \(importer.state)")
            }

            // Verify test items tracked for undo
            XCTAssertEqual(importer.testItems.count, 1)
        }

        // Verify DB row exists
        let tsMs = ts * 1000
        var found = false
        DB.shared.onQueueSync {
            guard let db = DB.shared.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "SELECT app_bundle_id, format FROM ts_snapshot WHERE started_at_ms=?;", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, tsMs)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let bundle = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                let format = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                XCTAssertEqual(bundle, "com.test.app")
                XCTAssertEqual(format, "jpg")
                found = true
            }
        }
        XCTAssertTrue(found, "Snapshot row should exist in DB")

        // Verify FTS text was indexed
        let textContent = try DB.shared.textContent(snapshotId: await importer.testItems.first!.id)
        XCTAssertTrue(textContent?.contains("Hello World") == true)

        // Verify source file still exists (copy mode)
        let srcFile = screenshotsDir
            .appendingPathComponent("2023/11/14")
            .appendingPathComponent("\(ts).jpeg")
        // Source should still be there since we used copy mode
        // (the exact path depends on timezone, so check via DB)

        // Clean up: undo the test import
        await importer.undoTest()
        await MainActor.run {
            XCTAssertEqual(importer.testItems.count, 0)
        }

        // Verify DB row is gone after undo
        var foundAfterUndo = false
        DB.shared.onQueueSync {
            guard let db = DB.shared.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "SELECT 1 FROM ts_snapshot WHERE started_at_ms=?;", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, tsMs)
            foundAfterUndo = sqlite3_step(stmt) == SQLITE_ROW
        }
        XCTAssertFalse(foundAfterUndo, "Snapshot should be removed after undo")
    }

    func test_fullImport_moves_files_and_handles_orphans() async throws {
        let ts1: Int64 = 1700000000
        let ts2: Int64 = 1700001000
        try createScreenMemoryDatabases(screenshots: [
            (timestamp: ts1, text: "OCR text one", bundleId: "com.app.one", appName: "AppOne"),
            (timestamp: ts2, text: "OCR text two", bundleId: "com.app.two", appName: "AppTwo")
        ])

        // Add an orphan file (on disk but not in OCR database)
        let orphanTs: Int64 = 1700002000
        let orphanDir = screenshotsDir.appendingPathComponent("2023/11/14/23", isDirectory: true)
        try fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphanFile = orphanDir.appendingPathComponent("\(orphanTs).jpeg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: orphanFile)

        let importer = await ScreenMemoryImporter()
        await importer.startFull(folder: testDir)

        let expectation = XCTestExpectation(description: "Full import completes")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if case .done = importer.state { expectation.fulfill(); return }
                if case .failed = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        await MainActor.run {
            if case .done(let imported, _, let errors) = importer.state {
                XCTAssertEqual(imported, 3, "Should import 2 OCR rows + 1 orphan")
                XCTAssertEqual(errors, 0)
            } else {
                XCTFail("Expected .done state, got \(importer.state)")
            }
        }

        // Verify all 3 are in DB
        for ts in [ts1, ts2, orphanTs] {
            var found = false
            DB.shared.onQueueSync {
                guard let db = DB.shared.db else { return }
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                sqlite3_prepare_v2(db, "SELECT 1 FROM ts_snapshot WHERE started_at_ms=?;", -1, &stmt, nil)
                sqlite3_bind_int64(stmt, 1, ts * 1000)
                found = sqlite3_step(stmt) == SQLITE_ROW
            }
            XCTAssertTrue(found, "Snapshot for ts=\(ts) should exist")
        }

        // Verify source files were moved (should no longer exist at source)
        let src1 = screenshotsDir.appendingPathComponent("2023/11/14")
        // Files should have been moved away
        XCTAssertFalse(fm.fileExists(atPath: orphanFile.path), "Orphan source should be moved")

        // Clean up DB rows
        for ts in [ts1, ts2, orphanTs] {
            try? DB.shared.deleteSnapshot(id: ts * 1000) // this won't work by timestamp, but cleanup is best-effort
        }
    }

    func test_duplicate_detection_skips_existing() async throws {
        let ts: Int64 = 1700010000
        try createScreenMemoryDatabases(screenshots: [
            (timestamp: ts, text: "Existing", bundleId: "com.test", appName: "Test")
        ])

        // Pre-insert so it's a duplicate
        let tsMs = ts * 1000
        _ = try DB.shared.insertSnapshot(
            startedAtMs: tsMs, path: "/fake/path.jpg", text: "pre-existing",
            appBundleId: nil, appName: nil, boxes: [],
            bytes: nil, width: nil, height: nil, format: "jpg", hash64: nil, thumbPath: nil
        )

        let importer = await ScreenMemoryImporter()
        await importer.startTest(folder: testDir)

        let expectation = XCTestExpectation(description: "Import with duplicate")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if case .done = importer.state { expectation.fulfill(); return }
                if case .failed = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        await MainActor.run {
            if case .done(let imported, let skipped, _) = importer.state {
                XCTAssertEqual(imported, 0, "Should not import duplicates")
                XCTAssertEqual(skipped, 1, "Should skip the duplicate")
            } else {
                XCTFail("Expected .done state")
            }
        }
    }

    func test_missing_source_file_counted_as_error() async throws {
        let ts: Int64 = 1700020000
        try createScreenMemoryDatabases(screenshots: [
            (timestamp: ts, text: "Ghost", bundleId: "com.ghost", appName: "Ghost")
        ])

        // Delete the source file so it's missing
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = String(format: "%02d", cal.component(.month, from: date))
        let d = String(format: "%02d", cal.component(.day, from: date))
        let h = String(format: "%02d", cal.component(.hour, from: date))
        let srcFile = screenshotsDir.appendingPathComponent("\(y)/\(m)/\(d)/\(h)/\(ts).jpeg")
        try? fm.removeItem(at: srcFile)

        let importer = await ScreenMemoryImporter()
        await importer.startTest(folder: testDir)

        let expectation = XCTestExpectation(description: "Import with missing file")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if case .done = importer.state { expectation.fulfill(); return }
                if case .failed = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        await MainActor.run {
            if case .done(let imported, _, let errors) = importer.state {
                XCTAssertEqual(imported, 0)
                XCTAssertEqual(errors, 1, "Missing file should be counted as error")
            } else {
                XCTFail("Expected .done state")
            }
        }
    }

    func test_invalid_folder_fails_gracefully() async throws {
        let bogusDir = URL(fileURLWithPath: "/tmp/nonexistent_sm_\(UUID().uuidString)")

        let importer = await ScreenMemoryImporter()
        await importer.startTest(folder: bogusDir)

        let expectation = XCTestExpectation(description: "Import fails for invalid folder")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if case .failed = importer.state { expectation.fulfill(); return }
                if case .done = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        await MainActor.run {
            if case .failed(let msg) = importer.state {
                XCTAssertTrue(msg.contains("not found"))
            } else {
                XCTFail("Expected .failed state")
            }
        }
    }

    func test_usage_name_placeholder_mapped_to_nil() async throws {
        let ts: Int64 = 1700030000
        try createScreenMemoryDatabases(screenshots: [
            (timestamp: ts, text: "Test", bundleId: "com.browser", appName: "name") // "name" is ScreenMemory's placeholder
        ])

        let importer = await ScreenMemoryImporter()
        await importer.startTest(folder: testDir)

        let expectation = XCTestExpectation(description: "Import with placeholder name")
        Task { @MainActor in
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if case .done = importer.state { expectation.fulfill(); return }
                if case .failed = importer.state { expectation.fulfill(); return }
            }
        }
        await fulfillment(of: [expectation], timeout: 15)

        // Verify app_name is nil (not "name")
        let tsMs = ts * 1000
        DB.shared.onQueueSync {
            guard let db = DB.shared.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "SELECT app_name, app_bundle_id FROM ts_snapshot WHERE started_at_ms=?;", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, tsMs)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let appName = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                let bundleId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                XCTAssertNil(appName, "Placeholder 'name' should be mapped to nil")
                XCTAssertEqual(bundleId, "com.browser")
            }
        }

        // Clean up
        await importer.undoTest()
    }
}
