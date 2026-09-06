import CryptoKit
import Foundation

enum VaultFileMigration {
  struct Record: Codable {
    let snapshotID: Int64
    let timestamp: Int64
    let source: URL
    let destination: URL
    let digest: String
    let mime: String
  }

  private static let queue = DispatchQueue(label: "TimeScroll.Vault.FileMigration", qos: .utility)

  static func schedule() {
    queue.async {
      do {
        try StoragePaths.withSecurityScope { try run() }
      } catch {
        fputs("[VaultMigration] \(error.localizedDescription)\n", stderr)
      }
    }
  }

  private static func run() throws {
    let directory = StoragePaths.vaultDir().appendingPathComponent("FileMigrations", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var pendingSources = Set<URL>()
    for journal in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where journal.pathExtension == "json" {
      do {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: journal))
        pendingSources.insert(record.source)
        try finish(record, journal: journal)
      } catch {
        fputs("[VaultMigration] Pending file retained: \(error.localizedDescription)\n", stderr)
      }
    }
    var afterID: Int64 = 0
    while true {
      guard StoragePaths.sharedBool(forKey: "settings.vaultEnabled"), StoragePaths.sharedBool(forKey: "vault.isUnlocked") else { return }
      let rows = try DB.shared.listPlaintextSnapshots(limit: 100, afterID: afterID)
      if rows.isEmpty { return }
      for row in rows {
        afterID = row.id
        guard StoragePaths.sharedBool(forKey: "settings.vaultEnabled"), StoragePaths.sharedBool(forKey: "vault.isUnlocked") else { return }
        do { try autoreleasepool {
          guard let meta = try DB.shared.snapshotMetaById(row.id), meta.path == row.path else { return }
          let source = URL(fileURLWithPath: row.path)
          guard !pendingSources.contains(source) else { return }
          let data = try Data(contentsOf: source)
          let mime: String
          switch source.pathExtension.lowercased() {
          case "png": mime = "image/png"
          case "jpg", "jpeg": mime = "image/jpeg"
          case "heic": mime = "image/heic"
          case "mov": mime = "video/quicktime"
          case "m4a": mime = "audio/mp4"
          case "caf": mime = "audio/x-caf"
          default: throw failure("Unsupported capture format; original retained.")
          }
          let id = UUID().uuidString
          let destination = source.deletingPathExtension().appendingPathExtension("\(id).tse")
          let record = Record(snapshotID: row.id, timestamp: row.startedAtMs, source: source,
                              destination: destination, digest: digest(data), mime: mime)
          let journal = directory.appendingPathComponent(id + ".json")
          try JSONEncoder().encode(record).write(to: journal, options: .atomic)
          pendingSources.insert(source)
          try finish(record, journal: journal)
        } } catch {
          fputs("[VaultMigration] Snapshot \(row.id) retained: \(error.localizedDescription)\n", stderr)
        }
      }
    }
  }

  static func finish(_ record: Record, journal: URL) throws {
    guard let access = VaultMediaAccess.token(for: record.destination), access.vaultEnabled else {
      throw failure("Unlock the vault to resume file migration.")
    }
    let fm = FileManager.default
    if !fm.fileExists(atPath: record.destination.path) {
      let data = try Data(contentsOf: record.source)
      guard digest(data) == record.digest else { throw failure("Source changed; original retained.") }
      let blob = try FileCrypter.shared.makeTSEBlob(data: data, timestampMs: record.timestamp, width: 0, height: 0, mime: record.mime)
      try blob.write(to: record.destination, options: .atomic)
    }
    let (header, verified) = try FileCrypter.shared.decryptTSE(at: record.destination)
    guard header.mime == record.mime, digest(verified) == record.digest else { throw failure("Encrypted copy failed verification; original retained.") }
    guard VaultMediaAccess.isCurrent(access, for: record.destination) else { throw failure("Vault locked during migration.") }
    let meta = try DB.shared.snapshotMetaById(record.snapshotID)
    if meta?.path == record.source.path {
      try DB.shared.updateSnapshotPath(oldPath: record.source.path, newPath: record.destination.path,
                                       bytes: Int64(try record.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), format: nil)
    } else if meta?.path != record.destination.path {
      throw failure("Snapshot changed during migration; files retained.")
    }
    // Replays after a crash can finish cleanup without repeating the database update.
    guard VaultMediaAccess.isCurrent(access, for: record.destination) else { throw failure("Vault locked during migration.") }
    if fm.fileExists(atPath: record.source.path) {
      guard digest(try Data(contentsOf: record.source)) == record.digest else { throw failure("Source changed; original retained.") }
      try fm.removeItem(at: record.source)
    }
    try fm.removeItem(at: journal)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "TimeScroll.VaultMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
