#if DEBUG
import AppKit
import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Fills the fake home's database with the manifest's history, through the same writes capture uses.
enum DemoSeeder {
  private struct ScreenText: Decodable {
    struct Line: Decodable { let text: String; let x: Double; let y: Double; let w: Double; let h: Double }
    let width: Int
    let height: Int
    let lines: [Line]
  }

  private struct Prepared {
    let path: String
    let text: String
    let boxes: [OCRLine]
    let width: Int
    let height: Int
    let bytes: Int64
    let screen: DemoManifest.Screen
    let vector: [Float]
  }

  static func seed(manifest: DemoManifest, dataDir: URL, now: Date = Date()) throws {
    let root = StoragePaths.currentRoot().standardizedFileURL.path
    guard root.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path) else {
      throw NSError(domain: "DemoSeeder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage is outside the fake home: \(root)"])
    }
    let calendar = Calendar.current
    let prepared = try prepareScreens(manifest: manifest, dataDir: dataDir)
    let captures = DemoSchedule.captures(days: manifest.days, today: manifest.today, historyDays: manifest.historyDays,
                                         intervalSeconds: manifest.captureIntervalSeconds, now: now, calendar: calendar)
    let provider = EmbeddingService.shared.providerID
    let model = EmbeddingService.shared.modelID
    try DB.shared.withWriteSavepoint {
      for (index, capture) in captures.enumerated() {
        guard let screen = prepared[capture.screen] else { continue }
        let id = try DB.shared.insertSnapshot(startedAtMs: capture.timeMs, path: screen.path, text: screen.text,
                                              appBundleId: screen.screen.bundleId, appName: screen.screen.app,
                                              boxes: screen.boxes, bytes: screen.bytes, width: screen.width,
                                              height: screen.height, format: "png")
        // Session boundaries can land a capture or two before an app switch. Leaving those captures out of
        // AI search keeps a result card's app and thumbnail in agreement in the screenshots.
        let isBeforeSwitch = captures[index..<min(index + 3, captures.count)].contains { $0.screen != capture.screen }
        if !screen.vector.isEmpty, !isBeforeSwitch {
          _ = try DB.shared.upsertEmbedding(snapshotId: id, dim: screen.vector.count, vec: screen.vector, provider: provider, model: model)
        }
      }
    }
    try storeRecording(manifest.recording, now: now)
    try storeSummaries(manifest.summaries, now: now, calendar: calendar)
  }

  private static func storeRecording(_ recording: DemoManifest.Recording, now: Date) throws {
    let lineMs: Int64 = 20_000
    let startMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(recording.minutesAgo) * 60_000
    let durationMs = lineMs * Int64(recording.lines.count)
    let segments = recording.lines.enumerated().map { index, text in
      AudioTranscriptSegment(id: index, relativeStartMs: Int64(index) * lineMs, relativeEndMs: Int64(index + 1) * lineMs, text: text)
    }
    let path = SnapshotStore.shared.snapshotsDir.appendingPathComponent("demo/meeting.m4a").path
    let asset = try DB.shared.insertAudioAsset(startedAtMs: startMs, endedAtMs: startMs + durationMs, path: path, sourceKind: .system,
                                               bytes: nil, durationMs: durationMs, mime: "audio/mp4", sampleRate: 16_000, channels: 1,
                                               transcriptSegments: segments)
    _ = try DB.shared.insertSnapshot(startedAtMs: startMs, endedAtMs: startMs + durationMs, path: path,
                                     text: recording.lines.joined(separator: "\n"), appBundleId: nil, appName: nil,
                                     captureKind: .audio, sourceKind: .system, audioAssetId: asset)
  }

  private static func prepareScreens(manifest: DemoManifest, dataDir: URL) throws -> [String: Prepared] {
    let screensDir = dataDir.appendingPathComponent("screens", isDirectory: true)
    let storeDir = SnapshotStore.shared.snapshotsDir.appendingPathComponent("demo", isDirectory: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    var prepared: [String: Prepared] = [:]
    for (id, screen) in manifest.screens {
      let source = screensDir.appendingPathComponent("\(id).png")
      let destination = storeDir.appendingPathComponent("\(id).png")
      try FileManager.default.copyItem(at: source, to: destination)
      let layout = try JSONDecoder().decode(ScreenText.self, from: Data(contentsOf: screensDir.appendingPathComponent("\(id).json")))
      let text = layout.lines.map(\.text).joined(separator: "\n")
      let boxes = layout.lines.map { OCRLine(text: $0.text, box: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }
      let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
      prepared[id] = Prepared(path: destination.path, text: text, boxes: boxes, width: layout.width, height: layout.height,
                              bytes: bytes, screen: screen, vector: EmbeddingService.shared.embed(text, usage: .document))
    }
    return prepared
  }

  private static func storeSummaries(_ summaries: [DemoManifest.Summary], now: Date, calendar: Calendar) throws {
    for summary in summaries {
      guard let preset = TimelineRangePreset.demoPreset(named: summary.range),
            let range = preset.range(now: now, calendar: calendar) else { continue }
      let stored = StoredRangeSummary(startMs: range.fromMs, endMs: range.toMs, model: DemoMode.summaryModels[0],
                                      promptVersion: SummaryPrompt.version, text: summary.text,
                                      createdAtMs: Int64(now.timeIntervalSince1970 * 1000))
      try DB.shared.onQueueSync {
        try DB.shared.openIfNeeded()
        guard let db = DB.shared.db else { return }
        _ = try DB.storeRangeSummary(stored, expectedInvalidations: DB.summaryInvalidationCount(db: db), db: db)
      }
    }
  }
}

extension TimelineRangePreset {
  static func demoPreset(named name: String) -> TimelineRangePreset? {
    switch name {
    case "yesterday": return .yesterday
    case "lastWeek": return .lastWeek
    default: return nil
    }
  }
}
#endif
