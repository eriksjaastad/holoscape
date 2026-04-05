import XCTest

final class NotificationUITests: HoloscapeUITestCase {

    // MARK: - Permission Request
    // Note: The actual system notification permission dialog is managed by macOS
    // and cannot be reliably triggered/dismissed in XCUITest.
    // These tests verify the app-level notification UI components.

    func testNotificationTogglesInSettings() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Verify all notification checkboxes exist
        let enableCheckbox = settingsWindow.checkBoxes["Enable Notifications"]
        XCTAssertTrue(enableCheckbox.waitForExistence(timeout: 2), "Master notification toggle should exist")

        let shellCheckbox = settingsWindow.checkBoxes["Shell"]
        XCTAssertTrue(shellCheckbox.exists, "Shell notification toggle should exist")

        let agentCheckbox = settingsWindow.checkBoxes["Agent"]
        XCTAssertTrue(agentCheckbox.exists, "Agent notification toggle should exist")

        let sshCheckbox = settingsWindow.checkBoxes["SSH"]
        XCTAssertTrue(sshCheckbox.exists, "SSH notification toggle should exist")

        let mcpCheckbox = settingsWindow.checkBoxes["MCP"]
        XCTAssertTrue(mcpCheckbox.exists, "MCP notification toggle should exist")

        let chatCheckbox = settingsWindow.checkBoxes["Group Chat"]
        XCTAssertTrue(chatCheckbox.exists, "Group Chat notification toggle should exist")
    }

    func testTogglingMasterDisablesPerType() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let enableCheckbox = settingsWindow.checkBoxes["Enable Notifications"]
        guard enableCheckbox.waitForExistence(timeout: 2) else {
            XCTFail("Enable Notifications checkbox not found")
            return
        }

        // Ensure enabled first
        if enableCheckbox.value as? Int == 0 {
            enableCheckbox.click()
        }

        let agentCheckbox = settingsWindow.checkBoxes["Agent"]
        XCTAssertTrue(agentCheckbox.isEnabled, "Per-type toggles should be enabled when master is on")

        // Disable master
        enableCheckbox.click()

        XCTAssertFalse(agentCheckbox.isEnabled, "Per-type toggles should be disabled when master is off")

        // Re-enable
        enableCheckbox.click()

        XCTAssertTrue(agentCheckbox.isEnabled, "Per-type toggles should re-enable when master is turned back on")
    }

    func testPerTypeTogglesPersist() throws {
        // Open settings, toggle shell notifications on
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let shellCheckbox = settingsWindow.checkBoxes["Shell"]
        guard shellCheckbox.waitForExistence(timeout: 2) else {
            XCTFail("Shell checkbox not found")
            return
        }

        // Toggle shell on if off
        if shellCheckbox.value as? Int == 0 {
            shellCheckbox.click()
        }

        // Close settings
        closeSettings()

        // Reopen settings
        openSettings()

        let reopened = app.windows["Appearance Settings"]
        let shellAgain = reopened.checkBoxes["Shell"]
        XCTAssertTrue(shellAgain.waitForExistence(timeout: 2))
        XCTAssertEqual(shellAgain.value as? Int, 1, "Shell notification toggle should persist after close/reopen")
    }
}
