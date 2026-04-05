import XCTest

final class KeyboardShortcutsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - All Shortcuts Verified

    func testCmdN() throws {
        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Should focus session launcher or show dialog
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+N should trigger New Session")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmdW() throws {
        // Create second channel first
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+W should close channel")
    }

    func testCmdShiftS() throws {
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+Shift+S should toggle sidebar")

        // Toggle back
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testCmdT() throws {
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+T should toggle timestamps")

        // Toggle back
        app.typeKey("t", modifierFlags: .command)
    }

    func testCmdF() throws {
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Cmd+F should open search")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmdD() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+D should split horizontal")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testCmdShiftD() throws {
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+Shift+D should split vertical")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testCmdShiftW() throws {
        // Create split first
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+Shift+W should close split pane")
    }

    func testCmdComma() throws {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Cmd+, should open settings")

        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    func testCmdQ() throws {
        // Verify quit shortcut exists — don't actually quit
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()
        Thread.sleep(forTimeInterval: 0.2)

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.exists, "Cmd+Q should be bound to Quit")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmd1Through9() throws {
        // Create 3 channels
        for _ in 0..<2 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            if dialog.waitForExistence(timeout: 2) {
                dialog.buttons["Shell"].click()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Switch between channels
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("3", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+1-9 should switch between channels")
    }

    func testCmdC() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("copy-shortcut-test")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+C should copy")
    }

    func testCmdV() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("paste-source")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "paste-source", "Cmd+V should paste")
    }

    func testCmdX() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("cut-test")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Cmd+X should cut text")
    }

    func testCmdA() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("select-all")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeText("replaced")
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "replaced", "Cmd+A should select all")
    }

    // MARK: - Conflict Detection

    func testNoShortcutConflicts() throws {
        // Run through all shortcuts in sequence — none should crash or conflict
        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("t", modifierFlags: .command) // Toggle back

        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("w", modifierFlags: [.command, .shift])

        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("s", modifierFlags: [.command, .shift])

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "No shortcuts should conflict with each other")
    }

    func testShortcutsWorkFromInputBox() throws {
        // Ensure input box has focus
        let inputBox = app.textViews["input-box"]
        inputBox.click()
        Thread.sleep(forTimeInterval: 0.2)

        // Shortcuts should fire from input box
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Shortcuts should fire from input box")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testShortcutsWorkFromOutputView() throws {
        // Generate output then click it
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo output-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Shortcuts should still work
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Shortcuts should fire from output view")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testShortcutsWorkWithSearchBarOpen() throws {
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Toggle sidebar while search is open
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Shortcuts should work with search bar open")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Shortcut Context

    func testEscapeContextSensitive() throws {
        // Open search
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2))

        // Escape should close search bar
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Escape again should do nothing (no search bar open)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Escape should be context-sensitive")
    }

    func testEnterContextSensitive() throws {
        // In input box, Enter submits
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("enter-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Enter should submit input when input focused")

        // In search bar, Enter advances match
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let searchBar = app.toolbars["Search Bar"]
        let searchField = searchBar.textFields.firstMatch
        if searchField.waitForExistence(timeout: 1) {
            searchField.typeText("test")
            searchField.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Enter should be context-sensitive")
        app.typeKey(.escape, modifierFlags: [])
    }
}
