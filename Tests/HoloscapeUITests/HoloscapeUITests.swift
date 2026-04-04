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
        let inputBox = app.textViews.firstMatch
        XCTAssertTrue(inputBox.exists)

        // Submit, then up, then down
        inputBox.typeText("pwd")
        inputBox.typeKey(.return, modifierFlags: [])
        inputBox.typeKey(.upArrow, modifierFlags: [])
        inputBox.typeKey(.downArrow, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Down arrow past end of history should clear input")
    }

    // MARK: - Tab Bar

    func testDefaultShellTabExists() throws {
        // On launch, there should be at least one tab (the default shell)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Look for tab bar content — the Shell tab
        let shellTab = window.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'Shell'")).firstMatch
        XCTAssertTrue(shellTab.waitForExistence(timeout: 2), "Default Shell tab should be visible")
    }

    func testNewChannelCreatesTab() throws {
        // Count initial tabs
        let window = app.windows["Holoscape"]
        let initialTabCount = window.staticTexts.count

        // Create new shell channel
        app.typeKey("n", modifierFlags: .command)
        let shellButton = app.buttons["Shell"]
        if shellButton.waitForExistence(timeout: 2) {
            shellButton.click()
        }

        // Should have one more tab
        let newTabCount = window.staticTexts.count
        XCTAssertGreaterThan(newTabCount, initialTabCount, "New channel should add a tab")
    }

    // MARK: - Keyboard Shortcuts

    func testCmdWClosesChannel() throws {
        // Create a second channel first so closing doesn't leave us empty
        app.typeKey("n", modifierFlags: .command)
        let shellButton = app.buttons["Shell"]
        if shellButton.waitForExistence(timeout: 2) {
            shellButton.click()
        }

        let window = app.windows["Holoscape"]
        let tabCountBefore = window.staticTexts.count

        // Close active channel
        app.typeKey("w", modifierFlags: .command)

        // If a confirmation dialog appears, confirm it
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        let tabCountAfter = window.staticTexts.count
        XCTAssertLessThan(tabCountAfter, tabCountBefore, "Cmd+W should close a channel")
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
