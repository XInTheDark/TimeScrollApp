//
//  TimelineModeTests.swift
//  TimeScrollDevTests
//

import Testing
@testable import TimeScroll

struct TimelineModeTests {
    @Test @MainActor func mode_switches_on_query_change() async throws {
        let vm = TimelineModel()
        #expect({ if case .latest = vm.mode { return true } else { return false } }())
        vm.onQueryChanged("hello")
        #expect({ if case .searching = vm.mode { return true } else { return false } }())
        vm.onQueryChanged("")
        #expect({ if case .latest = vm.mode { return true } else { return false } }())
    }
}

