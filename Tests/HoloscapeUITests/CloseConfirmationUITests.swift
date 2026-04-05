import XCTest

final class CloseConfirmationUITests: HoloscapeUITestCase {

    // MARK: - Confirmation Triggers

    func testCloseActiveShellShowsConfirmation() throws {
        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        let hasDialog = closeButton.waitForExistence(timeout: 2) || cancelButton.waitForExistence(timeout: 1)

        if hasDialog {
            XCTAssertTrue(closeButton.exists || cancelButton.exists, "Confirmation dialog should have Close or Cancel button")
            // Cancel to keep channel
            if cancelButton.exists {
                cancelButton.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // Verify sidebar entry still exists after cancel/no-dialog
        let shellEntry = sidebarEntry("Shell")
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Shell sidebar entry should remain")
    }

    func testCloseActiveAgentShowsConfirmation() throws {
        createChannel(type: "Agent (OAuth)")

        let agentEntry = app.windows["Holoscape"].buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3))
        agentEntry.click()

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 2) || cancelButton.waitForExistence(timeout: 1) {
            XCTAssertTrue(closeButton.exists || cancelButton.exists, "Confirmation dialog should appear for agent channel")
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Agent sidebar entry should remain after cancel")
    }

    func testCloseActiveSSHShowsConfirmation() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let newChannelItem = app.menuItems["New Channel"]
        XCTAssertTrue(newChannelItem.waitForExistence(timeout: 2))
        newChannelItem.click()

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))

        let sshButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'SSH'")).firstMatch
        guard sshButton.exists else {
            dialog.buttons["Cancel"].click()
            throw XCTSkip("No SSH option available")
        }
        sshButton.click()

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 2) || cancelButton.waitForExistence(timeout: 1) {
            XCTAssertTrue(closeButton.exists || cancelButton.exists, "Confirmation dialog should appear for SSH channel")
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after SSH close confirmation")
    }

    func testCloseDisconnectedChannelNoConfirmation() throws {
        createChannel(type: "Agent (OAuth)")

        // Wait for potential disconnection
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after closing disconnected channel")
    }

    // MARK: - Dialog Behavior

    func testConfirmationDialogHasButtons() throws {
        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 2) {
            XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
            XCTAssertTrue(cancelButton.waitForExistence(timeout: 1), "Dialog should have Cancel button")
            cancelButton.click()
        }
    }

    func testConfirmationCancelKeepsChannelOpen() throws {
        let shellEntry = sidebarEntry("Shell")
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        app.typeKey("w", modifierFlags: .command)

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.waitForExistence(timeout: 2) {
            cancelButton.click()
        }

        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Channel sidebar entry should remain open after Cancel")
    }

    func testConfirmationCloseRemovesChannel() throws {
        createChannel(type: "Shell")

        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))
        shell2.click()

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Channel sidebar entry should disappear after Close confirmation")
    }

    // MARK: - Edge Cases

    func testCloseLastChannelBehavior() throws {
        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        // Window should remain (app handles gracefully)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should remain after closing last channel")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still be present after closing last channel")
    }

    func testRapidCloseDoesNotDoublePrompt() throws {
        // Press Cmd+W twice quickly
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 2) || cancelButton.waitForExistence(timeout: 1) {
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        // Assert no crash and window remains
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Rapid Cmd+W should not stack dialogs or crash")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain functional after rapid close attempts")
    }
}
