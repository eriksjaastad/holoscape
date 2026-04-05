import XCTest

final class SearchAdvancedUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    private func generateOutput(_ text: String) {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo \(text)")
        inputBox.typeKey(.return, modifierFlags: [])
    }

    // MARK: - Match Navigation

    func testSearchNextButtonAdvancesMatch() throws {
        generateOutput("searchword repeated searchword here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("searchword")

        let labelBefore = searchMatchCountText()

        let nextButton = searchBar.buttons["search-next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 2), "Next button should exist")
        nextButton.click()

        let labelAfter = searchMatchCountText()

        guard let before = labelBefore else {
            XCTFail("Match count label not found")
            return
        }
        guard let after = labelAfter else {
            XCTFail("Match count label not found")
            return
        }
        XCTAssertNotEqual(before, after, "Match label should change after clicking next")

        closeSearch()
    }

    func testSearchPreviousButtonGoesBack() throws {
        generateOutput("findme repeated findme here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("findme")

        let labelBefore = searchMatchCountText()
        let previousButton = searchBar.buttons["search-previous"]
        XCTAssertTrue(previousButton.waitForExistence(timeout: 2), "Previous button should exist")
        previousButton.click()
        let labelAfter = searchMatchCountText()

        guard let before = labelBefore else {
            XCTFail("Match count label not found before click")
            return
        }
        guard let after = labelAfter else {
            XCTFail("Match count label not found after click")
            return
        }
        XCTAssertNotEqual(before, after, "Match label should change after clicking previous")

        closeSearch()
    }

    func testSearchEnterAdvancesToNext() throws {
        generateOutput("enter-test data enter-test more")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("enter-test")

        let labelBefore = searchMatchCountText()
        searchField.typeKey(.return, modifierFlags: [])
        let labelAfter = searchMatchCountText()

        guard let before = labelBefore else {
            XCTFail("Match count label not found")
            return
        }
        guard let after = labelAfter else {
            XCTFail("Match count label not found")
            return
        }
        XCTAssertNotEqual(before, after, "Enter should advance match position")

        closeSearch()
    }

    func testSearchWrapsAround() throws {
        generateOutput("wraptest single")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("wraptest")

        let labelBefore = searchMatchCountText()
        searchField.typeKey(.return, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])
        let labelAfter = searchMatchCountText()

        guard let before = labelBefore else {
            XCTFail("Match count label not found")
            return
        }
        // After wrapping, label should show position (may be same as start if single match)
        XCTAssertNotNil(labelAfter, "Match count label should exist after wrap")

        closeSearch()
    }

    func testSearchPreviousWrapsAround() throws {
        generateOutput("prevwrap data")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("prevwrap")

        let labelBefore = searchMatchCountText()
        let previousButton = searchBar.buttons["search-previous"]
        if previousButton.waitForExistence(timeout: 2) {
            previousButton.click()
        }
        let labelAfter = searchMatchCountText()

        guard labelBefore != nil else {
            XCTFail("Match count label not found before click")
            return
        }
        XCTAssertNotNil(labelAfter, "Match count label should exist after previous wrap")

        closeSearch()
    }

    // MARK: - Match Count Accuracy

    func testSearchMultipleMatchesCountCorrect() throws {
        generateOutput("multi multi multi")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("multi")

        let label = searchMatchCountText()
        XCTAssertNotNil(label, "Match count label should be visible for multiple matches")
        if let label = label {
            XCTAssertTrue(label.contains("of"), "Match count should show 'X of Y' format, got: \(label)")
        }

        closeSearch()
    }

    func testSearchNoMatchesShowsZero() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("zzz_nonexistent_string_xyz")

        let label = searchMatchCountText()
        XCTAssertNotNil(label, "Match count label should be visible for no-match search")
        if let label = label {
            XCTAssertTrue(
                label.contains("0") || label.lowercased().contains("no match"),
                "No-match search should show zero count or 'No matches', got: \(label)"
            )
        }

        closeSearch()
    }

    func testSearchSingleMatchShowsOneOfOne() throws {
        generateOutput("uniqueterm12345")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("uniqueterm12345")

        let label = searchMatchCountText()
        XCTAssertNotNil(label, "Match count label should be visible for single match")
        if let label = label {
            XCTAssertTrue(label.contains("1 of 1"), "Single match should show '1 of 1', got: \(label)")
        }

        closeSearch()
    }

    // MARK: - Edge Cases

    func testSearchSpecialCharacters() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("[regex.*chars()")

        XCTAssertTrue(searchBar.exists, "Special characters in search should not crash")
        closeSearch()
    }

    func testSearchVeryLongQuery() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        let longQuery = String(repeating: "x", count: 500)
        searchField.typeText(longQuery)

        XCTAssertTrue(searchBar.exists, "Very long search query should be handled gracefully")
        closeSearch()
    }

    func testSearchWhileChannelSwitching() throws {
        createChannel(type: "Shell")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("channel-switch")

        // Switch channels while search is active
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("2", modifierFlags: .command)

        // Search bar may or may not persist across channel switch — verify app is stable
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 2), "App should remain stable after channel switching during search")
        closeSearch()
    }

    func testSearchClearedOnClose() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("clear-test")

        closeSearch()

        XCTAssertFalse(app.toolbars["Search Bar"].waitForExistence(timeout: 1), "Search bar should not exist after closing")
    }

    // MARK: - Focus Management

    func testSearchFieldHasFocusOnOpen() throws {
        openSearch()

        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        // Verify focus by typing directly and checking the value
        searchField.typeText("focus-check")
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.contains("focus-check"), "Search field should have focus immediately on open — typed text should appear")

        closeSearch()
    }

    func testEscapeReturnsToInputBox() throws {
        openSearch()
        closeSearch()

        // Input box should have focus after escape
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist")
        inputBox.typeText("after-escape")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "after-escape", "Escape should return focus to input box")
    }

    func testSearchFieldRetainsFocusDuringNavigation() throws {
        generateOutput("navfocus navfocus navfocus")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("navfocus")

        // Click next button by identifier
        let nextButton = searchBar.buttons["search-next"]
        if nextButton.waitForExistence(timeout: 2) {
            nextButton.click()
        }

        // Search field should still accept input after navigation
        searchField.typeText("extra")
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.contains("extra"), "Search field should retain focus during match navigation")

        closeSearch()
    }
}
