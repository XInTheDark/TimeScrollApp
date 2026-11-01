import Foundation

/// Pages through search results grouped into sessions. Hits are fetched without text into a growing
/// pool, just far enough to fill the requested page (plus one group, to know a next page exists);
/// only the best hit of each shown group has its text loaded for the snippet.
final class SearchSessionPager: @unchecked Sendable {
  /// Fetches hits without text: `(limit, offset)`.
  typealias Fetch = (_ limit: Int, _ offset: Int) -> [SearchResult]
  /// Sessions for the days holding these times; nil when unavailable (vault locked).
  typealias SessionLookup = (_ times: [Int64]) -> [ActivitySession]?

  struct Page {
    let groups: [SearchSessionGroup]
    let hasNext: Bool
  }

  static let firstChunk = 64
  static let maxChunk = 512
  static let maxPool = 4_000

  private let fetch: Fetch
  private let sessionsFor: SessionLookup
  private let queue = DispatchQueue(label: "TimeScroll.SearchSessionPager", qos: .userInitiated)
  private var pool: [SearchResult] = []
  private var exhausted = false
  private var groups: [SearchSessionGroup] = []

  init(fetch: @escaping Fetch, sessionsFor: @escaping SessionLookup) {
    self.fetch = fetch
    self.sessionsFor = sessionsFor
  }

  /// Groups of page `index`; runs on the pager's queue, delivers on the main queue.
  func page(_ index: Int, size: Int, completion: @escaping (Page) -> Void) {
    queue.async { [self] in
      let page = pageSync(index, size: size)
      DispatchQueue.main.async { completion(page) }
    }
  }

  /// Blocking variant for tests and callers already off the main thread.
  func pageSync(_ index: Int, size: Int) -> Page {
    let needed = (index + 1) * size + 1
    var chunk = Self.firstChunk
    while groups.count < needed, !exhausted, pool.count < Self.maxPool {
      let limit = min(chunk, Self.maxPool - pool.count)
      let fetched = fetch(limit, pool.count)
      pool += fetched
      if fetched.count < limit { exhausted = true }
      let sessions = sessionsFor(pool.map(\.startedAtMs)) ?? []
      groups = SearchSessionGrouper.group(pool, sessions: sessions)
      chunk = min(Self.maxChunk, chunk * 2)
    }
    let start = min(groups.count, index * size)
    let end = min(groups.count, start + size)
    return Page(groups: Array(groups[start..<end]), hasNext: groups.count > end)
  }
}

extension SearchResult {
  /// A hit without its text; the text is loaded later for the hits that are shown.
  init(meta: SnapshotMeta) {
    self.init(id: meta.id, startedAtMs: meta.startedAtMs, endedAtMs: meta.endedAtMs, path: meta.path,
              appBundleId: meta.appBundleId, appName: meta.appName, thumbPath: meta.thumbPath,
              captureKind: meta.captureKind, audioSourceKind: meta.audioSourceKind,
              audioAssetId: meta.audioAssetId, audioDurationMs: meta.audioDurationMs, content: "")
  }
}
