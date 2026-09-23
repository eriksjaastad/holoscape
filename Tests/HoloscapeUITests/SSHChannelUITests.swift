import XCTest

final class SSHChannelUITests: HoloscapeUITestCase {

    private func sshProfileAvailable() -> Bool {
        // Check if any SSH profiles are configured by looking for sidebar entries after refresh
        let comboBox = app.comboBoxes["session-launcher-combo"]
        return comboBox.waitForExistence(timeout: 2)
    }

    // MARK: - Channel Creation

    func testNewChannelUsesUnifiedLauncherInsteadOfSeparateSSHDialog() throws {
        // Verify File > New Channel opens the unified launcher. SSH remains
        // typed/profile-driven rather than a separate modal button.
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        XCTAssertTrue(app.comboBoxes["session-launcher-combo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.dialogs.firstMatch.waitForExistence(timeout: 1), "New Channel should not open a separate SSH dialog")
    }

    // MARK: - Session Launcher SSH Path

    func testSessionLauncherComboBoxExists() throws {
        let comboBox = app.comboBoxes["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Session launcher should exist for SSH profile selection")
    }

    func testSessionLauncherAcceptsSSHProfileName() throws {
        let comboBox = app.comboBoxes["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))
        comboBox.click()
        comboBox.typeText("ssh-test")
        // Don't press Enter — just verify it accepts text
        XCTAssertTrue(comboBox.isEnabled, "Launcher should accept SSH profile name input")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Context Menu for Future SSH Entries

    func testContextMenuHasReconnectItem() throws {
        // Verify Reconnect exists in context menu (SSH would use this).
        let shellEntry = defaultShellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))
        shellEntry.rightClick()

        let reconnectItem = app.menuItems["Reconnect"]
        XCTAssertTrue(reconnectItem.waitForExistence(timeout: 2), "Reconnect should exist in context menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMultipleChannelTypesCoexist() throws {
        // Create a bridge channel alongside the default shell
        createChannel(type: "Bridge")

        // Default shell's label may be a directory name (OSC 7), so use index-based lookup
        XCTAssertGreaterThanOrEqual(sidebarEntryCount(), 2, "Should have at least 2 channels after creating Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 2), "Bridge should coexist with shell")

        // Switch to first channel (default shell) and verify it's responsive
        app.typeKey("1", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel should be responsive after switching between channel types")
    }
}
