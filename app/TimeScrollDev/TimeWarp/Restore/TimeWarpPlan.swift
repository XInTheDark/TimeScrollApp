import Foundation

/// The groups the Time Warp sheet shows, in order.
enum TimeWarpGroup: String, CaseIterable, Identifiable, Sendable {
  case pages, documents, folders, apps

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pages: return "Pages"
    case .documents: return "Documents"
    case .folders: return "Folders"
    case .apps: return "Apps"
    }
  }

  init?(kind: TimeWarpItemKind) {
    switch kind {
    case .page: self = .pages
    case .document: self = .documents
    case .folder: self = .folders
    case .app: self = .apps
    case .warpPoint: return nil
    }
  }
}

/// Which items a Time Warp offers.
enum TimeWarpScope: String, CaseIterable, Identifiable, Sendable {
  /// What was in front during the block.
  case visited
  /// Also everything that was open (background tabs and windows) at the end of the block.
  case everythingOpen

  var id: String { rawValue }
}

/// One thing that can be reopened.
struct TimeWarpPlanItem: Identifiable, Hashable, Sendable {
  let kind: TimeWarpItemKind
  let value: String
  let title: String?
  /// The app it was used in: the one it spent the most time in front of, or the one that had it open.
  let appBundleId: String?
  /// Time in front within the block.
  let frontMs: Int64
  /// Separate times it came to the front.
  let visits: Int
  let lastSeenMs: Int64
  /// Open in the background at the end of the block (recorded only with "everything that's open").
  let wasOpenAtEnd: Bool
  /// In front at the moment of a moment's Time Warp, or last before it.
  var wasFrontAtMoment = false
  /// Time in front weighted toward the moment (`TimeWarpRecency`); 0 for a block.
  var momentScore: Double = 0

  var id: String { "\(kind.rawValue):\(value)" }
}

/// A note the user left during the block.
struct TimeWarpPointNote: Identifiable, Hashable, Sendable {
  let timeMs: Int64
  let note: String
  let appBundleId: String?

  var id: String { "\(timeMs):\(note)" }
}

/// Everything a Time Warp can offer for one block.
struct TimeWarpPlan: Equatable, Sendable {
  let fromMs: Int64
  let toMs: Int64
  let scope: TimeWarpScope
  /// Set when the block is a moment's look-back.
  var momentMs: Int64? = nil
  let groups: [TimeWarpGroup: [TimeWarpPlanItem]]
  let notes: [TimeWarpPointNote]
  /// Whether anything open in the background was recorded in this block.
  let hasOpenItems: Bool

  static func empty(fromMs: Int64, toMs: Int64, scope: TimeWarpScope) -> TimeWarpPlan {
    TimeWarpPlan(fromMs: fromMs, toMs: toMs, scope: scope, groups: [:], notes: [], hasOpenItems: false)
  }

  var isEmpty: Bool { groups.values.allSatisfy(\.isEmpty) && notes.isEmpty }

  func items(in group: TimeWarpGroup) -> [TimeWarpPlanItem] { groups[group] ?? [] }
}
