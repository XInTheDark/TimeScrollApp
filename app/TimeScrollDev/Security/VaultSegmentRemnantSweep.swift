import CryptoKit
import Foundation

/// Encrypts or removes plaintext `.mov` segments left by older versions while the vault is on
/// (see `VaultSegmentRemnantPlanner`). Runs after unlock on the vault file-migration queue.
/// A plaintext file is removed only after its encrypted copy has been read back and verified.
enum VaultSegmentRemnantSweep {
  static func run(now: Date = Date()) {
    guard StoragePaths.sharedBool(forKey: "settings.vaultEnabled"),
          let referenced = try? DB.shared.referencedSnapshotPaths(withExtension: "mov") else { return }
    let files = StoragePaths.withSecurityScope { () -> [OrphanSegmentPlanner.SegmentFile] in
      let urls = (try? FileManager.default.contentsOfDirectory(at: StoragePaths.videosDir(),
                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [.skipsHiddenFiles])) ?? []
      return urls.compactMap { url in
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return OrphanSegmentPlanner.SegmentFile(url: url, modifiedAt: modified)
      }
    }
    for action in VaultSegmentRemnantPlanner.actions(in: files, referencedPaths: referenced, now: now) {
      do {
        try StoragePaths.withSecurityScope { try apply(action) }
      } catch {
        fputs("[VaultRemnants] plaintext segment retained: \(error.localizedDescription)\n", stderr)
      }
    }
  }

  private static func apply(_ action: VaultSegmentRemnantPlanner.Action) throws {
    switch action {
    case let .removeSealedDuplicate(mov, tse):
      guard let access = VaultMediaAccess.token(for: tse), access.vaultEnabled else { throw locked() }
      if (try? FileCrypter.shared.decryptTSE(at: tse))?.0.mime.hasPrefix("video/") != true {
        // The sealed copy is unreadable; the .mov is the only good copy, so re-seal from it.
        try seal(mov, to: tse, access: access)
      }
      guard VaultMediaAccess.isCurrent(access, for: tse) else { throw locked() }
      try FileManager.default.removeItem(at: mov)
    case let .seal(mov, tse):
      guard let access = VaultMediaAccess.token(for: tse), access.vaultEnabled else { throw locked() }
      try seal(mov, to: tse, access: access)
      guard VaultMediaAccess.isCurrent(access, for: tse) else { throw locked() }
      try FileManager.default.removeItem(at: mov)
    }
  }

  private static func seal(_ mov: URL, to tse: URL, access: VaultMediaAccess.Token) throws {
    let video = try Data(contentsOf: mov)
    let start = HEVCFrameExtractor.startFromSegmentURL(mov) ?? 0
    let blob = try FileCrypter.shared.makeTSEBlob(data: video, timestampMs: start, width: 0, height: 0, mime: "video/quicktime")
    let tmp = tse.appendingPathExtension("tmp")
    try blob.write(to: tmp, options: .atomic)
    do {
      let (_, verified) = try FileCrypter.shared.decryptTSE(at: tmp)
      guard SHA256.hash(data: verified) == SHA256.hash(data: video) else {
        throw NSError(domain: "TimeScroll.VaultRemnants", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encrypted copy failed verification."])
      }
      if FileManager.default.fileExists(atPath: tse.path) {
        _ = try FileManager.default.replaceItemAt(tse, withItemAt: tmp)
      } else {
        try FileManager.default.moveItem(at: tmp, to: tse)
      }
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      throw error
    }
  }

  private static func locked() -> NSError {
    NSError(domain: "TimeScroll.VaultRemnants", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vault locked."])
  }
}
