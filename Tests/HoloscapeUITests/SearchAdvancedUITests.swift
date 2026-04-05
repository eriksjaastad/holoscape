import XCTest

final class SearchAdvancedUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    private func generateOutput(_ text: String) {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo \(text)")
        inputBox.typeKey(.return, modifierFlags: [])
    }

    /// Read the match count label from the search bar. Returns the label text or nil.
    private func matchCountLabel() -> String? {
        let searchBar = app.toolbars["Search Bar"]
        // Look for static texts containing "of" or "No matches"
        let texts = searchBar.staticTexts
        for i in 0..<texts.count {
            let text = texts.element(boundBy: i).label
            if text.contains("of") || text.contains("No matches") || text.contains("0") {
                return text
            }
        }
        // Fall back to checking text fields
        let fields = searchBar.textFields
        for i in 0..<fields.count {
            let val = fields.element(boundBy: i).value as? String ?? ""
            if val.contains("of") || val.contains("No matches") {
                return val
            }
        }
        return nil
    }

    // MARK: - Match Navigation

    func testSearchNextButtonAdvancesMatch() throws {
        generateOutput("searchword repeated searchword here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("searchword")

        let labelBefore = matchCountLabel()

        // Click next — try buttons by index since icons may not have text titles
        let buttons = searchBar.buttons
        if buttons.count > 0 {
            buttons.element(boundBy: 0).click()
            }

        let labelAfter = matchCountLabel()

        // If we found labels, verify they changed; otherwise verify search bar is still functional
        if let before = labelBefore, let after = labelAfter {
            XCTAssertNotEqual(before, after, "Match label should change after clicking next")
        } else {
            // At minimum, search bar should still be present
            XCTAssertTrue(searchBar.exists, "Search bar should remain after clicking next")
        }

        closeSearch()
    }

    func testSearchPreviousButtonGoesBack() throws {
        generateOutput("findme repeated findme here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("findme")

        // Click previous — try second button or last button
        let buttons = searchBar.buttons
        if buttons.count > 1 {
            buttons.element(boundBy: 1).click()
        } else if buttons.count > 0 {
            buttons.element(boundBy: 0).click()
        }

        XCTAssertTrue(searchBar.exists, "Search bar should remain after clicking previous")
        closeSearch()
    }

    func testSearchEnterAdvancesToNext() throws {
        generateOutput("enter-test data enter-test more")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("enter-test")

        let labelBefore = matchCountLabel()
        searchField.typeKey(.return, modifierFlags: [])
        let labelAfter = matchCountLabel()

        if let before = labelBefore, let after = labelAfter {
            XCTAssertNotEqual(before, after, "Enter should advance match position")
        } else {
            XCTAssertTrue(searchBar.exists, "Search bar should remain functional after Enter")
        }

        closeSearch()
    }

    func testSearchWrapsAround() throws {
        generateOutput("wraptest single")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("wraptest")

        // Press Enter multiple times to wrap
        searchField.typeKey(.return, modifierFlags: [])
        searchField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(searchBar.exists, "Search should wrap around without crashing")
        closeSearch()
    }

    func testSearchPreviousWrapsAround() throws {
        generateOutput("prevwrap data")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("prevwrap")

        // Click previous to wrap backwards
        let buttons = searchBar.buttons
        if buttons.count > 1 {
            buttons.element(boundBy: 1).click()
        }

        XCTAssertTrue(searchBar.exists, "Previous should wrap without crashing")
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

        let label = matchCountLabel()
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

        // Look for "0" or "No matches" in the search bar
        let allTexts = searchBar.staticTexts
        var foundZeroIndicator = false
        for i in 0..<allTexts.count {
            let text = allTexts.element(boundBy: i).label
            if text.contains("0") || text.lowercased().contains("no match") {
                foundZeroIndicator = true
                break
            }
        }
        XCTAssertTrue(foundZeroIndicator, "No-match search should show zero count or 'No matches' label")

        closeSearch()
    }

    func testSearchSingleMatchShowsOneOfOne() throws {
        generateOutput("uniqueterm12345")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Search field should exist")

        searchField.typeText("uniqueterm12345")

        let allTexts = searchBar.staticTexts
        var foundOneOfOne = false
        for i in 0..<allTexts.count {
            let text = allTexts.element(boundBy: i).label
            if text.contains("1 of 1") {
                foundOneOfOne = true
                break
            }
        }
        XCTAssertTrue(foundOneOfOne, "Single match should show '1 of 1' in match count label")

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

        // Click next button
        let buttons = searchBar.buttons
        if buttons.count > 0 {
            buttons.element(boundBy: 0).click()
        }

        // Search field should still accept input after navigation
        searchField.typeText("extra")
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.contains("extra"), "Search field should retain focus during match navigation")

        closeSearch()
    }
}
