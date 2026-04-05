import XCTest

final class KeyboardShortcutsUITests: HoloscapeUITestCase {

    // MARK: - All Shortcuts Verified

    func testCmdN() throws {
        app.typeKey("n", modifierFlags: .command)

        // Should show combo box or dialog for new session
        let dialog = app.dialogs.firstMatch
        let comboBox = app.comboBoxes.firstMatch
        let appeared = dialog.waitForExistence(timeout: 3) || comboBox.waitForExistence(timeout: 1)
        XCTAssertTrue(appeared, "Cmd+N should show new session dialog or combo box")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmdW() throws {
        createChannel(type: "Shell")

        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))
        shell2.click()

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Cmd+W should remove channel from sidebar")
    }

    func testCmdShiftS() throws {
        app.typeKey("s", modifierFlags: [.command, .shift])

        // Tab bar should appear when sidebar is collapsed
        let window = app.windows["Holoscape"]
        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Cmd+Shift+S should collapse sidebar and show tab bar")

        // Toggle back
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testCmdT() throws {
        app.typeKey("t", modifierFlags: .command)

        // Verify menu item is still interactable (toggle worked without crash)
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Show Timestamps menu item should still be interactable after Cmd+T")
        app.typeKey(.escape, modifierFlags: [])

        // Toggle back
        app.typeKey("t", modifierFlags: .command)
    }

    func testCmdF() throws {
        app.typeKey("f", modifierFlags: .command)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3), "Cmd+F should open search bar")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmdD() throws {
        app.typeKey("d", modifierFlags: .command)

        // After split, input box should still work
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still work after Cmd+D split")
        inputBox.typeText("split-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submit in split pane")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testCmdShiftD() throws {
        app.typeKey("d", modifierFlags: [.command, .shift])

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still work after Cmd+Shift+D vertical split")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testCmdShiftW() throws {
        // Create split first
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after Cmd+Shift+W closes split pane")
    }

    func testCmdComma() throws {
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Cmd+, should open settings window")

        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    func testCmdQ() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.waitForExistence(timeout: 2), "Cmd+Q should be bound to Quit")
        XCTAssertTrue(quitItem.isEnabled, "Quit should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testCmd1Through9() throws {
        // Create 3 channels total
        for _ in 0..<2 {
            createChannel(type: "Shell")
        }

        let inputBox = app.textViews["input-box"]

        // Switch between channels
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist after Cmd+1")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist after Cmd+2")

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist after Cmd+3")
    }

    func testCmdCVXA() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Type, select all, copy
        inputBox.typeText("clipboard-test")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)

        // Cut (should clear)
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("x", modifierFlags: .command)

        let afterCut = inputBox.value as? String ?? ""
        XCTAssertTrue(afterCut.isEmpty, "Cmd+X should cut text from input box")

        // Paste back
        inputBox.typeKey("v", modifierFlags: .command)

        let afterPaste = inputBox.value as? String ?? ""
        XCTAssertEqual(afterPaste, "clipboard-test", "Cmd+V should paste back the copied text")
    }

    // MARK: - Conflict Detection

    func testNoShortcutConflicts() throws {
        // Run through all shortcuts in sequence
        app.typeKey("n", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)

        app.typeKey("f", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("d", modifierFlags: .command)
        app.typeKey("w", modifierFlags: [.command, .shift])

        app.typeKey("s", modifierFlags: [.command, .shift])
        app.typeKey("s", modifierFlags: [.command, .shift])

        // Window should still be functional
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after rapid shortcut sequence")
        inputBox.typeText("post-conflict-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Input box should accept text after rapid shortcut sequence")
    }

    func testShortcutsWorkFromInputBox() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.click()

        app.typeKey("f", modifierFlags: .command)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3), "Shortcuts should fire from input box")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testShortcutsWorkFromOutputView() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("echo output-test")
        inputBox.typeKey(.return, modifierFlags: [])

        app.typeKey("f", modifierFlags: .command)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3), "Shortcuts should fire from output view")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testShortcutsWorkWithSearchBarOpen() throws {
        app.typeKey("f", modifierFlags: .command)
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3))

        // Toggle sidebar while search is open
        app.typeKey("s", modifierFlags: [.command, .shift])
        app.typeKey("s", modifierFlags: [.command, .shift])

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain functional with search bar open")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Shortcut Context

    func testEscapeClosesSearch() throws {
        app.typeKey("f", modifierFlags: .command)

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3))

        app.typeKey(.escape, modifierFlags: [])

        // Search bar should be gone
        XCTAssertFalse(searchBar.waitForExistence(timeout: 2), "Escape should close search bar")
    }

    func testEnterSubmitsInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("enter-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Enter should submit input and clear the input box")
    }
}
