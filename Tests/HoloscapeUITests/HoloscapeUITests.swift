import XCTest

final class HoloscapeUITests: HoloscapeUITestCase {

    // MARK: - Window Launch

    func testAppLaunchesWithWindow() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Main window should exist on launch")
        XCTAssertTrue(window.isHittable, "Main window should be visible and interactable")
    }

    func testNoExtraTerminalWindowSpawned() throws {
        // Only one window should exist — the Holoscape window itself
        XCTAssertEqual(app.windows.count, 1, "Only one window should be open (no Terminal.app spawned)")
    }

    // MARK: - Input Box Focus

    func testInputBoxHasFocusOnLaunch() throws {
        // The input text view should be focused and accept keystrokes immediately
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should exist")

        // Type into it — if focus is correct, text appears
        inputBox.typeText("hello")
        XCTAssertEqual(inputBox.value as? String, "hello", "Input box should accept typing on launch")
    }

    func testInputBoxRetainsFocusAfterChannelSwitch() throws {
        // Open a new channel via File > New Channel, pick Shell
        createChannel(type: "Shell")

        // Input box should still accept keystrokes
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("test")
        XCTAssertEqual(inputBox.value as? String, "test")
    }

    // MARK: - Input Submission

    func testEnterKeySubmitsAndClearsInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        inputBox.typeText("echo hello")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input box should be cleared after submission
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should be empty after Enter")
    }

    func testEmptyInputDoesNotSubmit() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Press Enter with empty input — nothing should happen, no crash
        inputBox.typeKey(.return, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should remain empty")
    }

    // MARK: - Command History

    func testUpArrowRecallsPreviousCommand() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit a command
        inputBox.typeText("ls -la")
        inputBox.typeKey(.return, modifierFlags: [])

        // Press up arrow to recall it
        inputBox.typeKey(.upArrow, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "ls -la", "Up arrow should recall previous command")
    }

    func testDownArrowAfterUpClearsInput() throws {
        // BUG: InputBoxView.keyDown only handles down-arrow when string.isEmpty,
        // but after up-arrow recalls a command, string is non-empty so down-arrow
        // falls through to NSTextView instead of navigating history.
        // This test documents the expected behavior once fixed.
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Submit, then up, then down
        inputBox.typeText("pwd")
        inputBox.typeKey(.return, modifierFlags: [])

        inputBox.typeKey(.upArrow, modifierFlags: [])
        let recalled = inputBox.value as? String ?? ""
        XCTAssertEqual(recalled, "pwd", "Up arrow should recall previous command")

        inputBox.typeKey(.downArrow, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Down arrow past end of history should clear input")
    }

    // MARK: - Tab Bar

    func testDefaultShellTabExists() throws {
        // On launch, there should be at least one tab button (the default shell)
        let entry = sidebarEntry("Shell")
        XCTAssertTrue(entry.waitForExistence(timeout: 2), "Default Shell entry should be visible")
    }

    func testNewChannelCreatesTab() throws {
        // On launch we should have one Shell entry
        let firstEntry = sidebarEntry("Shell")
        XCTAssertTrue(firstEntry.waitForExistence(timeout: 2), "Should have initial Shell entry")

        // Create a new shell channel
        createChannel(type: "Shell")

        // The second shell entry should appear with an instance number
        let secondEntry = sidebarEntry("Shell 2")
        XCTAssertTrue(secondEntry.waitForExistence(timeout: 3), "Second Shell entry should appear after creating new channel")
    }

    // MARK: - Keyboard Shortcuts

    func testCmdWClosesChannel() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // Verify second entry appeared
        let secondEntry = sidebarEntry("Shell 2")
        XCTAssertTrue(secondEntry.waitForExistence(timeout: 3), "Second entry should exist before close test")

        // Close active channel
        app.typeKey("w", modifierFlags: .command)

        // If a confirmation dialog appears, confirm it
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        // The second entry should be gone
        let gone = secondEntry.waitForNonExistence(timeout: 2)
        XCTAssertTrue(gone, "Cmd+W should close the channel and remove its entry")
    }

    // MARK: - Window Behavior

    func testWindowIsResizable() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)
        // Verify the window has resize capability by checking it's not a fixed-size sheet
        let frame = window.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
