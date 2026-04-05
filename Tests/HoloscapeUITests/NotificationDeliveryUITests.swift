import XCTest

final class NotificationDeliveryUITests: HoloscapeUITestCase {

    // MARK: - Permission

    func testNotificationPermissionRequested() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    func testNotificationPermissionDeniedHandledGracefully() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    // MARK: - Delivery

    func testNotificationFiredOnInactiveChannelOutput() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    func testNotificationNotFiredOnActiveChannel() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    func testNotificationContentShowsFirstLine() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    // MARK: - Click Handling

    func testNotificationClickSwitchesToChannel() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    func testNotificationClickBringsWindowToFront() throws {
        throw XCTSkip("Notifications cannot fire during XCUITest — NSApp.isActive is always true")
    }

    // MARK: - Settings Toggles

    func testNotificationRespectsPerTypeToggle() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let shellCheckbox = settingsWindow.checkBoxes["Shell"]
        XCTAssertTrue(shellCheckbox.waitForExistence(timeout: 3), "Shell notification checkbox should exist")

        // Toggle off if currently on
        let currentValue = shellCheckbox.value as? Int ?? 0
        if currentValue == 1 {
            shellCheckbox.click()
            XCTAssertEqual(shellCheckbox.value as? Int, 0, "Shell notification should be disabled after click")
            // Restore
            shellCheckbox.click()
        } else {
            shellCheckbox.click()
            XCTAssertEqual(shellCheckbox.value as? Int, 1, "Shell notification should be enabled after click")
            // Restore
            shellCheckbox.click()
        }

        closeSettings()
    }

    func testNotificationRespectsMasterToggle() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let enableCheckbox = settingsWindow.checkBoxes["Enable Notifications"]
        XCTAssertTrue(enableCheckbox.waitForExistence(timeout: 3), "Master notification toggle should exist")

        let originalValue = enableCheckbox.value as? Int ?? 0

        // Toggle
        enableCheckbox.click()
        let toggledValue = enableCheckbox.value as? Int ?? originalValue
        XCTAssertNotEqual(originalValue, toggledValue, "Master toggle should change state on click")

        // Restore
        enableCheckbox.click()
        XCTAssertEqual(enableCheckbox.value as? Int, originalValue, "Master toggle should restore to original state")

        closeSettings()
    }

    // MARK: - Per-Channel-Type Settings

    func testAgentChannelNotificationCheckboxExists() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let agentCheckbox = settingsWindow.checkBoxes["Agent"]
        XCTAssertTrue(agentCheckbox.waitForExistence(timeout: 3), "Agent notification toggle should exist in settings")

        closeSettings()
    }

    func testSSHChannelNotificationCheckboxExists() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let sshCheckbox = settingsWindow.checkBoxes["SSH"]
        XCTAssertTrue(sshCheckbox.waitForExistence(timeout: 3), "SSH notification toggle should exist in settings")

        closeSettings()
    }

    func testMCPChannelNotificationCheckboxExists() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let mcpCheckbox = settingsWindow.checkBoxes["MCP"]
        XCTAssertTrue(mcpCheckbox.waitForExistence(timeout: 3), "MCP notification toggle should exist in settings")

        closeSettings()
    }

    func testGroupChatChannelNotificationCheckboxExists() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]

        let gcCheckbox = settingsWindow.checkBoxes["Group Chat"]
        XCTAssertTrue(gcCheckbox.waitForExistence(timeout: 3), "Group Chat notification toggle should exist in settings")

        closeSettings()
    }
}
