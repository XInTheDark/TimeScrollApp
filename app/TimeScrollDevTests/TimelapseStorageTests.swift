import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

@Suite(.serialized)
struct TimelapseStorageTests {
  @Test func pagesAreStableAtTiesAndExcludeAudioAndNewCaptures() throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
    let handle = try #require(db)
    defer { sqlite3_close(handle) }
    #expect(sqlite3_exec(handle, """
      CREATE TABLE ts_snapshot(id INTEGER PRIMARY KEY, started_at_ms INTEGER, path TEXT, format TEXT, capture_kind TEXT, width INTEGER, height INTEGER, thumb_path TEXT);
      INSERT INTO ts_snapshot VALUES(1, 1000, 'a.png', 'png', 'screen', 1920, 1080, NULL), (2, 1000, 'b.mov', 'hevc', 'screen', 1920, 1080, NULL),
      (3, 2000, 'audio', NULL, 'audio', NULL, NULL, NULL), (4, 3000, 'c.tse', 'hevc', 'screen', 2560, 1440, NULL),
      (5, 4000, 'later.png', 'png', 'screen', 640, 480, NULL), (6, 1000, 'new.png', 'png', 'screen', 1920, 1080, NULL);
      """, nil, nil, nil) == SQLITE_OK)
    func page(_ after: TimelapseFrame?) throws -> [TimelapseFrame] {
      try DB.timelapseFrames(fromMs: 1000, toMs: 3000, throughID: 5, after: after, limit: 1, db: handle)
    }
    let first = try page(nil)
    #expect(first.map(\.id) == [1])
    let second = try page(first.last)
    #expect(second.map(\.id) == [2])
    let third = try page(second.last)
    #expect(third.map(\.id) == [4])
    #expect(third.first?.format == "hevc")
    #expect(try page(third.last).isEmpty)
    #expect(try DB.timelapseFrames(fromMs: 5000, toMs: 6000, throughID: 5, after: nil, limit: 256, db: handle).isEmpty)
    let summary = try DB.timelapseSummary(fromMs: 1000, toMs: 3000, db: handle)
    #expect(summary.count == 4)
    #expect(summary.maxID == 6)
    #expect(summary.width == 2560 && summary.height == 1440)
    #expect(try DB.timelapseSummary(fromMs: 5000, toMs: 6000, db: handle).count == 0)
  }

  @Test func recordingIntervalsClipMergeAndResolveOpenSessions() throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
    let handle = try #require(db)
    defer { sqlite3_close(handle) }
    #expect(sqlite3_exec(handle, """
      CREATE TABLE ts_usage_session(id INTEGER PRIMARY KEY, start_s REAL, end_s REAL);
      INSERT INTO ts_usage_session VALUES(1, 0, 10), (2, 8, 12), (3, 30, 32), (4, 40, NULL), (5, 70, 80), (6, 35, 34);
      """, nil, nil, nil) == SQLITE_OK)
    #expect(try DB.timelapseRecordingIntervals(fromMs: 5000, toMs: 50000, db: handle) == [5000...12000, 30000...32000, 40000...50000])
    #expect(try DB.timelapseRecordingIntervals(fromMs: 13000, toMs: 29000, db: handle).isEmpty)
  }
}
