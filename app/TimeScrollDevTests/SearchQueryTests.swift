//
//  SearchQueryTests.swift
//  TimeScrollDevTests
//

import Testing
@testable import TimeScroll

struct SearchQueryTests {
    @Test @MainActor func ftsQuery_phrase() async throws {
        let svc = SearchService()
        let q = svc.ftsQuery(for: "\"hello world\"", fuzziness: .low)
        #expect(q == "\"hello world\"")
    }

    @Test @MainActor func ftsQuery_tokens_with_prefix() async throws {
        let svc = SearchService()
        let q = svc.ftsQuery(for: "automation hello", fuzziness: .medium)
        // medium fuzziness should prefix-longer tokens with *
        #expect(q.contains("automati*"))
        #expect(q.contains("hello"))
        #expect(q.contains(" AND "))
    }
}

