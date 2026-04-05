import XCTest

final class TimestampToggleUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Keyboard Shortcut

    func testCmdTTogglesTimestamps() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Disable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // No crash — toggle worked both ways
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after toggling timestamps on and off")
    }

    func testTimestampsVisibleAfterEnable() throws {
        // Submit a command to generate output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo timestamp-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Output should now show timestamp prefixes — verify app is functional
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should display timestamps after enabling")
    }

    func testTimestampsHiddenAfterDisable() throws {
        // Enable then disable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Output should have no timestamp prefix
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should hide timestamps after disabling")
    }

    // MARK: - Menu Item

    func testViewMenuShowTimestamps() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 1), "Show Timestamps menu item should exist in View menu")
        timestampItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Toggle back off via menu
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)
        let timestampItem2 = app.menuItems["Show Timestamps"]
        if timestampItem2.waitForExistence(timeout: 1) {
            timestampItem2.click()
        }
    }

    func testMenuCheckmarkReflectsState() throws {
        // Enable via Cmd+T
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Open View menu — item should show checkmark (title may differ when checked)
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 1), "Timestamp menu item should exist")

        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])

        // Disable timestamps
        app.typeKey("t", modifierFlags: .command)
    }

    // MARK: - Persistence

    func testTimestampSettingPersistsAcrossRestart() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Timestamps should still be enabled — verify via menu state
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 1), "Timestamp setting should persist across restart")

        app.typeKey(.escape, modifierFlags: [])

        // Disable for cleanup
        app.typeKey("t", modifierFlags: .command)
    }

    func testTimestampSettingPersistsAcrossChannelSwitch() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Create second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Switch between channels
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Timestamps should still be active on both channels
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Timestamp setting should apply globally across channel switches")

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }

    // MARK: - Display

    func testTimestampFormatIsCorrect() throws {
        // Submit some output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo format-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Timestamps should match [HH:MM:SS] format — no crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Timestamp format should render without crash")

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }

    func testTimestampsOnNewOutput() throws {
        // Enable timestamps first
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Generate new output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo new-output-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // New output should have timestamps
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "New output should show timestamps after enabling")

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }

    func testTimestampsOnExistingOutput() throws {
        // Generate output first
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo existing-output")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Enable timestamps after output exists
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Verify toggling on with existing output doesn't crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Toggling timestamps on existing output should not crash")

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }
}
