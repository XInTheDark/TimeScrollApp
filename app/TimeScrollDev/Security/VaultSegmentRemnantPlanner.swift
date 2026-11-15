import Foundation

/// Decides what to do with plaintext `.mov` segments found while the vault is on. Older
/// versions recorded each vault segment as a plaintext .mov first and could leave it behind
/// (crash, failed seal or failed removal). Pure, so it is tested without touching real data.
enum VaultSegmentRemnantPlanner {
  enum Action: Equatable {
    /// The sealed .tse exists: verify it, then remove the plaintext copy.
    case removeSealedDuplicate(mov: URL, tse: URL)
    /// No sealed copy: encrypt the .mov into the .tse rows point to, then remove it.
    case seal(mov: URL, tse: URL)
  }

  /// Leaves files written in the last few minutes alone, in case a segment is still being finished.
  static let minimumAge: TimeInterval = 5 * 60

  static func actions(in files: [OrphanSegmentPlanner.SegmentFile],
                      referencedPaths: Set<String>,
                      now: Date) -> [Action] {
    let tseStems = Set(files.compactMap { file -> String? in
      guard file.url.pathExtension.lowercased() == "tse" else { return nil }
      return OrphanSegmentPlanner.stem(ofFileName: file.url.lastPathComponent)
    })
    return files.compactMap { file in
      guard file.url.pathExtension.lowercased() == "mov",
            let stem = OrphanSegmentPlanner.stem(ofFileName: file.url.lastPathComponent),
            now.timeIntervalSince(file.modifiedAt) >= minimumAge,
            // A row that points at the .mov itself is plaintext-era data: VaultFileMigration
            // converts it with a journal and updates the row.
            !referencedPaths.contains(file.url.path) else { return nil }
      let tse = file.url.deletingLastPathComponent().appendingPathComponent(stem + ".tse")
      return tseStems.contains(stem) ? .removeSealedDuplicate(mov: file.url, tse: tse) : .seal(mov: file.url, tse: tse)
    }
  }
}
