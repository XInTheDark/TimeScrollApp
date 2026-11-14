import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

final class TimeWarpPointQueryTests {
  private let database: TimeWarpTestDatabase

  init() throws {
    database = try TimeWarpTestDatabase()
  }

  @Test func returnsOnlyWarpPointsInTheRangeOldestFirst() {
    database.add("later", kind: .warpPoint, source: .event, app: "com.b", start: 3_000, end: 3_000)
    database.add("first", kind: .warpPoint, source: .event, app: "com.a", start: 1_000, end: 1_000)
    database.add("", kind: .warpPoint, source: .event, app: nil, start: 2_000, end: 2_000)
    database.add("outside", kind: .warpPoint, source: .event, start: 9_000, end: 9_000)
    database.add("https://page/", start: 1_500, end: 2_500)
    let points = DB.timeWarpPoints(fromMs: 1_000, toMs: 9_000, db: database.db)
    #expect(points.map(\.note) == ["first", "", "later"])
    #expect(points.map(\.timeMs) == [1_000, 2_000, 3_000])
    #expect(points.first?.appBundleId == "com.a")
    #expect(points[1].appBundleId == nil)
  }

  @Test func emptyRangeHasNone() {
    database.add("note", kind: .warpPoint, source: .event, start: 1_000, end: 1_000)
    #expect(DB.timeWarpPoints(fromMs: 2_000, toMs: 3_000, db: database.db).isEmpty)
    #expect(DB.timeWarpPoints(fromMs: 1_000, toMs: 1_000, db: database.db).isEmpty)
  }

  @Test func readsThroughTheWarpPointIndex() {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "EXPLAIN QUERY PLAN SELECT s.start_ms FROM ts_tw_span s WHERE s.kind = 'warpPoint' AND s.start_ms >= 0 AND s.start_ms < 10 ORDER BY s.start_ms;"
    #expect(sqlite3_prepare_v2(database.db, sql, -1, &stmt, nil) == SQLITE_OK)
    var details: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW { details.append(String(cString: sqlite3_column_text(stmt, 3))) }
    #expect(details.contains { $0.contains("idx_ts_tw_span_warp_point") }, "plan: \(details)")
  }

  @Test func manySpansStayFast() {
    database.exec("BEGIN;")
    for index in 0..<100_000 {
      database.add("https://p\(index % 500)/", start: Int64(index) * 1_000, end: Int64(index) * 1_000 + 900)
      if index % 1_000 == 0 {
        database.add("note \(index)", kind: .warpPoint, source: .event, start: Int64(index) * 1_000, end: Int64(index) * 1_000)
      }
    }
    database.exec("COMMIT;")
    let started = Date()
    let points = DB.timeWarpPoints(fromMs: 0, toMs: 100_000_000, db: database.db)
    let elapsed = Date().timeIntervalSince(started)
    #expect(points.count == 100)
    #expect(elapsed < 0.05, "took \(elapsed) s")
  }
}
