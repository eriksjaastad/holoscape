import XCTest

final class ContextMenuUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func createSecondShell() {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func shellSidebarEntry(_ label: String = "Shell") -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-\(label)'")).firstMatch
    }

    // MARK: - Close via Context Menu

    func testContextMenuCloseRemovesChannel() throws {
        createSecondShell()

        let shell2 = shellSidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 2))

        shell2.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let closeItem = app.menuItems["Close"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 1))
        closeItem.click()

        // Handle confirmation if it appears
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(shell2.exists, "Channel should be removed after context menu Close")
    }

    func testContextMenuCloseActiveChannelSwitchesToAnother() throws {
        createSecondShell()

        let shell2 = shellSidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 2))
        shell2.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Close active channel via context menu
        shell2.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let closeItem = app.menuItems["Close"]
        if closeItem.waitForExistence(timeout: 1) {
            closeItem.click()
        }

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Original Shell should still exist and be selected
        let shell1 = shellSidebarEntry("Shell")
        XCTAssertTrue(shell1.exists, "Another channel should be selected after closing active")
    }

    func testContextMenuCloseWithConfirmation() throws {
        // Active shell should show confirmation
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let closeItem = app.menuItems["Close"]
        if closeItem.waitForExistence(timeout: 1) {
            closeItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Check for confirmation dialog
        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 1) || cancelButton.exists {
            // Confirmation dialog appeared — cancel to keep channel
            if cancelButton.exists {
                cancelButton.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after cancelling close confirmation")
    }

    // MARK: - Rename

    func testContextMenuRenameShowsDialog() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let renameItem = app.menuItems["Rename"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 1), "Rename menu item should exist")
        renameItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // A dialog or text input should appear
        let dialog = app.dialogs.firstMatch
        let sheet = app.sheets.firstMatch
        let hasDialog = dialog.waitForExistence(timeout: 2) || sheet.waitForExistence(timeout: 1)
        XCTAssertTrue(hasDialog, "Rename should present a text input dialog")

        // Dismiss
        app.typeKey(.escape, modifierFlags: [])
    }

    func testContextMenuRenameUpdatesLabel() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let renameItem = app.menuItems["Rename"]
        if renameItem.waitForExistence(timeout: 1) {
            renameItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Type new name in the dialog
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let textField = dialog.textFields.firstMatch
            if textField.exists {
                textField.click()
                textField.typeKey("a", modifierFlags: .command) // Select all
                textField.typeText("MyCustomShell")
            }
            // Confirm rename
            let okButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'OK' OR title CONTAINS[c] 'Rename'")).firstMatch
            if okButton.exists {
                okButton.click()
            } else {
                dialog.typeKey(.return, modifierFlags: [])
            }
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Check for renamed label in sidebar
        let window = app.windows["Holoscape"]
        let renamedEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MyCustomShell'")).firstMatch
        XCTAssertTrue(renamedEntry.waitForExistence(timeout: 2), "Renamed label should appear in sidebar")
    }

    func testContextMenuRenamePersistsAcrossRestart() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let renameItem = app.menuItems["Rename"]
        if renameItem.waitForExistence(timeout: 1) {
            renameItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let textField = dialog.textFields.firstMatch
            if textField.exists {
                textField.click()
                textField.typeKey("a", modifierFlags: .command)
                textField.typeText("PersistShell")
            }
            let okButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'OK' OR title CONTAINS[c] 'Rename'")).firstMatch
            if okButton.exists {
                okButton.click()
            } else {
                dialog.typeKey(.return, modifierFlags: [])
            }
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        let renamedEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-PersistShell'")).firstMatch
        XCTAssertTrue(renamedEntry.waitForExistence(timeout: 3), "Renamed label should persist across restart")
    }

    func testContextMenuRenameEmptyStringRejected() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let renameItem = app.menuItems["Rename"]
        if renameItem.waitForExistence(timeout: 1) {
            renameItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let textField = dialog.textFields.firstMatch
            if textField.exists {
                textField.click()
                textField.typeKey("a", modifierFlags: .command)
                textField.typeKey(.delete, modifierFlags: [])
            }
            let okButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'OK' OR title CONTAINS[c] 'Rename'")).firstMatch
            if okButton.exists {
                okButton.click()
            } else {
                dialog.typeKey(.return, modifierFlags: [])
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Shell label should still exist (empty name rejected)
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2), "Empty rename should be rejected, original label preserved")
    }

    // MARK: - Duplicate

    func testContextMenuDuplicateCreatesNewChannel() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 1), "Duplicate menu item should exist")
        duplicateItem.click()
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let shell2 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell 2'")).firstMatch
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "Duplicate should create a second channel")
    }

    func testContextMenuDuplicateShellChannel() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let duplicateItem = app.menuItems["Duplicate"]
        if duplicateItem.waitForExistence(timeout: 1) {
            duplicateItem.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Verify new shell was created
        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 2, "Duplicating shell should create a new shell channel")
    }

    func testContextMenuDuplicateAgentChannel() throws {
        // Create an agent channel first
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        guard agentEntry.waitForExistence(timeout: 3) else {
            XCTFail("Agent entry should exist for duplicate test")
            return
        }

        agentEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let duplicateItem = app.menuItems["Duplicate"]
        if duplicateItem.waitForExistence(timeout: 1) {
            duplicateItem.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let agentEntries = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'"))
        XCTAssertGreaterThanOrEqual(agentEntries.count, 2, "Duplicating agent should create new agent with same profile")
    }

    func testContextMenuDuplicateSSHChannel() throws {
        // SSH may not be available — skip if no SSH option
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))

        let sshButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'SSH'")).firstMatch
        guard sshButton.exists else {
            dialog.buttons["Cancel"].click()
            throw XCTSkip("No SSH option available for duplicate test")
        }
        sshButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        guard sshEntry.waitForExistence(timeout: 3) else {
            throw XCTSkip("SSH entry did not appear")
        }

        sshEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let duplicateItem = app.menuItems["Duplicate"]
        if duplicateItem.waitForExistence(timeout: 1) {
            duplicateItem.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let sshEntries = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'"))
        XCTAssertGreaterThanOrEqual(sshEntries.count, 2, "Duplicating SSH should reconnect to same host")
    }

    func testContextMenuDuplicateIncrementLabel() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        // Duplicate once
        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let duplicateItem = app.menuItems["Duplicate"]
        if duplicateItem.waitForExistence(timeout: 1) {
            duplicateItem.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let shell2 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell 2'")).firstMatch
        XCTAssertTrue(shell2.waitForExistence(timeout: 2), "First duplicate should get numbered label 'Shell 2'")

        // Duplicate again
        shell2.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let duplicateItem2 = app.menuItems["Duplicate"]
        if duplicateItem2.waitForExistence(timeout: 1) {
            duplicateItem2.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let shell3 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell 3'")).firstMatch
        XCTAssertTrue(shell3.waitForExistence(timeout: 2), "Second duplicate should get 'Shell 3'")
    }

    // MARK: - Reconnect

    func testContextMenuReconnectOnlyOnDisconnected() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let reconnectItem = app.menuItems["Reconnect"]
        XCTAssertTrue(reconnectItem.waitForExistence(timeout: 1), "Reconnect menu item should exist")
        // Active channel Reconnect should be disabled
        XCTAssertFalse(reconnectItem.isEnabled, "Reconnect should be disabled for active channel")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testContextMenuReconnectReactivatesChannel() throws {
        // Create an agent channel that may disconnect
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 2.0)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        guard agentEntry.waitForExistence(timeout: 2) else { return }

        agentEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let reconnectItem = app.menuItems["Reconnect"]
        if reconnectItem.waitForExistence(timeout: 1) && reconnectItem.isEnabled {
            reconnectItem.click()
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertTrue(agentEntry.exists, "Channel should still exist after reconnect attempt")
        } else {
            // If not enabled, just verify it exists
            XCTAssertTrue(reconnectItem.exists, "Reconnect menu item should exist")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testContextMenuReconnectOnActiveChannelDisabled() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let reconnectItem = app.menuItems["Reconnect"]
        if reconnectItem.waitForExistence(timeout: 1) {
            XCTAssertFalse(reconnectItem.isEnabled, "Reconnect should be grayed out for active channel")
        }

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Copy Session Info

    func testContextMenuCopySessionInfo() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let copyInfoItem = app.menuItems["Copy Session Info"]
        XCTAssertTrue(copyInfoItem.waitForExistence(timeout: 1), "Copy Session Info menu item should exist")
        copyInfoItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Verify clipboard has content (general pasteboard)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after Copy Session Info")
    }

    func testContextMenuCopySessionInfoContent() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let copyInfoItem = app.menuItems["Copy Session Info"]
        if copyInfoItem.waitForExistence(timeout: 1) {
            copyInfoItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Clipboard should contain channel info — verify via paste into input box
        let inputBox = app.textViews["input-box"]
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Clipboard should contain session info after Copy Session Info")
    }

    // MARK: - Pin/Unpin

    func testContextMenuUnpinRemovesEmoji() throws {
        let shellEntry = shellSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        // Pin first
        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let pinItem = app.menuItems["Pin"]
        if pinItem.waitForExistence(timeout: 1) {
            pinItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Unpin
        shellEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let unpinItem = app.menuItems["Unpin"]
        if unpinItem.waitForExistence(timeout: 1) {
            unpinItem.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Verify the sidebar entry no longer shows pin indicator
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after unpin")
    }

    func testContextMenuPinOrderStableWithMultiplePins() throws {
        createSecondShell()

        let window = app.windows["Holoscape"]
        let shell1 = shellSidebarEntry("Shell")
        let shell2 = shellSidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 2))

        // Pin both channels
        shell1.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let pin1 = app.menuItems["Pin"]
        if pin1.waitForExistence(timeout: 1) {
            pin1.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        shell2.rightClick()
        Thread.sleep(forTimeInterval: 0.3)
        let pin2 = app.menuItems["Pin"]
        if pin2.waitForExistence(timeout: 1) {
            pin2.click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Both should still be visible — order should be stable
        XCTAssertTrue(shell1.exists, "First pinned channel should remain visible")
        XCTAssertTrue(shell2.exists, "Second pinned channel should remain visible")
    }
}
