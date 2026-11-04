import Foundation

/// What the summary providers need from the database, so tests can use a throwaway file instead of
/// `DB.shared`.
protocol SummaryDatabase {
  func read<T>(_ body: (OpaquePointer) throws -> T) throws -> T
  /// Runs `body` atomically; a thrown error rolls it back.
  func write<T>(_ body: (OpaquePointer) throws -> T) throws -> T
  func texts(ids: [Int64]) throws -> [Int64: String]
}

struct SharedSummaryDatabase: SummaryDatabase {
  func read<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try DB.shared.onReadQueueSync(body)
  }

  func write<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try DB.shared.withWriteSavepoint {
      guard let db = DB.shared.db else { throw NSError(domain: "TS.DB", code: 3) }
      return try body(db)
    }
  }

  func texts(ids: [Int64]) throws -> [Int64: String] {
    try DB.shared.sessionTexts(textStoreIds: ids)
  }
}
