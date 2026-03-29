import Foundation
import CoreGraphics
import ImageIO
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Imports screenshots from ScreenMemory into TimeScroll.
/// UI state is updated on MainActor; heavy work runs on a background thread.
final class ScreenMemoryImporter: ObservableObject {
    enum Mode { case copy, move }
    enum State: Equatable {
        case idle
        case running
        case done(imported: Int, skipped: Int, errors: Int)
        case failed(String)
    }

    struct ImportedItem: Identifiable {
        let id: Int64
        let timestampMs: Int64
        let destPath: String
    }

    // All @Published properties are updated only via MainActor.run
    @Published var state: State = .idle
    @Published var progress: String = ""
    @Published var imported: Int = 0
    @Published var total: Int = 0
    @Published var testItems: [ImportedItem] = []

    private var task: Task<Void, Never>?

    // MARK: - Public (called from MainActor UI)

    @MainActor func startTest(folder: URL) {
        start(folder: folder, mode: .copy, testOnly: true, includeOrphans: false)
    }

    @MainActor func startFull(folder: URL) {
        start(folder: folder, mode: .move, testOnly: false, includeOrphans: false)
    }

    @MainActor func cancel() {
        task?.cancel()
    }

    @MainActor func undoTest() {
        let items = testItems
        guard !items.isEmpty else { return }
        let fm = FileManager.default
        for item in items {
            try? fm.removeItem(atPath: item.destPath)
            try? DB.shared.deleteSnapshot(id: item.id)
        }
        testItems = []
        state = .idle
        progress = "Test import undone"
    }

    // MARK: - Private

