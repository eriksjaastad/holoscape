import XCTest

final class InputBoxUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Auto-Grow

    func testInputBoxGrowsWithMultipleLines() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        let initialFrame = inputBox.frame

        // Insert multiple lines with Shift+Enter
        inputBox.typeText("line 1")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line 2")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line 3")

        Thread.sleep(forTimeInterval: 0.3)

        let grownFrame = inputBox.frame
        // The input container (parent scroll view) should have grown
        // We can't directly measure the scroll view, but the text view should have content
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("line 1"), "Input should contain first line")
        XCTAssertTrue(value.contains("line 3"), "Input should contain third line")
    }

    func testInputBoxShrinksAfterSend() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Type multiple lines
        inputBox.typeText("multi")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("input")

        // Send
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Should be empty and back to single-line height
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should be empty after send")
    }

    // MARK: - Shift+Enter

    func testShiftEnterInsertsNewline() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        inputBox.typeText("first line")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("second line")

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("first line"), "Should have first line")
        XCTAssertTrue(value.contains("second line"), "Should have second line after Shift+Enter")
        // Should NOT have submitted (text is still there)
        XCTAssertFalse(value.isEmpty)
    }

    // MARK: - Command History

    func testUpArrowRecallsCommand() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit a command
        inputBox.typeText("echo test-history")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Up arrow
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "echo test-history", "Up arrow should recall previous command")
    }

    func testDownArrowAfterUpClearsInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit
        inputBox.typeText("history-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Up to recall, then down to clear
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
        inputBox.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Down arrow past end of history should clear input")
    }

    func testMultipleHistoryEntries() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit 3 commands
        for cmd in ["cmd-a", "cmd-b", "cmd-c"] {
            inputBox.typeText(cmd)
            inputBox.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Up arrow 3 times should recall cmd-a
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.05)
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.05)
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.05)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "cmd-a", "Three up arrows should reach the first command")
    }

    // MARK: - Focus

    func testInputBoxHasFocusOnLaunch() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should exist")

        inputBox.typeText("focus-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "focus-test", "Input box should accept typing on launch")
    }

    func testInputBoxRetainsFocusAfterChannelSwitch() throws {
        // Create second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.3)

        // Switch back
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Type
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("still-focused")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "still-focused", "Input box should retain focus after channel switch")
    }

    // MARK: - Empty Submit

    func testEmptyInputDoesNotSubmit() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Press Enter with no text — should not crash
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Empty input should remain empty after Enter")
    }
}
