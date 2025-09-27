//
//  SearchFlowUITests.swift
//  TimeScrollDevUITests
//

import XCTest

final class SearchFlowUITests: XCTestCase {
    @MainActor
    func test_open_close_search_restores_timeline() throws {
        let app = XCUIApplication()
        app.launch()
        let searchField = app.textFields["Search snapshots"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("hello")
        // Invoke Search (Return)
        app.typeKey(.return, modifierFlags: [])
        // Close via Close button if present
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }
        // Ensure timeline base UI exists (e.g., Live toggle)
        XCTAssertTrue(app.switches["Live"].exists)
    }

    @MainActor
    func test_blank_query_routes_to_latest() throws {
        let app = XCUIApplication()
        app.launch()
        let searchField = app.textFields["Search snapshots"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("hello")
        app.typeKey(.return, modifierFlags: [])
        // Clear the field
        for _ in 0..<5 { app.typeKey(.delete, modifierFlags: []) }
        // After debounce, list should switch away from search view; verify Live toggle exists
        XCTAssertTrue(app.switches["Live"].waitForExistence(timeout: 2))
    }
}