    @MainActor private func start(folder: URL, mode: Mode, testOnly: Bool, includeOrphans: Bool = false) {
        state = .running
        imported = 0
        total = 0
        testItems = []
        progress = "Opening ScreenMemory databases..."

        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runMain(folder: folder, mode: mode, testOnly: testOnly)
        }
    }

    // MARK: - Main import (from OCR database)

    private func runMain(folder: URL, mode: Mode, testOnly: Bool) async {
        let textDbPath = folder.appendingPathComponent("text.sqlite").path
        let usageDbPath = folder.appendingPathComponent("usage.sqlite").path
        let screenshotsDir = folder.appendingPathComponent("screenshots")

        guard FileManager.default.fileExists(atPath: textDbPath),
              FileManager.default.fileExists(atPath: usageDbPath) else {
            await MainActor.run { [weak self] in
                self?.state = .failed("text.sqlite or usage.sqlite not found")
            }
            return
        }

        var textDb: OpaquePointer?
        var usageDb: OpaquePointer?
        guard sqlite3_open_v2(textDbPath, &textDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(usageDbPath, &usageDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            await MainActor.run { [weak self] in
                self?.state = .failed("Failed to open ScreenMemory databases")
            }
            sqlite3_close(textDb); sqlite3_close(usageDb)
            return
        }
        defer { sqlite3_close(textDb); sqlite3_close(usageDb) }

        await MainActor.run { [weak self] in self?.progress = "Loading app usage data..." }
        let usageLookup = Self.buildUsageLookup(db: usageDb!)
        let totalCount = Self.countRows(db: textDb!)

        let rows: [(timestamp: String, path: String, text: String)]
        if testOnly {
            rows = Self.pickTestSamples(db: textDb!, count: 5, totalCount: totalCount)
        } else {
            rows = Self.allRows(db: textDb!)
        }

        await MainActor.run { [weak self] in
            self?.total = rows.count
            self?.progress = "Importing \(rows.count) screenshots..."
        }

        let snapshotsRoot = StoragePaths.snapshotsDir()
        let fm = FileManager.default
        var okCount = 0, skipCount = 0, errCount = 0
        var testImported: [ImportedItem] = []

        for (i, row) in rows.enumerated() {
            if Task.isCancelled { break }

            guard let tsInt = Int64(row.timestamp) else { errCount += 1; continue }
            let tsMs = tsInt * 1000

            if Self.snapshotExists(timestampMs: tsMs) { skipCount += 1; continue }

            let src = screenshotsDir.appendingPathComponent(row.path)
            guard fm.fileExists(atPath: src.path) else { errCount += 1; continue }

            let date = Date(timeIntervalSince1970: TimeInterval(tsInt))
            let dayStr = Self.dayFormatter.string(from: date)
            let destDir = snapshotsRoot.appendingPathComponent(dayStr, isDirectory: true)
            if !fm.fileExists(atPath: destDir.path) {
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            let destFile = destDir.appendingPathComponent("snap-\(tsMs).jpeg")

            do {
                if mode == .copy {
                    try fm.copyItem(at: src, to: destFile)
                } else {
                    try fm.moveItem(at: src, to: destFile)
                }
            } catch { errCount += 1; continue }

            let (bytes, width, height) = Self.imageMetadata(url: destFile)
            let (bundleId, appName) = Self.lookupUsage(lookup: usageLookup, timestamp: tsInt)

            do {
                let rowId = try DB.shared.insertSnapshot(
                    startedAtMs: tsMs, path: destFile.path, text: row.text,
                    appBundleId: bundleId, appName: appName, boxes: [],
                    bytes: bytes, width: width, height: height,
                    format: "jpg", hash64: nil, thumbPath: nil
                )
                okCount += 1
                if testOnly {
                    testImported.append(ImportedItem(id: rowId, timestampMs: tsMs, destPath: destFile.path))
                }
            } catch {
                if mode == .copy { try? fm.removeItem(at: destFile) }
                errCount += 1
            }

            if (i + 1) % 200 == 0 || i == rows.count - 1 {
                let ok = okCount, skip = skipCount, err = errCount, idx = i, count = rows.count
                await MainActor.run { [weak self] in
                    self?.imported = ok
                    let pct = Int(Double(idx + 1) / Double(count) * 100)
                    self?.progress = "\(pct)% — \(ok) imported, \(skip) skipped, \(err) errors"
                }
            }
        }

        // MARK: Phase 2 — Orphan files (not in OCR database, only for full import)
        if !testOnly && !Task.isCancelled {
            await MainActor.run { [weak self] in
                self?.progress = "Scanning for remaining files not in OCR database..."
            }

            var orphanFiles: [URL] = []
            if let enumerator = fm.enumerator(at: screenshotsDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    if ext == "jpeg" || ext == "jpg" {
                        orphanFiles.append(url)
                    }
                }
            }

            if !orphanFiles.isEmpty {
                await MainActor.run { [weak self] in
                    let count = orphanFiles.count
                    self?.progress = "Importing \(count) remaining files..."
                }

                for (i, src) in orphanFiles.enumerated() {
                    if Task.isCancelled { break }

                    let filename = src.deletingPathExtension().lastPathComponent
                    let tsStr = filename.components(separatedBy: "-").first ?? filename
                    guard let tsInt = Int64(tsStr) else { errCount += 1; continue }
                    let tsMs = tsInt * 1000

                    if Self.snapshotExists(timestampMs: tsMs) { skipCount += 1; continue }

                    let date = Date(timeIntervalSince1970: TimeInterval(tsInt))
                    let dayStr = Self.dayFormatter.string(from: date)
                    let destDir = snapshotsRoot.appendingPathComponent(dayStr, isDirectory: true)
                    if !fm.fileExists(atPath: destDir.path) {
                        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    }
                    let destFile = destDir.appendingPathComponent("snap-\(tsMs).jpeg")

                    guard !fm.fileExists(atPath: destFile.path) else { skipCount += 1; continue }

                    do {
                        try fm.moveItem(at: src, to: destFile)
                    } catch { errCount += 1; continue }

                    let (bytes, width, height) = Self.imageMetadata(url: destFile)
                    let (bundleId, appName) = Self.lookupUsage(lookup: usageLookup, timestamp: tsInt)

                    do {
                        _ = try DB.shared.insertSnapshot(
                            startedAtMs: tsMs, path: destFile.path, text: "",
                            appBundleId: bundleId, appName: appName, boxes: [],
                            bytes: bytes, width: width, height: height,
                            format: "jpg", hash64: nil, thumbPath: nil
                        )
                        okCount += 1
                    } catch {
                        errCount += 1
                    }

                    if (i + 1) % 100 == 0 || i == orphanFiles.count - 1 {
                        let ok = okCount, skip = skipCount, err = errCount, idx = i, count = orphanFiles.count
                        await MainActor.run { [weak self] in
                            self?.imported = ok
                            let pct = Int(Double(idx + 1) / Double(count) * 100)
                            self?.progress = "Orphans: \(pct)% — \(ok) total imported, \(skip) skipped, \(err) errors"
                        }
                    }
                }
            }
        }

        let finalOk = okCount, finalSkip = skipCount, finalErr = errCount
        await MainActor.run { [weak self] in
            AppState.shared.lastSnapshotTick &+= finalOk
            self?.imported = finalOk
            self?.testItems = testImported
            self?.state = .done(imported: finalOk, skipped: finalSkip, errors: finalErr)
            self?.progress = "Done: \(finalOk) imported, \(finalSkip) skipped, \(finalErr) errors"
        }
    }

    // MARK: - Helpers (all static to avoid actor isolation issues)

    private static func imageMetadata(url: URL) -> (bytes: Int64, width: Int, height: Int) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        var w = 0, h = 0
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
        return (bytes, w, h)
    }

    private struct UsageEntry {
        let timestamp: Int64
        let bundleId: String
        let name: String
    }

    private static func buildUsageLookup(db: OpaquePointer) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT CAST(timestamp AS INTEGER), identifier, name FROM usage ORDER BY timestamp;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let id = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            entries.append(UsageEntry(timestamp: ts, bundleId: id, name: name))
        }
        return entries
    }

    private static func lookupUsage(lookup: [UsageEntry], timestamp: Int64) -> (String?, String?) {
        guard !lookup.isEmpty else { return (nil, nil) }
        var lo = 0, hi = lookup.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lookup[mid].timestamp < timestamp { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0 && abs(lookup[lo - 1].timestamp - timestamp) < abs(lookup[lo].timestamp - timestamp) {
            best = lo - 1
        }
        let entry = lookup[best]
        guard abs(entry.timestamp - timestamp) <= 30 else { return (nil, nil) }
        let name = entry.name == "name" ? nil : entry.name
        return (entry.bundleId, name)
    }

    private static func countRows(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ocrresults;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func pickTestSamples(db: OpaquePointer, count: Int, totalCount: Int) -> [(timestamp: String, path: String, text: String)] {
        guard totalCount > 0 else { return [] }
        let step = max(1, totalCount / count)
        var results: [(String, String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT imagetimestamp, imagepath, imagetext FROM ocrresults ORDER BY imagetimestamp;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var idx = 0, nextTarget = 0
        while sqlite3_step(stmt) == SQLITE_ROW && results.count < count {
            if idx == nextTarget {
                let ts = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                results.append((ts, path, text))
                nextTarget += step
            }
            idx += 1
        }
        return results
    }

    private static func allRows(db: OpaquePointer) -> [(timestamp: String, path: String, text: String)] {
        var results: [(String, String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT imagetimestamp, imagepath, imagetext FROM ocrresults ORDER BY imagetimestamp;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            results.append((ts, path, text))
        }
        return results
    }

    private static func snapshotExists(timestampMs: Int64) -> Bool {
        var exists = false
        DB.shared.onQueueSync {
            guard let db = DB.shared.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM ts_snapshot WHERE started_at_ms=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, timestampMs)
            exists = sqlite3_step(stmt) == SQLITE_ROW
        }
        return exists
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df
    }()
}
