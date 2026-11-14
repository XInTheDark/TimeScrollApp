import Foundation

/// What a Time Warp record points at.
enum TimeWarpItemKind: String, CaseIterable, Sendable {
  case page
  case document
  case folder
  case app
  case warpPoint

  /// The namespace its value is stored under; documents and folders share file paths.
  var valueDomain: TimeWarpValueDomain {
    switch self {
    case .page: return .url
    case .document, .folder: return .path
    case .app: return .app
    case .warpPoint: return .note
    }
  }
}

/// How an item was recorded.
enum TimeWarpSource: String, Sendable {
  /// It was in the frontmost window.
  case front
  /// It was open, for example a background tab or another document window.
  case open
  /// A single moment: a Warp point.
  case event
}

/// Namespaces of stored strings, so the same text in different roles stays separate.
enum TimeWarpValueDomain: String, Sendable {
  case url, path, app, title, note
}

/// One thing Time Warp can record: a page, file, folder, app or note.
struct TimeWarpItem: Hashable, Sendable {
  let kind: TimeWarpItemKind
  /// URL string, file path, bundle id or note text.
  let value: String
  /// Page or window title. Not part of the item's identity: titles change while the item stays.
  var title: String?

  static func == (lhs: TimeWarpItem, rhs: TimeWarpItem) -> Bool {
    lhs.kind == rhs.kind && lhs.value == rhs.value
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(kind)
    hasher.combine(value)
  }
}

/// A stored record: an item and when it was seen.
struct TimeWarpSpanRecord: Equatable, Sendable {
  let kind: TimeWarpItemKind
  let source: TimeWarpSource
  let value: String
  let title: String?
  let appBundleId: String?
  let startMs: Int64
  let endMs: Int64
}
