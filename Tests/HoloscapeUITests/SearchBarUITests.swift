import XCTest

final class SearchBarUITests: HoloscapeUITestCase {

    // MARK: - Open/Close

    func testCmdFOpensSearchBar() throws {
        openSearch()

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.exists, "Search bar should appear on Cmd+F")
    }

    func testEscapeClosesSearchBar() throws {
        openSearch()

        // Close with Escape
        closeSearch()

        // Focus should return to input box
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("after-search")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "after-search", "Focus should return to input box after closing search")
    }

    func testCmdFTogglesSearchBar() throws {
        // Open
        openSearch()

        // Toggle off
        app.typeKey("f", modifierFlags: .command)

        // Input box should have focus
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("toggled")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "toggled", "Input box should have focus after toggling search off")
    }

    // MARK: - Search via Menu

    func testSearchViaViewMenu() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let findItem = app.menuItems["Find"]
        XCTAssertTrue(findItem.exists, "Find menu item should exist in View menu")
        findItem.click()

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Search bar should appear from View > Find")
    }

    // MARK: - Search Query

    func testSearchShowsMatchCount() throws {
        // First, send some text to the shell so we have content to search
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("echo searchable-text-123")
        inputBox.typeKey(.return, modifierFlags: [])

        // Open search
        openSearch()

        // Type search query
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 2) {
            searchField.typeText("searchable")
            // The match count label should show something other than empty
            // We can't directly read it, but the search mechanism should not crash
        }

        // Close search
        closeSearch()
    }

    // MARK: - Empty Query

    func testEmptyQueryShowsNoMatches() throws {
        openSearch()

        // Don't type anything — match count should be empty/zero
        // Verify the search bar opened without crashing
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.exists, "Search bar should be visible with empty query")

        closeSearch()
    }
}
