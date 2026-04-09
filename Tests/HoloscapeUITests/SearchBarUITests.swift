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

        // Channel should still be responsive after closing search
        assertActiveChannelResponsive(message: "Channel should be responsive after closing search")
    }

    func testCmdFTogglesSearchBar() throws {
        // Open
        openSearch()

        // Toggle off
        app.typeKey("f", modifierFlags: .command)

        // Channel should still be responsive after toggling search off
        assertActiveChannelResponsive(message: "Channel should be responsive after toggling search off")
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
        // Send text to the shell via API so we have content to search
        let channels = try apiListChannels()
        if let label = channels.first?["label"] as? String {
            try apiSendInput(label: label, text: "echo searchable-text-123\n")
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Open search
        openSearch()

        // Type search query
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")
        searchField.typeText("searchable")

        // Verify match count label is present and shows matches
        let label = searchMatchCountText()
        XCTAssertNotNil(label, "Match count label should be visible after typing a search query")
        if let label = label {
            XCTAssertFalse(label.isEmpty, "Match count label should not be empty after searching for existing text")
        }

        // Close search
        closeSearch()
    }

    // MARK: - Empty Query

    func testEmptyQueryShowsNoMatchLabel() throws {
        openSearch()

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.exists, "Search bar should be visible with empty query")

        // With an empty query, match count should be nil or empty
        let label = searchMatchCountText()
        if let label = label {
            XCTAssertTrue(
                label.isEmpty || label.contains("0") || label.lowercased().contains("no"),
                "Empty query should show no matches or empty label, got: \(label)"
            )
        }

        closeSearch()
    }
}
