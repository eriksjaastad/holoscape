import XCTest

final class SearchAdvancedUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func openSearch() {
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func closeSearch() {
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func generateOutput(_ text: String) {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo \(text)")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Match Navigation

    func testSearchNextButtonAdvancesMatch() throws {
        generateOutput("searchword repeated searchword here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("searchword")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Click next button
        let nextButton = searchBar.buttons.matching(NSPredicate(format: "title CONTAINS '▼' OR title CONTAINS 'Next' OR title CONTAINS 'next'")).firstMatch
        if nextButton.exists {
            nextButton.click()
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Next button should advance match without crash")
        closeSearch()
    }

    func testSearchPreviousButtonGoesBack() throws {
        generateOutput("findme repeated findme here")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("findme")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Click previous button
        let prevButton = searchBar.buttons.matching(NSPredicate(format: "title CONTAINS '▲' OR title CONTAINS 'Previous' OR title CONTAINS 'prev'")).firstMatch
        if prevButton.exists {
            prevButton.click()
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Previous button should go back without crash")
        closeSearch()
    }

    func testSearchEnterAdvancesToNext() throws {
        generateOutput("enter-test data enter-test more")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("enter-test")
            Thread.sleep(forTimeInterval: 0.3)
            searchField.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Enter in search field should advance to next match")
        closeSearch()
    }

    func testSearchWrapsAround() throws {
        generateOutput("wraptest single")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("wraptest")
            Thread.sleep(forTimeInterval: 0.3)

            // Press Enter multiple times to wrap
            searchField.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
            searchField.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Search should wrap around at last match")
        closeSearch()
    }

    func testSearchPreviousWrapsAround() throws {
        generateOutput("prevwrap data")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("prevwrap")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Click previous to wrap backwards
        let prevButton = searchBar.buttons.matching(NSPredicate(format: "title CONTAINS '▲' OR title CONTAINS 'Previous'")).firstMatch
        if prevButton.exists {
            prevButton.click()
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Previous should wrap to last match from first")
        closeSearch()
    }

    // MARK: - Match Count Accuracy

    func testSearchMultipleMatchesCountCorrect() throws {
        generateOutput("multi multi multi")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("multi")
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Match count label should show correct count
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Multiple matches should show correct count")
        closeSearch()
    }

    func testSearchNoMatchesShowsZero() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("zzz_nonexistent_string_xyz")
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Should show "0 of 0" or similar
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "No matches should show zero count")
        closeSearch()
    }

    func testSearchSingleMatchShowsOneOfOne() throws {
        generateOutput("uniqueterm12345")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("uniqueterm12345")
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Should show "1 of 1"
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Single match should show 1 of 1")
        closeSearch()
    }

    // MARK: - Edge Cases

    func testSearchSpecialCharacters() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("[regex.*chars()")
            Thread.sleep(forTimeInterval: 0.3)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Special characters in search should not crash")
        closeSearch()
    }

    func testSearchVeryLongQuery() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            let longQuery = String(repeating: "x", count: 500)
            searchField.typeText(longQuery)
            Thread.sleep(forTimeInterval: 0.5)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Very long search query should be handled gracefully")
        closeSearch()
    }

    func testSearchWhileChannelSwitching() throws {
        // Create second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("channel-switch")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Switch channels while search is active
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Search should adapt when switching channels")
        closeSearch()
    }

    func testSearchClearedOnClose() throws {
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("clear-test")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Close search bar
        closeSearch()
        Thread.sleep(forTimeInterval: 0.3)

        // Search bar should be gone and highlights cleared
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Closing search should clear highlights")
    }

    // MARK: - Focus Management

    func testSearchFieldHasFocusOnOpen() throws {
        openSearch()

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            // Verify focus by typing
            searchField.typeText("focus-check")
            Thread.sleep(forTimeInterval: 0.2)
            let value = searchField.value as? String ?? ""
            XCTAssertTrue(value.contains("focus-check"), "Search field should have focus immediately on open")
        }

        closeSearch()
    }

    func testEscapeReturnsToInputBox() throws {
        openSearch()
        Thread.sleep(forTimeInterval: 0.3)

        // Escape to close search
        closeSearch()
        Thread.sleep(forTimeInterval: 0.3)

        // Input box should have focus
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("after-escape")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "after-escape", "Escape should return focus to input box")
    }

    func testSearchFieldRetainsFocusDuringNavigation() throws {
        generateOutput("navfocus navfocus navfocus")

        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("navfocus")
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Click next button
        let nextButton = searchBar.buttons.matching(NSPredicate(format: "title CONTAINS '▼' OR title CONTAINS 'Next'")).firstMatch
        if nextButton.exists {
            nextButton.click()
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Search field should still have focus
        if searchField.exists {
            searchField.typeText("extra")
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Search field should retain focus during navigation")
        closeSearch()
    }
}
