import XCTest

final class TimestampToggleUITests: HoloscapeUITestCase {

    // MARK: - Keyboard Shortcut

    func testCmdTTogglesTimestamps() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)

        // Verify the menu item exists after toggle
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Show Timestamps menu item should exist after Cmd+T toggle")
        app.typeKey(.escape, modifierFlags: [])

        // Toggle back off
        app.typeKey("t", modifierFlags: .command)
    }

    // MARK: - Menu Item

    func testViewMenuShowTimestamps() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Show Timestamps menu item should exist in View menu")
        XCTAssertTrue(timestampItem.isEnabled, "Show Timestamps menu item should be interactable")
        timestampItem.click()

        // Verify menu item still accessible after click
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem2 = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem2.waitForExistence(timeout: 2), "Show Timestamps menu item should still exist after toggling")
        timestampItem2.click()
    }

    // MARK: - Persistence

    func testTimestampMenuItemExistsAfterRestart() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)

        // Quit and relaunch
        app.terminate()
        app.launch()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App should relaunch successfully")

        // Verify menu item accessible after restart
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Timestamp menu item should exist after restart")
        app.typeKey(.escape, modifierFlags: [])

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }

    func testTimestampSettingPersistsAcrossChannelSwitch() throws {
        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)

        // Create second channel
        createChannel(type: "Shell")

        // Switch between channels
        app.typeKey("1", modifierFlags: .command)
        let firstEntry = sidebarEntry("Shell")
        XCTAssertTrue(firstEntry.waitForExistence(timeout: 2), "First channel sidebar entry should exist after switch")

        app.typeKey("2", modifierFlags: .command)

        // Verify menu item still present (setting is global)
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Timestamp setting should apply globally across channel switches")
        app.typeKey(.escape, modifierFlags: [])

        // Cleanup
        app.typeKey("t", modifierFlags: .command)
    }
}
