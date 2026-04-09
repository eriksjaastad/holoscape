import XCTest

final class InputBoxUITests: HoloscapeUITestCase {

    /// Input box is only visible for non-PTY channels (Bridge, Group Chat).
    /// Create a Bridge channel before each test so input-box exists.
    override func setUpWithError() throws {
        try super.setUpWithError()
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Auto-Grow

    func testInputBoxGrowsWithMultipleLines() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist for non-PTY channel")

        let baselineHeight = inputBox.frame.height

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

        let grownHeight = inputBox.frame.height
        XCTAssertGreaterThan(grownHeight, baselineHeight, "Input box height should increase with multiple lines")
        XCTAssertGreaterThan(grownHeight, 30, "Input box height should be greater than 30 points with multiple lines")
    }

    func testInputBoxShrinksAfterSend() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        let baselineHeight = inputBox.frame.height

        // Type multiple lines
        inputBox.typeText("multi")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("input")

        let expandedHeight = inputBox.frame.height

        // Send
        inputBox.typeKey(.return, modifierFlags: [])

        // Should be empty after send
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should be empty after send")

        let shrunkHeight = inputBox.frame.height
        XCTAssertLessThan(shrunkHeight, expandedHeight, "Input box height should decrease after sending multi-line input")
        XCTAssertLessThanOrEqual(shrunkHeight, baselineHeight + 2, "Input box height should return to approximately baseline after send")
    }

    // MARK: - Shift+Enter

    func testShiftEnterInsertsNewline() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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

    func testInputBoxHasFocusOnNonPTYChannel() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist for non-PTY channel")

        inputBox.typeText("focus-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "focus-test", "Input box should accept typing on non-PTY channel")
    }

    func testInputBoxRetainsFocusAfterChannelSwitch() throws {
        // Switch to shell and back to bridge
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Type
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("still-focused")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "still-focused", "Input box should retain focus after channel switch")
    }

    // MARK: - Empty Submit

    func testEmptyInputDoesNotSubmit() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Press Enter with no text — should not crash
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Empty input should remain empty after Enter")
    }
}
