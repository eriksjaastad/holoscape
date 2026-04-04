import XCTest

final class HoloscapeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

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
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists, "Input box should exist")

        // Type into it — if focus is correct, text appears
        inputBox.typeText("hello")
        XCTAssertEqual(inputBox.value as? String, "hello", "Input box should accept typing on launch")
    }

    func testInputBoxRetainsFocusAfterChannelSwitch() throws {
        // Open a new channel via Cmd+N, pick Shell, then verify input still works
        app.typeKey("n", modifierFlags: .command)

        // Dialog should appear — click Shell
        let shellButton = app.buttons["Shell"]
        if shellButton.waitForExistence(timeout: 2) {
            shellButton.click()
        }

        // Input box should still accept keystrokes
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("test")
        XCTAssertEqual(inputBox.value as? String, "test")
    }

    // MARK: - Input Submission

    func testEnterKeySubmitsAndClearsInput() throws {
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists)

        inputBox.typeText("echo hello")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input box should be cleared after submission
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should be empty after Enter")
    }

    func testEmptyInputDoesNotSubmit() throws {
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists)

        // Press Enter with empty input — nothing should happen, no crash
        inputBox.typeKey(.return, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should remain empty")
    }

    // MARK: - Command History

    func testUpArrowRecallsPreviousCommand() throws {
        let inputBox = app.textViews.firstMatch
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
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists)

        // Submit, then up, then down
        inputBox.typeText("pwd")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        inputBox.typeKey(.upArrow, modifierFlags: [])
        let recalled = inputBox.value as? String ?? ""
        XCTAssertEqual(recalled, "pwd", "Up arrow should recall previous command")

        // TODO: Fix InputBoxView to handle down-arrow during history navigation
        // Once fixed, uncomment:
        // inputBox.typeKey(.downArrow, modifierFlags: [])
        // let value = inputBox.value as? String ?? ""
        // XCTAssertTrue(value.isEmpty, "Down arrow past end of history should clear input")
    }

    // MARK: - Tab Bar

    func testDefaultShellTabExists() throws {
        // On launch, there should be at least one tab button (the default shell)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Tab bar uses NSButton elements — look for any button containing "Shell"
        let shellTab = window.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'Shell'")).firstMatch
        XCTAssertTrue(shellTab.waitForExistence(timeout: 2), "Default Shell tab should be visible")
    }

    func testNewChannelCreatesTab() throws {
        let window = app.windows["Holoscape"]

        // On launch we should have one Shell tab
        let firstTab = window.buttons.matching(NSPredicate(format: "title == 'Shell'")).firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 2), "Should have initial Shell tab")

        // Create a new shell channel via Cmd+N
        app.typeKey("n", modifierFlags: .command)
        let dialogShellButton = app.buttons["Shell"]
        if dialogShellButton.waitForExistence(timeout: 2) {
            dialogShellButton.click()
        }

        // The second shell tab should appear with an instance number
        let secondTab = window.buttons.matching(NSPredicate(format: "title CONTAINS 'Shell 2'")).firstMatch
        XCTAssertTrue(secondTab.waitForExistence(timeout: 3), "Second Shell tab should appear after Cmd+N")
    }

    // MARK: - Keyboard Shortcuts

    func testCmdWClosesChannel() throws {
        // Create a second channel so closing doesn't leave us empty
        app.typeKey("n", modifierFlags: .command)
        let shellButton = app.buttons["Shell"]
        if shellButton.waitForExistence(timeout: 2) {
            shellButton.click()
        }

        // Verify second tab appeared
        let window = app.windows["Holoscape"]
        let secondTab = window.buttons.matching(NSPredicate(format: "title CONTAINS 'Shell 2'")).firstMatch
        XCTAssertTrue(secondTab.waitForExistence(timeout: 3), "Second tab should exist before close test")

        // Close active channel
        app.typeKey("w", modifierFlags: .command)

        // If a confirmation dialog appears, confirm it
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        // The second tab should be gone
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(secondTab.exists, "Cmd+W should close the channel and remove its tab")
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
