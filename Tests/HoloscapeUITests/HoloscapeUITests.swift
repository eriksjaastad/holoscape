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

    // MARK: - Input Box (requires non-PTY channel)

    func testInputBoxRetainsFocusAfterChannelSwitch() throws {
        // Create a Bridge channel so input-box is visible
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        // Switch away and back
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("test")
        XCTAssertEqual(inputBox.value as? String, "test")
    }

    // MARK: - Input Submission (requires non-PTY channel)

    func testEnterKeySubmitsAndClearsInput() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        inputBox.typeText("echo hello")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input box should be cleared after submission
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should be empty after Enter")
    }

    // MARK: - Command History (requires non-PTY channel)

    func testUpArrowRecallsPreviousCommand() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Submit a command
        inputBox.typeText("ls -la")
        inputBox.typeKey(.return, modifierFlags: [])

        // Press up arrow to recall it
        inputBox.typeKey(.upArrow, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "ls -la", "Up arrow should recall previous command")
    }

    func testDownArrowAfterUpClearsInput() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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
        // On launch, there should be at least one sidebar entry
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

    func testWindowExistsOnLaunch() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)
        let frame = window.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
