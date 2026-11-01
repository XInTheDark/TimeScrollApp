import Foundation
import Testing
@testable import TimeScroll

struct OrphanSegmentPlannerTests {
  private typealias File = OrphanSegmentPlanner.SegmentFile
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private var old: Date { now.addingTimeInterval(-OrphanSegmentPlanner.minimumAge - 1) }

  private func file(_ name: String, modifiedAt: Date? = nil) -> File {
    File(url: URL(fileURLWithPath: "/data/Videos/\(name)"), modifiedAt: modifiedAt ?? old)
  }

  private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

  // MARK: - Stem

  @Test func stemOfMovAndTseIsTheSame() {
    #expect(OrphanSegmentPlanner.stem(ofFileName: "seg-2026-10-30-21-00-00-d1.mov") == "seg-2026-10-30-21-00-00-d1")
    #expect(OrphanSegmentPlanner.stem(ofFileName: "seg-2026-10-30-21-00-00-d1.tse") == "seg-2026-10-30-21-00-00-d1")
    #expect(OrphanSegmentPlanner.stem(ofFileName: "seg-2025-11-30-11-44-00.MOV") == "seg-2025-11-30-11-44-00")
  }

  @Test func nonSegmentFilesHaveNoStem() {
    #expect(OrphanSegmentPlanner.stem(ofFileName: "seg-2026-10-30-21-00-00.mov.tmp") == nil)
    #expect(OrphanSegmentPlanner.stem(ofFileName: "snap-2026-10-30.heic") == nil)
    #expect(OrphanSegmentPlanner.stem(ofFileName: "seg-2026-10-30-21-00-00.mp4") == nil)
    #expect(OrphanSegmentPlanner.stem(ofFileName: ".DS_Store") == nil)
    #expect(OrphanSegmentPlanner.stem(ofFileName: "") == nil)
  }

  // MARK: - Orphans

  @Test func emptyFolderHasNoOrphans() {
    #expect(OrphanSegmentPlanner.orphans(in: [], referencedStems: ["seg-a"], now: now).isEmpty)
  }

  @Test func allReferencedMeansNothingRemoved() {
    let files = [file("seg-a.mov"), file("seg-b.tse")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-b"], now: now).isEmpty)
  }

  @Test func unreferencedOldSegmentIsOrphan() {
    let files = [file("seg-a.mov"), file("seg-b.mov"), file("seg-c.mov")]
    #expect(names(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-c"], now: now)) == ["seg-b.mov"])
  }

  @Test func retainedLiveMovBesideReferencedTseIsKept() {
    // Failed sealing keeps the live .mov; the row may point at the .tse (or the reverse).
    let files = [file("seg-a.tse"), file("seg-a.mov"), file("seg-b.mov"), file("seg-b.tse")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-b"], now: now).isEmpty)
  }

  @Test func recentSegmentIsKeptEvenIfUnreferenced() {
    let files = [
      file("seg-a.mov"),
      file("seg-b.mov"),
      file("seg-open.mov", modifiedAt: now.addingTimeInterval(-60)),
      file("seg-edge.mov", modifiedAt: now.addingTimeInterval(-OrphanSegmentPlanner.minimumAge + 1)),
    ]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-b"], now: now).isEmpty)
  }

  @Test func futureModificationDateIsKept() {
    // A clock change can leave mtimes ahead of "now".
    let files = [file("seg-a.mov"), file("seg-b.mov"), file("seg-c.mov", modifiedAt: now.addingTimeInterval(3600))]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-b"], now: now).isEmpty)
  }

  @Test func displaysAreMatchedSeparately() {
    let files = [file("seg-t-d1.mov"), file("seg-t-d2.mov"), file("seg-t.mov"), file("seg-u-d1.mov")]
    let orphans = OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-t-d1", "seg-t", "seg-u-d1"], now: now)
    #expect(names(orphans) == ["seg-t-d2.mov"])
  }

  @Test func otherFilesInFolderAreNeverTouched() {
    let files = [file("seg-a.mov"), file("notes.txt"), file("seg-a.mov.tmp"), file(".DS_Store")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a"], now: now).isEmpty)
  }

  @Test func noReferencesMeansNothingRemoved() {
    // An empty or unreadable database must never turn every segment into an orphan.
    let files = [file("seg-a.mov"), file("seg-b.mov")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: [], now: now).isEmpty)
  }

  @Test func halfOrphanedIsStillCleaned() {
    let files = [file("seg-a.mov"), file("seg-b.mov"), file("seg-c.mov"), file("seg-d.mov")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-b"], now: now).count == 2)
  }

  @Test func mostlyOrphanedLooksLikeDamagedDatabaseSoNothingIsRemoved() {
    let files = [file("seg-a.mov"), file("seg-b.mov"), file("seg-c.mov")]
    #expect(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a"], now: now).isEmpty)
  }

  @Test func referencesToFilesNotOnDiskDoNotMatter() {
    let files = [file("seg-a.mov"), file("seg-b.mov")]
    #expect(names(OrphanSegmentPlanner.orphans(in: files, referencedStems: ["seg-a", "seg-gone", "seg-gone2"], now: now)) == ["seg-b.mov"])
  }

  @Test func hundredThousandSegmentsPlanQuickly() {
    let files = (0..<100_000).map { file("seg-\($0).mov") }
    let referenced = Set((0..<100_000).filter { $0 % 10 != 0 }.map { "seg-\($0)" })
    let start = Date()
    let orphans = OrphanSegmentPlanner.orphans(in: files, referencedStems: referenced, now: now)
    let elapsed = Date().timeIntervalSince(start)
    #expect(orphans.count == 10_000)
    print("[OrphanSegmentPlannerTests] 100k files planned in \(String(format: "%.1f", elapsed * 1000)) ms")
    #expect(elapsed < 2.0)
  }
}
