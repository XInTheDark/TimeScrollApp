import Foundation

/// Database rows turned into segmenter input: interned apps and one sketch per distinct text.
struct SessionInput {
  let samples: [SessionSample]
  let sketches: [[UInt32]]
  /// `ts_text_store` id of each sketch, by sketch index.
  let sketchTextStoreIds: [Int64]
  let apps: [SessionSummarizer.App]
  let fingerprint: SessionDayFingerprint

  init(rows: [SessionSampleRow]) {
    var appIndex: [String: Int32] = [:]
    var apps: [SessionSummarizer.App] = []
    var sketchIndex: [Int64: Int32] = [:]
    var sketches: [[UInt32]] = []
    var sketchTextStoreIds: [Int64] = []
    var textCount = 0
    var sketchedCount = 0
    samples = rows.map { row in
      let key = row.appBundleId ?? row.appName ?? ""
      let app: Int32
      if key.isEmpty {
        app = -1
      } else if let index = appIndex[key] {
        app = index
      } else {
        app = Int32(apps.count)
        appIndex[key] = app
        apps.append(SessionSummarizer.App(bundleId: row.appBundleId, name: row.appName))
      }

      var sketch: Int32 = -1
      if let textStoreId = row.textStoreId {
        textCount += 1
        if let value = row.sketch {
          sketchedCount += 1
          if let index = sketchIndex[textStoreId] {
            sketch = index
          } else if !value.isEmpty {
            sketch = Int32(sketches.count)
            sketchIndex[textStoreId] = sketch
            sketches.append(value)
            sketchTextStoreIds.append(textStoreId)
          }
        }
      }
      return SessionSample(timeMs: row.timeMs, app: app, sketch: sketch)
    }
    self.apps = apps
    self.sketches = sketches
    self.sketchTextStoreIds = sketchTextStoreIds
    fingerprint = SessionDayFingerprint(snapshotCount: rows.count,
                                        maxSnapshotId: rows.map(\.snapshotId).max() ?? 0,
                                        textCount: textCount,
                                        sketchedCount: sketchedCount)
  }
}
