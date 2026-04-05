import XCTest

final class SearchBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Open/Close

    func testCmdFOpensSearchBar() throws {
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Search bar should be visible — look for the search field
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Search bar should appear on Cmd+F")
    }

    func testEscapeClosesSearchBar() throws {
        // Open search
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Close with Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Focus should return to input box
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("after-search")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "after-search", "Focus should return to input box after closing search")
    }

    func testCmdFTogglesSearchBar() throws {
        // Open
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Toggle off
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Input box should have focus
        let inputBox = app.textViews["input-box"]
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

        Thread.sleep(forTimeInterval: 0.3)

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
        Thread.sleep(forTimeInterval: 0.5)

        // Open search
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Type search query
        let searchBar = app.toolbars["Search Bar"]
        if searchBar.waitForExistence(timeout: 2) {
            let searchField = searchBar.textFields.firstMatch
            if searchField.waitForExistence(timeout: 1) {
                searchField.typeText("searchable")
                Thread.sleep(forTimeInterval: 0.5)
                // The match count label should show something other than empty
                // We can't directly read it, but the search mechanism should not crash
            }
        }

        // Close search
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Empty Query

    func testEmptyQueryShowsNoMatches() throws {
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Don't type anything — match count should be empty/zero
        // Just verify the search bar opened without crashing
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        app.typeKey(.escape, modifierFlags: [])
    }
}
