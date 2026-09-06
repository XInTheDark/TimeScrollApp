//
//  TimelineModeTests.swift
//  TimeScrollDevTests
//

import Testing
@testable import TimeScroll

struct TimelineModeTests {
    @Test @MainActor func query_tracks_applied_search_text() {
        let vm = TimelineModel()
        #expect(vm.query.isEmpty)
        vm.query = "hello"
        #expect(vm.query == "hello")
        vm.query = ""
        #expect(vm.query.isEmpty)
    }
}
