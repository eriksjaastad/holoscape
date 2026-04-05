import XCTest

final class InputBoxUITests: HoloscapeUITestCase {

    // MARK: - Auto-Grow

    func testInputBoxGrowsWithMultipleLines() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Insert multiple lines with Shift+Enter
        inputBox.typeText("line 1")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line 2")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line 3")

        // The input should contain all lines
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

        // Should be empty after send
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

        // Up arrow
        inputBox.typeKey(.upArrow, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "echo test-history", "Up arrow should recall previous command")
    }

    func testDownArrowAfterUpClearsInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit
        inputBox.typeText("history-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Up to recall, then down to clear
        inputBox.typeKey(.upArrow, modifierFlags: [])
        inputBox.typeKey(.downArrow, modifierFlags: [])

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
        }

        // Up arrow 3 times should recall cmd-a
        inputBox.typeKey(.upArrow, modifierFlags: [])
        inputBox.typeKey(.upArrow, modifierFlags: [])
        inputBox.typeKey(.upArrow, modifierFlags: [])

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
        createChannel(type: "Shell")

        // Switch back
        app.typeKey("1", modifierFlags: .command)

        // Type
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
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

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Empty input should remain empty after Enter")
    }
}
