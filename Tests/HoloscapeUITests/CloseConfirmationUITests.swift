import XCTest

final class CloseConfirmationUITests: HoloscapeUITestCase {

    // MARK: - Confirmation Triggers

    func testCloseActiveShellShowsConfirmation() throws {
        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Close confirmation should appear for active shell channel")

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")

        // Cancel to keep channel
        cancelButton.click()

        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Shell sidebar entry should remain after cancel")
    }

    func testCloseActiveAgentShowsConfirmation() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")

        let agentEntry = sidebarEntry("Agent")
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3))
        agentEntry.click()

        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Close confirmation should appear for active agent channel")

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")

        cancelButton.click()

        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Agent sidebar entry should remain after cancel")
    }

    // MARK: - Dialog Behavior

    func testConfirmationDialogHasButtons() throws {
        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Close confirmation dialog should appear")

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")

        cancelButton.click()
    }

    func testConfirmationCancelKeepsChannelOpen() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Close confirmation dialog should appear")

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")
        cancelButton.click()

        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Channel sidebar entry should remain open after Cancel")
    }

    func testConfirmationCloseRemovesChannel() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))
        shell2.click()

        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Close confirmation dialog should appear")

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        closeButton.click()

        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Channel sidebar entry should disappear after Close confirmation")
    }

    // MARK: - Edge Cases

    func testCloseLastChannelBehavior() throws {
        app.typeKey("w", modifierFlags: .command)

        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 3) {
            let closeButton = app.buttons["Close"]
            if closeButton.exists {
                closeButton.click()
            }
        }

        // Window should remain (app handles gracefully)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should remain after closing last channel")

        assertActiveChannelResponsive(message: "Channel should be responsive after closing last channel")
    }

    func testRapidCloseDoesNotDoublePrompt() throws {
        // Press Cmd+W twice quickly
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)

        // Only one dialog should appear
        let dialogs = app.dialogs
        let dialogCount = dialogs.count
        XCTAssertLessThanOrEqual(dialogCount, 1, "Rapid Cmd+W should not produce multiple dialogs")

        let dialog = dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let cancelButton = app.buttons["Cancel"]
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        // Assert no crash and window remains
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Rapid Cmd+W should not crash the app")
    }
}
