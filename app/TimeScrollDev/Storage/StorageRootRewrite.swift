import Foundation

/// Media-path rewrites owed after a storage move. Each move is recorded before files move, and
/// stays recorded until the open database (and the vault's migration journals) point at the
/// new root, so a failed or interrupted rewrite is finished on a later open instead of leaving
/// rows pointing at the old folder.
enum StorageRootRewrite {
  struct Move: Codable, Equatable {
    let oldRoot: String
    let newRoot: String
  }

  private static let key = "storage.pendingRootRewrites"

  static func record(oldRoot: String, newRoot: String, defaults: UserDefaults = .standard) {
    var moves = pending(defaults: defaults)
    moves.append(Move(oldRoot: oldRoot, newRoot: newRoot))
    save(moves, defaults: defaults)
  }

  static func pending(defaults: UserDefaults = .standard) -> [Move] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([Move].self, from: data)) ?? []
  }

  /// Applies pending moves, oldest first, to the open database. Returns false when a move is
  /// still owed (database not open, or the update failed).
  @discardableResult
  static func applyPending(defaults: UserDefaults = .standard,
                           rewrite: (Move) throws -> Void = applyToDatabaseAndJournals) -> Bool {
    var moves = pending(defaults: defaults)
    while let move = moves.first {
      do {
        try rewrite(move)
      } catch {
        fputs("[Storage] path rewrite pending: \(error.localizedDescription)\n", stderr)
        return false
      }
      moves.removeFirst()
      save(moves, defaults: defaults)
    }
    return true
  }

  static func applyToDatabaseAndJournals(_ move: Move) throws {
    try DB.shared.rewriteMediaPathsAfterRootMove(oldRoot: move.oldRoot, newRoot: move.newRoot)
    try StoragePaths.withSecurityScope { try rewriteJournals(move, in: VaultFileMigration.journalDirectory()) }
  }

  /// Points interrupted vault file-migration journals at the moved files.
  static func rewriteJournals(_ move: Move, in directory: URL) throws {
    let fm = FileManager.default
    guard let journals = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    for journal in journals where journal.pathExtension == "json" {
      let record = try JSONDecoder().decode(VaultFileMigration.Record.self, from: Data(contentsOf: journal))
      let moved = VaultFileMigration.Record(snapshotID: record.snapshotID,
                                            timestamp: record.timestamp,
                                            source: relocate(record.source, move),
                                            destination: relocate(record.destination, move),
                                            digest: record.digest,
                                            mime: record.mime)
      guard moved.source != record.source || moved.destination != record.destination else { continue }
      try JSONEncoder().encode(moved).write(to: journal, options: .atomic)
    }
  }

  static func relocate(_ url: URL, _ move: Move) -> URL {
    let oldPrefix = move.oldRoot.hasSuffix("/") ? move.oldRoot : move.oldRoot + "/"
    let newPrefix = move.newRoot.hasSuffix("/") ? move.newRoot : move.newRoot + "/"
    guard url.path.hasPrefix(oldPrefix) else { return url }
    return URL(fileURLWithPath: newPrefix + url.path.dropFirst(oldPrefix.count))
  }

  private static func save(_ moves: [Move], defaults: UserDefaults) {
    if moves.isEmpty {
      defaults.removeObject(forKey: key)
    } else if let data = try? JSONEncoder().encode(moves) {
      defaults.set(data, forKey: key)
    }
  }
}
