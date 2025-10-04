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

    @Test @MainActor func ftsQuery_short_tokens_preserved() async throws {
        let svc = SearchService()
        let q = svc.ftsQuery(for: "go c ui", fuzziness: .medium)
        // All short tokens (<=2) should be present verbatim and not dropped
        #expect(q.contains("go"))
        #expect(q.contains("c"))
        #expect(q.contains("ui"))
    }

    @Test @MainActor func ftsQuery_case_insensitive_lowercased() async throws {
        let svc = SearchService()
        let q = svc.ftsQuery(for: "AI Api aI", fuzziness: .off)
        // Should lowercase everything
        #expect(!q.contains("AI"))
        #expect(q.contains("ai"))
        // tokens preserved individually (AND joined)
        #expect(q.split(separator: " ").contains { $0.contains("ai") })
    }

}

