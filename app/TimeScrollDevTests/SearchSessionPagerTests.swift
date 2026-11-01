import Foundation
import Testing
@testable import TimeScroll

struct SearchSessionPagerTests {
  /// Hits newest first; the stub records each fetch.
  private final class Source: @unchecked Sendable {
    let hits: [SearchResult]
    var limits: [Int] = []
    var offsets: [Int] = []
    var lookups = 0
    init(_ hits: [SearchResult]) { self.hits = hits }

    func fetch(_ limit: Int, _ offset: Int) -> [SearchResult] {
      limits.append(limit)
      offsets.append(offset)
      guard offset < hits.count else { return [] }
      return Array(hits[offset..<min(hits.count, offset + limit)])
    }
  }

  private func pager(_ source: Source, sessions: [ActivitySession]?) -> SearchSessionPager {
    SearchSessionPager(fetch: source.fetch, sessionsFor: { _ in
      source.lookups += 1
      return sessions
    })
  }

  /// `count` sessions of `perSession` hits each, newest first, sessions one hour apart.
  private func fixture(sessions count: Int, perSession: Int) -> ([SearchResult], [ActivitySession]) {
    var hits: [SearchResult] = []
    var sessions: [ActivitySession] = []
    for index in 0..<count {
      let start = Int64(index) * 3_600_000
      sessions.append(SearchSessionGrouperTests.session(Int64(index + 1), start, start + 600_000))
    }
    for index in (0..<count).reversed() {
      for hit in (0..<perSession).reversed() {
        let time = Int64(index) * 3_600_000 + Int64(hit) * 1_000
        hits.append(SearchSessionGrouperTests.hit(Int64(index * perSession + hit + 1), at: time))
      }
    }
    return (hits, sessions)
  }

  @Test func noHitsGiveAnEmptyLastPage() {
    let source = Source([])
    let page = pager(source, sessions: []).pageSync(0, size: 20)
    #expect(page.groups.isEmpty)
    #expect(!page.hasNext)
    #expect(source.limits == [SearchSessionPager.firstChunk])
  }

  @Test func fewHitsAreFetchedOnce() {
    let (hits, sessions) = fixture(sessions: 3, perSession: 5)
    let source = Source(hits)
    let page = pager(source, sessions: sessions).pageSync(0, size: 20)
    #expect(page.groups.map(\.session?.id) == [3, 2, 1])
    #expect(page.groups.allSatisfy { $0.hits.count == 5 })
    #expect(!page.hasNext)
    #expect(source.limits.count == 1)
  }

  @Test func poolGrowsInDoublingChunksUntilThePageIsFull() {
    let (hits, sessions) = fixture(sessions: 30, perSession: 40)
    let source = Source(hits)
    let page = pager(source, sessions: sessions).pageSync(0, size: 20)
    #expect(page.groups.count == 20)
    #expect(page.hasNext)
    // 21 groups (one past the page) need 801 hits: 64 + 128 + 256 + 512.
    #expect(source.limits == [64, 128, 256, 512])
    #expect(source.offsets == [0, 64, 192, 448])
  }

  @Test func laterPagesContinueFromThePool() {
    let (hits, sessions) = fixture(sessions: 30, perSession: 10)
    let source = Source(hits)
    let pager = pager(source, sessions: sessions)
    let first = pager.pageSync(0, size: 20)
    let fetchesAfterFirst = source.limits.count
    let second = pager.pageSync(1, size: 20)
    #expect(first.groups.map(\.session?.id) == Array((11...30).reversed()).map(Int64.init))
    #expect(second.groups.map(\.session?.id) == Array((1...10).reversed()).map(Int64.init))
    #expect(!second.hasNext)
    #expect(source.offsets.dropFirst(fetchesAfterFirst).allSatisfy { $0 > 0 })
    // Going back is served from the pool.
    let fetches = source.limits.count
    #expect(pager.pageSync(0, size: 20).groups == first.groups)
    #expect(source.limits.count == fetches)
  }

  @Test func pageBeyondTheEndIsEmpty() {
    let (hits, sessions) = fixture(sessions: 2, perSession: 3)
    let page = pager(Source(hits), sessions: sessions).pageSync(5, size: 20)
    #expect(page.groups.isEmpty)
    #expect(!page.hasNext)
  }

  @Test func withoutSessionsEveryHitIsItsOwnGroup() {
    let (hits, _) = fixture(sessions: 2, perSession: 30)
    let page = pager(Source(hits), sessions: nil).pageSync(0, size: 20)
    #expect(page.groups.count == 20)
    #expect(page.groups.allSatisfy { $0.session == nil && $0.hits.count == 1 })
    #expect(page.hasNext)
  }

  @Test func poolStopsAtItsCap() {
    // One endless session: fetching never fills a second group.
    let session = SearchSessionGrouperTests.session(1, 0, .max / 2)
    let hits = (0..<10_000).map { SearchSessionGrouperTests.hit(Int64($0), at: Int64(10_000 - $0)) }
    let source = Source(hits)
    let page = pager(source, sessions: [session]).pageSync(0, size: 20)
    #expect(page.groups.count == 1)
    #expect(page.groups[0].hits.count == SearchSessionPager.maxPool)
    #expect(!page.hasNext)
    #expect(source.limits.reduce(0, +) == SearchSessionPager.maxPool)
    #expect(source.limits.allSatisfy { $0 <= SearchSessionPager.maxChunk })
  }

  @Test func asyncPageArrivesOnTheMainQueue() async {
    let (hits, sessions) = fixture(sessions: 2, perSession: 2)
    let pager = pager(Source(hits), sessions: sessions)
    let onMain = await withCheckedContinuation { continuation in
      pager.page(0, size: 20) { page in continuation.resume(returning: Thread.isMainThread && page.groups.count == 2) }
    }
    #expect(onMain)
  }
}
